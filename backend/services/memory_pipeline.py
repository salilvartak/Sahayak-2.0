import asyncio
from services.graph_client import graph_client
from services.cosmos_client import cosmos_client

class MemoryPipeline:
    async def save_interaction_memory(self, user_id: str, session_id: str, interaction_id: str, user_message: str, ai_response_text: str, extracted_memory: dict, prev_interaction_id: str = None):
        """
        Takes pre-extracted memory and user-facing text and updates Neo4j.
        This no longer calls LLM internally, saving quota!
        """
        # Ensure memory has correct format
        memory = extracted_memory if isinstance(extracted_memory, dict) else {
            "entities": [],
            "intent": "general interaction",
            "topic": "none"
        }
        
        # Update Neo4j Graph
        graph_data = {
            "user_id": user_id,
            "session_id": session_id,
            "interaction_id": interaction_id,
            "text": user_message,
            "entities": memory.get("entities", []),
            "intent": memory.get("intent", ""),
            "topic": memory.get("topic", ""),
            "prev_interaction_id": prev_interaction_id
        }
        
        try:
            await graph_client.update_graph(graph_data)
            print(f"Neo4j updated for interaction {interaction_id}")
        except Exception as e:
            print(f"Neo4j update failed, but continuing background task... {e}")

    async def build_routing_context(self, user_id: str, session_id: str, query: str):
        """Fetch all signals from Neo4j for the Smart Router."""
        try:
            # Fetch graph context and session metrics in parallel
            context_data, metrics = await asyncio.gather(
                graph_client.get_related_context(user_id, query),
                graph_client.get_routing_signals(session_id),
            )
            
            # 3. Construct the router-ready memory object
            # Note: inferred_domain and expertise_hint would ideally come from 
            # user profiles/past intents, defaulting to null/unknown for now.
            return {
                "dominant_topics": context_data.get("topics", []),
                "session_depth": metrics["depth"],
                "continuity_score": metrics["continuity"],
                "recent_intents": [], # Placeholder for intent history
                "user_interests": context_data.get("topics", []),
                "inferred_domain": None,
                "expertise_hint": "unknown",
                "last_model_used": None,
                "entities_mentioned": [str(e.get("name")) for e in context_data.get("entities", []) if isinstance(e, dict)]
            }
        except Exception as e:
            print(f"Error building routing context: {e}")
            return {
                "dominant_topics": [],
                "session_depth": 0,
                "continuity_score": 0.0,
                "recent_intents": [],
                "user_interests": [],
                "inferred_domain": None,
                "expertise_hint": "unknown",
                "last_model_used": None,
                "entities_mentioned": []
            }

memory_pipeline = MemoryPipeline()
