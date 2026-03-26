from neo4j import AsyncGraphDatabase
from config import settings


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
                max_connection_lifetime=600,
            )
            async with self._driver.session() as session:
                await session.execute_write(self._setup_schema)
            print("Neo4j Graph (Memory Storage) initialized successfully.")
        except Exception as e:
            print(f"Failed to initialize Neo4j: {e}")

    @staticmethod
    async def _setup_schema(tx):
        """Constraints + indexes so every MERGE on a named node uses an index scan."""
        cmds = [
            "CREATE CONSTRAINT user_id_unique IF NOT EXISTS FOR (u:User) REQUIRE u.id IS UNIQUE",
            "CREATE CONSTRAINT interaction_id_unique IF NOT EXISTS FOR (i:Interaction) REQUIRE i.id IS UNIQUE",
            # Indexes prevent full-label scans on every MERGE
            "CREATE INDEX entity_name IF NOT EXISTS FOR (e:Entity) ON (e.name)",
            "CREATE INDEX topic_name  IF NOT EXISTS FOR (t:Topic)  ON (t.name)",
            "CREATE INDEX intent_name IF NOT EXISTS FOR (n:Intent)  ON (n.name)",
        ]
        for cmd in cmds:
            await (await tx.run(cmd)).consume()

    # ------------------------------------------------------------------
    # Internal helpers
    # ------------------------------------------------------------------

    async def _safe_run(self, func, *args, **kwargs):
        if not self._driver:
            await self.init()
        try:
            return await func(*args, **kwargs)
        except Exception as e:
            if "10054" in str(e) or "defunct" in str(e).lower():
                await self.init()
                return await func(*args, **kwargs)
            raise

    @staticmethod
    def _normalize(text: str) -> str:
        """Lowercase + strip so 'Paracetamol' and 'paracetamol' share one node."""
        return text.strip().lower()

    @staticmethod
    def _sanitize_entities(raw: list) -> list:
        seen, out = set(), []
        for ent in raw:
            if isinstance(ent, dict):
                name = ent.get("name", "").strip().lower()
                etype = ent.get("type", "General")
            elif isinstance(ent, str):
                name = ent.strip().lower()
                etype = "General"
            else:
                continue
            if name and name not in seen:
                seen.add(name)
                out.append({"name": name, "type": etype})
        return out

    @staticmethod
    def _co_occurrence_pairs(entities: list) -> list:
        """All unique ordered pairs for CO_OCCURS_WITH edges."""
        pairs = []
        names = [e["name"] for e in entities]
        for i in range(len(names)):
            for j in range(i + 1, len(names)):
                a, b = names[i], names[j]
                pairs.append({"a": min(a, b), "b": max(a, b)})
        return pairs

    # ------------------------------------------------------------------
    # Public write
    # ------------------------------------------------------------------

    async def update_graph(self, data: dict):
        return await self._safe_run(self._update_graph_impl, data)

    async def _update_graph_impl(self, data: dict):
        # Normalise at Python level — one place, consistent everywhere
        topic  = self._normalize(data.get("topic",  "") or "")
        intent = self._normalize(data.get("intent", "") or "")
        entities = self._sanitize_entities(data.get("entities", []))
        pairs    = self._co_occurrence_pairs(entities)

        norm = {**data, "topic": topic, "intent": intent}

        async with self._driver.session() as session:
            try:
                await session.execute_write(self._create_base_nodes_tx, norm)
                await session.execute_write(
                    self._create_interaction_full_tx, norm, entities, pairs
                )
                print(f"[Graph] updated {data['interaction_id']}")
                return True
            except Exception as e:
                print(f"[Graph] FAILED {data['interaction_id']}: {e}")
                raise

    @staticmethod
    async def _create_base_nodes_tx(tx, data: dict):
        await (await tx.run(
            """
            MERGE (u:User {id: $user_id})
            MERGE (s:Session {id: $session_id})
            MERGE (u)-[:HAS_SESSION]->(s)
            """,
            user_id=data["user_id"],
            session_id=data["session_id"],
        )).consume()

    @staticmethod
    async def _create_interaction_full_tx(tx, data: dict, entities: list, pairs: list):
        # ── 1. Interaction node + intent + weighted topic interest + chain ──
        await (await tx.run(
            """
            MATCH (s:Session {id: $session_id})
            MERGE (i:Interaction {id: $interaction_id})
            SET i.timestamp = datetime()
            MERGE (s)-[:HAS_INTERACTION]->(i)

            WITH i
            CALL (i) {
              WITH i WHERE $intent <> ""
              MERGE (n:Intent {name: $intent})
              MERGE (i)-[:HAS_INTENT]->(n)
            }

            WITH i
            CALL (i) {
              WITH i WHERE $topic <> ""
              MERGE (t:Topic {name: $topic})
              MERGE (i)-[:RELATES_TO]->(t)
              WITH t, i
              MATCH (u:User)-[:HAS_SESSION]->(:Session)-[:HAS_INTERACTION]->(i)
              MERGE (u)-[r:INTERESTED_IN]->(t)
              ON CREATE SET r.weight = 1,
                            r.first_seen = datetime(),
                            r.last_seen  = datetime()
              ON MATCH  SET r.weight    = r.weight + 1,
                            r.last_seen = datetime()
            }

            WITH i
            CALL (i) {
              WITH i WHERE $prev_id <> "" AND $prev_id IS NOT NULL
              MERGE (prev:Interaction {id: $prev_id})
              MERGE (i)-[:FOLLOWS]->(prev)
            }

            RETURN i
            """,
            session_id=data["session_id"],
            interaction_id=data["interaction_id"],
            intent=data.get("intent", ""),
            topic=data.get("topic", ""),
            prev_id=data.get("prev_interaction_id"),
        )).consume()

        # ── 2. Entities + BELONGS_TO topic taxonomy ──
        if entities:
            await (await tx.run(
                """
                UNWIND $entities AS ent
                MATCH (i:Interaction {id: $interaction_id})
                MERGE (e:Entity {name: ent.name})
                SET e.type = coalesce(ent.type, "General")
                MERGE (i)-[:MENTIONS]->(e)
                WITH e
                WHERE $topic <> ""
                MATCH (t:Topic {name: $topic})
                MERGE (e)-[:BELONGS_TO]->(t)
                """,
                interaction_id=data["interaction_id"],
                entities=entities,
                topic=data.get("topic", ""),
            )).consume()

        # ── 3. Entity co-occurrence edges (richer cross-entity relationships) ──
        if pairs:
            await (await tx.run(
                """
                UNWIND $pairs AS pair
                MATCH (e1:Entity {name: pair.a}), (e2:Entity {name: pair.b})
                MERGE (e1)-[r:CO_OCCURS_WITH]->(e2)
                ON CREATE SET r.count = 1
                ON MATCH  SET r.count = r.count + 1
                """,
                pairs=pairs,
            )).consume()

    # ------------------------------------------------------------------
    # Public reads
    # ------------------------------------------------------------------

    async def get_routing_signals(self, session_id: str) -> dict:
        """Depth + continuity via simple aggregation — no variable-length paths."""
        if not self._driver:
            return {"depth": 0, "continuity": 0.0}
        async with self._driver.session() as session:
            result = await session.run(
                """
                MATCH (s:Session {id: $session_id})-[:HAS_INTERACTION]->(i:Interaction)
                OPTIONAL MATCH (i)-[:FOLLOWS]->(prev:Interaction)
                RETURN count(DISTINCT i) AS depth, count(prev) AS chained
                """,
                session_id=session_id,
            )
            rec = await result.single()
            if rec and rec["depth"] > 0:
                depth = rec["depth"]
                return {
                    "depth": depth,
                    "continuity": min(rec["chained"] / depth, 1.0),
                }
        return {"depth": 0, "continuity": 0.0}

    async def get_related_context(self, user_id: str, query: str, limit: int = 5) -> dict:
        """Topics ranked by interest weight + recency; entities from last 30 days."""
        if not self._driver:
            return {"topics": [], "entities": []}
        async with self._driver.session() as session:
            result = await session.run(
                """
                MATCH (u:User {id: $user_id})
                OPTIONAL MATCH (u)-[r:INTERESTED_IN]->(t:Topic)
                WITH u, t, r
                ORDER BY r.weight DESC, r.last_seen DESC
                WITH u, collect(t.name) AS topics
                OPTIONAL MATCH (u)-[:HAS_SESSION]->(:Session)
                    -[:HAS_INTERACTION]->(i:Interaction)
                    -[:MENTIONS]->(e:Entity)
                WHERE i.timestamp >= datetime() - duration({days: 30})
                RETURN topics, collect(DISTINCT {name: e.name, type: e.type}) AS entities
                """,
                user_id=user_id,
            )
            rec = await result.single()
            if rec:
                entities = [e for e in (rec["entities"] or []) if e.get("name")]
                return {
                    "topics":   rec["topics"][:limit],
                    "entities": entities[:limit],
                }
        return {"topics": [], "entities": []}


graph_client = GraphClient()
