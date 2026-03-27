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
                max_connection_lifetime=90,   # recycle before AuraDB server closes (~30s idle)
                max_connection_pool_size=5,
                connection_timeout=15,
                keep_alive=True,
            )
            async with self._driver.session() as session:
                await session.execute_write(self._setup_schema)
            print("Neo4j Graph (Memory Storage) initialized successfully.")
        except Exception as e:
            print(f"Failed to initialize Neo4j: {e}")

    @staticmethod
    async def _setup_schema(tx):
        cmds = [
            # Uniqueness constraints
            "CREATE CONSTRAINT user_id_unique        IF NOT EXISTS FOR (u:User)        REQUIRE u.id   IS UNIQUE",
            "CREATE CONSTRAINT session_id_unique     IF NOT EXISTS FOR (s:Session)     REQUIRE s.id   IS UNIQUE",
            "CREATE CONSTRAINT interaction_id_unique IF NOT EXISTS FOR (i:Interaction) REQUIRE i.id   IS UNIQUE",
            "CREATE CONSTRAINT category_name_unique  IF NOT EXISTS FOR (c:Category)    REQUIRE c.name IS UNIQUE",
            # Indexed lookups
            "CREATE INDEX entity_name   IF NOT EXISTS FOR (e:Entity)  ON (e.name)",
            "CREATE INDEX keyword_value IF NOT EXISTS FOR (k:Keyword)  ON (k.value)",
            "CREATE INDEX intent_name   IF NOT EXISTS FOR (n:Intent)   ON (n.name)",
        ]
        for cmd in cmds:
            await (await tx.run(cmd)).consume()

    # ── Internal helpers ──────────────────────────────────────────────────────

    async def _safe_run(self, func, *args, **kwargs):
        if not self._driver:
            await self.init()
        for attempt in range(2):
            try:
                return await func(*args, **kwargs)
            except Exception as e:
                err = str(e)
                is_connection_err = (
                    "10054" in err
                    or "defunct" in err.lower()
                    or "connection reset" in err.lower()
                    or "broken pipe" in err.lower()
                )
                if is_connection_err and attempt == 0:
                    # Driver will open a fresh connection from pool on next attempt
                    print(f"[Graph] Connection reset — retrying once...")
                    continue
                raise

    @staticmethod
    def _normalize(text: str) -> str:
        return (text or "").strip().lower()

    @staticmethod
    def _sanitize_entities(raw: list) -> list:
        """Deduplicate entities, preserve original casing."""
        seen, out = set(), []
        for ent in raw:
            if isinstance(ent, dict):
                name  = (ent.get("name") or "").strip()
                etype = (ent.get("type") or "General").strip()
            elif isinstance(ent, str):
                name, etype = ent.strip(), "General"
            else:
                continue
            key = name.lower()
            if name and key not in seen:
                seen.add(key)
                out.append({"name": name, "type": etype})
        return out

    @staticmethod
    def _co_occurrence_pairs(entities: list) -> list:
        names = [e["name"].lower() for e in entities]
        pairs = []
        for i in range(len(names)):
            for j in range(i + 1, len(names)):
                a, b = names[i], names[j]
                pairs.append({"a": min(a, b), "b": max(a, b)})
        return pairs

    # ── Public write ──────────────────────────────────────────────────────────

    async def update_graph(self, data: dict):
        return await self._safe_run(self._update_graph_impl, data)

    async def _update_graph_impl(self, data: dict):
        # category = canonical domain (healthcare / products / …) — max 9 values
        category  = self._normalize(data.get("category", "") or "")
        sub_topic = self._normalize(data.get("sub_topic", "") or "")
        intent    = self._normalize(data.get("intent",   "") or "")
        entities  = self._sanitize_entities(data.get("entities", []))
        pairs     = self._co_occurrence_pairs(entities)
        keywords  = [
            kw.strip().lower() for kw in (data.get("keywords") or [])
            if isinstance(kw, str) and kw.strip()
        ][:6]

        norm = {**data, "category": category, "sub_topic": sub_topic, "intent": intent}

        async with self._driver.session() as session:
            # Each write is independent — a failure in enrichment (keywords/entities)
            # never rolls back the core Interaction node.
            saved, failed = [], []

            async def _run(label: str, coro):
                try:
                    await coro
                    saved.append(label)
                except Exception as e:
                    failed.append(f"{label}:{e}")

            # 1. Core — must succeed; if this fails, propagate so _safe_run can retry
            await session.execute_write(self._write_base_tx, norm)
            await session.execute_write(self._write_interaction_tx, norm)

            # 2. Enrichment — best-effort; individual failures don't abort the rest
            if category:
                await _run("interest", session.execute_write(self._write_interest_tx, norm))
            if entities:
                await _run("entities", session.execute_write(self._write_entities_tx, norm, entities, category))
            if pairs:
                await _run("cooccur", session.execute_write(self._write_cooccurrence_tx, pairs))
            if keywords:
                await _run("keywords", session.execute_write(self._write_keywords_tx, norm, keywords, category))

            status = f"saved={saved}" + (f" | skipped={failed}" if failed else "")
            print(f"[Graph] {data['interaction_id']} [{status}]")
            return True

    @staticmethod
    async def _write_base_tx(tx, data: dict):
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
    async def _write_interaction_tx(tx, data: dict):
        """Core interaction node + optional Intent + Category + FOLLOWS chain."""
        await (await tx.run(
            """
            MATCH (s:Session {id: $session_id})

            MERGE (i:Interaction {id: $interaction_id})
            SET i.timestamp       = datetime(),
                i.user_message    = coalesce($user_message, ""),
                i.language        = coalesce($language, ""),
                i.response_length = coalesce($response_length, 0),
                i.topic           = coalesce($sub_topic, ""),
                i.category        = coalesce($category, "")
            MERGE (s)-[:HAS_INTERACTION]->(i)

            WITH i
            CALL (i) {
              WITH i WHERE $intent <> ""
              MERGE (n:Intent {name: $intent})
              MERGE (i)-[:HAS_INTENT]->(n)
            }

            WITH i
            CALL (i) {
              WITH i WHERE $category <> ""
              MERGE (c:Category {name: $category})
              MERGE (i)-[:IN_CATEGORY]->(c)
            }

            WITH i
            CALL (i) {
              WITH i WHERE $prev_id <> "" AND $prev_id IS NOT NULL
              MERGE (prev:Interaction {id: $prev_id})
              MERGE (i)-[:FOLLOWS]->(prev)
            }

            RETURN i
            """,
            session_id      = data["session_id"],
            interaction_id  = data["interaction_id"],
            user_message    = data.get("user_message", ""),
            language        = data.get("language", ""),
            response_length = data.get("response_length", 0),
            intent          = data.get("intent", ""),
            sub_topic       = data.get("sub_topic", ""),
            category        = data.get("category", ""),
            prev_id         = data.get("prev_interaction_id"),
        )).consume()

    @staticmethod
    async def _write_interest_tx(tx, data: dict):
        """
        User -[:INTERESTED_IN]-> Category  (weighted, tracks sub_topics array).
        Runs after _write_interaction_tx so Category node is guaranteed to exist.
        Simple direct lookup — no chain traversal.
        """
        await (await tx.run(
            """
            MATCH (u:User {id: $user_id})
            MATCH (c:Category {name: $category})
            MERGE (u)-[r:INTERESTED_IN]->(c)
            ON CREATE SET r.weight     = 1,
                          r.first_seen = datetime(),
                          r.last_seen  = datetime(),
                          r.topics     = CASE WHEN $sub_topic <> "" THEN [$sub_topic] ELSE [] END
            ON MATCH  SET r.weight     = r.weight + 1,
                          r.last_seen  = datetime(),
                          r.topics     = CASE
                            WHEN $sub_topic = ""
                              THEN coalesce(r.topics, [])
                            WHEN $sub_topic IN coalesce(r.topics, [])
                              THEN r.topics
                            ELSE coalesce(r.topics, []) + [$sub_topic]
                          END
            """,
            user_id   = data["user_id"],
            category  = data["category"],
            sub_topic = data.get("sub_topic", ""),
        )).consume()

    @staticmethod
    async def _write_entities_tx(tx, data: dict, entities: list, category: str):
        """Entity nodes with type + MENTIONS from Interaction + BELONGS_TO Category."""
        await (await tx.run(
            """
            UNWIND $entities AS ent
            MERGE (e:Entity {name: ent.name})
            SET e.type = ent.type
            WITH e
            MATCH (i:Interaction {id: $interaction_id})
            MERGE (i)-[:MENTIONS]->(e)
            WITH e
            WHERE $category <> ""
            MATCH (c:Category {name: $category})
            MERGE (e)-[:BELONGS_TO]->(c)
            """,
            interaction_id = data["interaction_id"],
            entities       = entities,
            category       = category,
        )).consume()

    @staticmethod
    async def _write_cooccurrence_tx(tx, pairs: list):
        """Weighted co-occurrence edges between entities."""
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

    @staticmethod
    async def _write_keywords_tx(tx, data: dict, keywords: list, category: str):
        """Keyword nodes linked to Interaction and optionally to Category."""
        await (await tx.run(
            """
            UNWIND $keywords AS kw
            MERGE (k:Keyword {value: kw})
            WITH k
            MATCH (i:Interaction {id: $interaction_id})
            MERGE (i)-[:TAGGED_WITH]->(k)
            WITH k
            WHERE $category <> ""
            MATCH (c:Category {name: $category})
            MERGE (k)-[:KEYWORD_OF]->(c)
            """,
            keywords       = keywords,
            interaction_id = data["interaction_id"],
            category       = category,
        )).consume()

    # ── Public reads ──────────────────────────────────────────────────────────

    async def get_routing_signals(self, session_id: str) -> dict:
        """Session depth + continuity score."""
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
                    "depth":      depth,
                    "continuity": min(rec["chained"] / depth, 1.0),
                }
        return {"depth": 0, "continuity": 0.0}

    async def get_related_context(self, user_id: str, query: str, limit: int = 5) -> dict:
        """
        Returns routing context based on User→INTERESTED_IN→Category edges
        and recent Interaction properties (topic, category stored on node).
        """
        if not self._driver:
            return {"topics": [], "entities": [], "sub_topics": [],
                    "dominant_category": None, "recent_intents": [], "entity_types": []}

        async with self._driver.session() as session:
            result = await session.run(
                """
                MATCH (u:User {id: $user_id})

                // ── Weighted category interests ────────────────────────────
                OPTIONAL MATCH (u)-[r:INTERESTED_IN]->(c:Category)
                WITH u,
                     collect({
                       name:      c.name,
                       weight:    coalesce(r.weight, 0),
                       last_seen: r.last_seen,
                       topics:    coalesce(r.topics, [])
                     }) AS cat_rows

                // ── Recent interactions (30-day window) ───────────────────
                OPTIONAL MATCH (u)-[:HAS_SESSION]->(:Session)
                    -[:HAS_INTERACTION]->(i:Interaction)
                WHERE i.timestamp >= datetime() - duration({days: 30})

                OPTIONAL MATCH (i)-[:MENTIONS]->(e:Entity)
                OPTIONAL MATCH (i)-[:HAS_INTENT]->(n:Intent)

                RETURN cat_rows,
                       collect(DISTINCT i.topic)[..8]            AS recent_topics,
                       collect(DISTINCT {name: e.name, type: e.type}) AS entities,
                       collect(DISTINCT n.name)[..5]             AS recent_intents
                """,
                user_id=user_id,
            )
            rec = await result.single()
            if not rec:
                return {"topics": [], "entities": [], "sub_topics": [],
                        "dominant_category": None, "recent_intents": [], "entity_types": []}

            # Sort categories by weight desc
            cat_rows = sorted(
                [r for r in (rec["cat_rows"] or []) if r.get("name")],
                key=lambda r: -(r.get("weight") or 0),
            )

            # Dominant category = highest weight
            dominant_category = cat_rows[0]["name"] if cat_rows else None

            # Collect sub_topics from top categories' topics arrays
            seen_st, sub_topics = set(), []
            for row in cat_rows[:3]:
                for t in (row.get("topics") or []):
                    if t and t not in seen_st:
                        seen_st.add(t)
                        sub_topics.append(t)

            # Also include recent topics from Interaction properties
            for t in (rec["recent_topics"] or []):
                if t and t not in seen_st:
                    seen_st.add(t)
                    sub_topics.append(t)

            category_names = [r["name"] for r in cat_rows[:limit]]

            entities = [e for e in (rec["entities"] or []) if e.get("name")]
            entity_names = [e["name"] for e in entities[:limit * 2]]
            entity_types = list(dict.fromkeys(
                e["type"] for e in entities if e.get("type") and e["type"] != "General"
            ))

            return {
                "topics":            category_names,
                "sub_topics":        sub_topics[:limit],
                "dominant_category": dominant_category,
                "entities":          entity_names[:limit],
                "entity_types":      entity_types[:4],
                "recent_intents":    [i for i in (rec["recent_intents"] or []) if i][:4],
            }


graph_client = GraphClient()
