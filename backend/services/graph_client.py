import uuid
from neo4j import AsyncGraphDatabase
from config import settings
from datetime import datetime

class GraphClient:
    def __init__(self):
        self._driver = None

    async def init(self):
        if not settings.NEO4J_URI or not settings.NEO4J_PASSWORD:
            print("WARNING: Neo4j credentials not configured correctly.")
            return
        
        try:
            self._driver = AsyncGraphDatabase.driver(
                settings.NEO4J_URI,
                auth=(settings.NEO4J_USERNAME, settings.NEO4J_PASSWORD),
                max_connection_lifetime=600 
            )
            async with self._driver.session() as session:
                await session.execute_write(self._setup_schema)
            print("Neo4j Graph (Memory Storage) initialized successfully.")
        except Exception as e:
            print(f"Failed to initialize Neo4j: {e}")

    @staticmethod
    async def _setup_schema(tx):
        await (await tx.run("CREATE CONSTRAINT user_id_unique IF NOT EXISTS FOR (u:User) REQUIRE u.id IS UNIQUE")).consume()
        await (await tx.run("CREATE CONSTRAINT interaction_id_unique IF NOT EXISTS FOR (i:Interaction) REQUIRE i.id IS UNIQUE")).consume()

    async def _safe_run(self, func, *args, **kwargs):
        if not self._driver:
            await self.init()
        try:
            return await func(*args, **kwargs)
        except Exception as e:
            if "10054" in str(e) or "defunct" in str(e).lower():
                await self.init()
                return await func(*args, **kwargs)
            raise e

    async def update_graph(self, data: dict):
        return await self._safe_run(self._update_graph_impl, data)

    async def _update_graph_impl(self, data):
        async with self._driver.session() as session:
            try:
                # 1. First, create/update User & Session
                await session.execute_write(self._create_base_nodes_tx, data)
                
                # 2. Then, create interaction and entities in ONE major Query for speed/reliability
                await session.execute_write(self._create_interaction_full_tx, data)
                
                print(f"DEBUG: Graph fully updated for {data['interaction_id']}")
                return True
            except Exception as e:
                print(f"DEBUG: Graph write FAILED for {data['interaction_id']}: {e}")
                raise

    @staticmethod
    async def _create_base_nodes_tx(tx, data):
        cypher = """
        MERGE (u:User {id: $user_id})
        MERGE (s:Session {id: $session_id})
        MERGE (u)-[:HAS_SESSION]->(s)
        """
        await (await tx.run(cypher, user_id=data["user_id"], session_id=data["session_id"])).consume()

    @staticmethod
    async def _create_interaction_full_tx(tx, data):
        # We model the interaction and all its metadata as a single transactional unit
        cypher = """
        // 1. Create Interaction
        MATCH (s:Session {id: $session_id})
        MERGE (i:Interaction {id: $interaction_id})
        SET i.text = $text, i.timestamp = datetime()
        MERGE (s)-[:HAS_INTERACTION]->(i)
        
        // 2. Intent
        WITH i
        CALL (i) {
          WITH i WHERE $intent <> ""
          MERGE (intent:Intent {name: $intent})
          MERGE (i)-[:HAS_INTENT]->(intent)
        }
        
        // 3. Topic & User Interest
        WITH i
        CALL (i) {
          WITH i WHERE $topic <> ""
          MERGE (topic:Topic {name: $topic})
          MERGE (i)-[:RELATES_TO]->(topic)
          WITH topic
          MATCH (u:User)-[:HAS_SESSION]->(:Session)-[:HAS_INTERACTION]->(i)
          MERGE (u)-[:INTERESTED_IN]->(topic)
        }
        
        // 4. Sequential connection
        WITH i
        CALL (i) {
          WITH i WHERE $prev_id <> "" AND $prev_id IS NOT NULL
          // Reference the previous interaction if it exists
          MERGE (prev:Interaction {id: $prev_id})
          MERGE (i)-[:FOLLOWS]->(prev)
        }
        
        RETURN i
        """
        await (await tx.run(
            cypher, 
            session_id=data["session_id"],
            interaction_id=data["interaction_id"],
            text=data["text"],
            intent=data.get("intent", ""),
            topic=data.get("topic", ""),
            prev_id=data.get("prev_interaction_id")
        )).consume()

        # 4. Entities (Python-side sanitization ensures we don't pass mixed types to Cypher)
        entities = data.get("entities", [])
        sanitized_entities = []
        for ent in entities:
            if isinstance(ent, dict):
                sanitized_entities.append(ent)
            elif isinstance(ent, str):
                sanitized_entities.append({"name": ent, "type": "General"})

        if sanitized_entities:
            entity_cypher = """
            UNWIND $entities as ent
            MATCH (i:Interaction {id: $interaction_id})
            MERGE (e:Entity {name: ent.name})
            SET e.type = coalesce(ent.type, "General")
            MERGE (i)-[:MENTIONS]->(e)
            """
            await (await tx.run(
                entity_cypher,
                interaction_id=data["interaction_id"],
                entities=sanitized_entities
            )).consume()

    async def get_routing_signals(self, session_id: str):
        """Calculates session depth and continuity score for the current session."""
        if not self._driver: return {"depth": 0, "continuity": 0.0}
        async with self._driver.session() as session:
            # 1. Depth: Number of interactions in this session
            depth_res = await session.run(
                "MATCH (:Session {id: $session_id})-[:HAS_INTERACTION]->(i:Interaction) RETURN count(i) as c",
                session_id=session_id
            )
            depth_rec = await depth_res.single()
            depth = depth_rec["c"] if depth_rec else 0
            
            # 2. Continuity: Length of the longest FOLLOWS chain in this session
            chain_res = await session.run(
                "MATCH (s:Session {id: $session_id})-[:HAS_INTERACTION]->(i:Interaction) "
                "OPTIONAL MATCH p = (i)-[:FOLLOWS*]->(:Interaction) "
                "RETURN length(p) as chain ORDER BY chain DESC LIMIT 1",
                session_id=session_id
            )
            chain_rec = await chain_res.single()
            chain_len = chain_rec["chain"] if chain_rec and chain_rec["chain"] is not None else 0
            
            # Simple score: normalized continuity (chain / depth) 
            continuity = (chain_len / depth) if depth > 0 else 0.0
            
            return {
                "depth": depth,
                "continuity": min(continuity, 1.0)
            }

    async def get_related_context(self, user_id: str, query: str, limit: int = 5):
        if not self._driver: return {"topics": [], "entities": []}
        async with self._driver.session() as session:
            cypher = """
            MATCH (u:User {id: $user_id})
            OPTIONAL MATCH (u)-[:INTERESTED_IN]->(t:Topic)
            WITH u, collect(DISTINCT t.name) as topics
            OPTIONAL MATCH (u)-[:HAS_SESSION]->(:Session)-[:HAS_INTERACTION]->(i:Interaction)-[:MENTIONS]->(e:Entity)
            RETURN topics, collect(DISTINCT {name: e.name, type: e.type}) as entities
            """
            result = await session.run(cypher, user_id=user_id)
            record = await result.single()
            if record:
                entities = [e for e in (record["entities"] or []) if e.get("name")]
                return {"topics": record["topics"][:limit], "entities": entities[:limit]}
            return {"topics": [], "entities": []}

graph_client = GraphClient()
