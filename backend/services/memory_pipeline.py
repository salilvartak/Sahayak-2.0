import json
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

    async def build_memory_context(self, user_id: str, query: str):
        """
        Fetch relevant nodes from Neo4j and return structured context for LLM.
        """
        try:
            context_data = await graph_client.get_related_context(user_id, query)
            
            # Format topics for prompt
            topics = context_data.get("topics", [])
            topics_str = ", ".join([str(t) for t in topics]) if topics else "None yet"
            
            # Format entities safely
            entities = context_data.get("entities", [])
            formatted_entities = []
            for e in entities:
                if isinstance(e, dict):
                    name = e.get("name", "Unknown")
                    etype = e.get("type", "Thing")
                    formatted_entities.append(f"{name} ({etype})")
                else:
                    formatted_entities.append(str(e))
            
            entities_str = ", ".join(formatted_entities) if formatted_entities else "None"
            
            context_summary = f"User is interested in: {topics_str}. Recently mentioned things: {entities_str}."
            return context_summary
        except Exception as e:
            print(f"Could not build memory context: {e}")
            return "No previous memory context found for this user."

memory_pipeline = MemoryPipeline()
