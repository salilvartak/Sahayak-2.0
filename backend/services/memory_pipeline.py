import asyncio
from services.graph_client import graph_client
from services.cosmos_client import cosmos_client


class MemoryPipeline:

    # ── Controlled vocabulary for topics (must match system_prompt) ──────────
    _VALID_TOPICS = {
        "healthcare", "products", "documents", "government",
        "agriculture", "finance", "nutrition", "education", "general",
    }

    # Fuzzy aliases the LLM might return → canonical topic
    _TOPIC_ALIASES = {
        "health": "healthcare", "medicine": "healthcare", "medical": "healthcare",
        "doctor": "healthcare", "hospital": "healthcare", "symptom": "healthcare",
        "pharmacy": "healthcare", "drug": "healthcare", "tablet": "healthcare",
        "treatment": "healthcare", "disease": "healthcare",

        "product": "products", "shopping": "products", "grocery": "products",
        "household": "products", "item": "products", "goods": "products",
        "food product": "products",

        "document": "documents", "certificate": "documents", "card": "documents",
        "aadhaar": "documents", "ration card": "documents", "license": "documents",
        "identity": "documents", "id": "documents",

        "scheme": "government", "welfare": "government", "pension": "government",
        "subsidy": "government", "benefit": "government", "yojana": "government",

        "crop": "agriculture", "farm": "agriculture", "farming": "agriculture",
        "fertilizer": "agriculture", "seed": "agriculture", "weather": "agriculture",
        "irrigation": "agriculture", "harvest": "agriculture",

        "money": "finance", "bank": "finance", "loan": "finance",
        "payment": "finance", "insurance": "finance", "savings": "finance",
        "investment": "finance",

        "food": "nutrition", "diet": "nutrition", "recipe": "nutrition",
        "ingredient": "nutrition", "cooking": "nutrition", "vegetable": "nutrition",
        "fruit": "nutrition", "grain": "nutrition",

        "school": "education", "exam": "education", "study": "education",
        "college": "education", "class": "education",
    }

    # Controlled entity types (must match system_prompt)
    _VALID_ENTITY_TYPES = {
        "Medicine", "Symptom", "Product", "Food", "Document",
        "Scheme", "Person", "Place", "Animal", "General",
    }

    # Words that carry no signal and must never become keyword nodes
    _NOISE_WORDS = {
        "general", "interaction", "question", "answer", "query", "response",
        "user", "said", "told", "asked", "this", "that", "what", "which",
        "where", "when", "whats", "identify", "object", "thing", "item",
    }

    # ── Helpers ──────────────────────────────────────────────────────────────

    def _canonical_topic(self, raw: str) -> str:
        """Map any LLM topic string to one of the 9 canonical categories."""
        t = (raw or "").strip().lower()
        if t in self._VALID_TOPICS:
            return t
        return self._TOPIC_ALIASES.get(t, "general")

    def _valid_entity_type(self, etype: str) -> str:
        """Return type if in vocabulary, otherwise 'General'."""
        return etype if etype in self._VALID_ENTITY_TYPES else "General"

    def _sanitize_memory(self, extracted: dict) -> dict:
        """
        Normalise raw LLM memory output:
        - Validate/coerce topic and entity types to controlled vocabulary
        - Ensure sub_topic and keywords are present
        - Clean entity list
        """
        raw_entities = extracted.get("entities") or []
        entities = []
        seen = set()
        for ent in raw_entities[:5]:
            if isinstance(ent, str):
                ent = {"name": ent, "type": "General"}
            name = (ent.get("name") or "").strip()
            if not name or name.lower() in seen:
                continue
            seen.add(name.lower())
            entities.append({
                "name": name,
                "type": self._valid_entity_type(ent.get("type", "General")),
            })

        topic = self._canonical_topic(extracted.get("topic", ""))

        raw_sub = (extracted.get("sub_topic") or "").strip().lower()
        sub_topic = raw_sub if raw_sub else topic  # fallback to topic

        raw_kw = extracted.get("keywords") or []
        keywords = [
            kw.strip().lower() for kw in raw_kw
            if isinstance(kw, str)
            and kw.strip()
            and kw.strip().lower() not in self._NOISE_WORDS
            and len(kw.strip()) > 2
        ][:6]

        # If LLM gave no keywords, derive from entity names + meaningful sub_topic words
        if not keywords:
            from_entities = [e["name"].lower() for e in entities]
            from_subtopic = [
                w for w in sub_topic.split()
                if len(w) > 3 and w not in self._NOISE_WORDS
            ]
            keywords = list(dict.fromkeys(from_entities + from_subtopic))[:6]

        return {
            "entities":  entities,
            "intent":    (extracted.get("intent") or "general interaction").strip(),
            "topic":     topic,
            "sub_topic": sub_topic,
            "keywords":  keywords,
        }

    def _has_useful_signal(self, memory: dict) -> bool:
        """Return False when the memory dict carries no real information."""
        has_entities = bool(memory.get("entities"))
        has_keywords = bool(memory.get("keywords"))
        topic = memory.get("topic", "general")
        sub_topic = memory.get("sub_topic", "general")
        intent = (memory.get("intent") or "").lower()
        # Must have at least one of: named entities, specific keywords,
        # a non-generic topic, a non-generic sub_topic
        non_trivial_topic = topic != "general"
        non_trivial_sub   = sub_topic not in ("general", topic, "")
        non_trivial_intent = intent not in ("general interaction", "general", "")
        return has_entities or has_keywords or non_trivial_topic or non_trivial_sub or non_trivial_intent

    # ── Public API ────────────────────────────────────────────────────────────

    async def save_interaction_memory(
        self,
        user_id: str,
        session_id: str,
        interaction_id: str,
        user_message: str,
        ai_response_text: str,
        extracted_memory: dict,
        prev_interaction_id: str = None,
        language: str | None = None,
    ):
        if isinstance(extracted_memory, dict) and extracted_memory:
            memory = self._sanitize_memory(extracted_memory)
        else:
            print(f"[Memory] No extracted memory for {interaction_id} — skipping Neo4j")
            return

        if not self._has_useful_signal(memory):
            print(f"[Memory] Trivial signal for {interaction_id} "
                  f"(topic={memory.get('topic')} sub={memory.get('sub_topic')}) — skipping Neo4j")
            return

        # topic = canonical category (e.g. "healthcare")
        # sub_topic = specific topic node (e.g. "fever tablet")
        graph_data = {
            "user_id":            user_id,
            "session_id":         session_id,
            "interaction_id":     interaction_id,
            "user_message":       user_message,
            "language":           language or "",
            "response_length":    len(ai_response_text or ""),
            "entities":           memory["entities"],
            "intent":             memory["intent"],
            "topic":              memory["sub_topic"],   # specific Topic node
            "sub_topic":          memory["sub_topic"],
            "category":           memory["topic"],       # broad Category node
            "keywords":           memory["keywords"],
            "prev_interaction_id": prev_interaction_id,
        }

        try:
            await graph_client.update_graph(graph_data)
            print(f"Neo4j updated for interaction {interaction_id} "
                  f"[topic={memory['topic']} → {memory['sub_topic']}, "
                  f"kw={memory['keywords'][:3]}]")
        except Exception as e:
            print(f"Neo4j update failed, but continuing background task... {e}")

    async def build_routing_context(self, user_id: str, session_id: str, query: str):
        """Fetch Neo4j signals for the router — runs in parallel."""
        try:
            context_data, metrics = await asyncio.gather(
                graph_client.get_related_context(user_id, query),
                graph_client.get_routing_signals(session_id),
            )
            return {
                "dominant_topics":    context_data.get("topics", []),
                "dominant_category":  context_data.get("dominant_category"),
                "recent_sub_topics":  context_data.get("sub_topics", []),
                "session_depth":      metrics["depth"],
                "continuity_score":   metrics["continuity"],
                "recent_intents":     context_data.get("recent_intents", []),
                "entities_mentioned": context_data.get("entities", []),
                "entity_types":       context_data.get("entity_types", []),
                "user_interests":     context_data.get("topics", []),
                "inferred_domain":    context_data.get("dominant_category"),
                "expertise_hint":     "unknown",
                "last_model_used":    None,
            }
        except Exception as e:
            print(f"Error building routing context: {e}")
            return {
                "dominant_topics":   [],
                "dominant_category": None,
                "recent_sub_topics": [],
                "session_depth":     0,
                "continuity_score":  0.0,
                "recent_intents":    [],
                "entities_mentioned": [],
                "entity_types":      [],
                "user_interests":    [],
                "inferred_domain":   None,
                "expertise_hint":    "unknown",
                "last_model_used":   None,
            }


memory_pipeline = MemoryPipeline()
