from typing import TypedDict, Annotated, List, Optional
import json
import uuid
from langgraph.graph import StateGraph, END
from services.gemini_service import gemini_service
from services.cosmos_client import cosmos_client
from services.memory_pipeline import memory_pipeline
from services.graph_client import graph_client

# Define the state for the LangGraph pipeline
class AgentState(TypedDict):
    user_id: str
    session_id: str
    interaction_id: str
    query: str
    language: str
    image_bytes: Optional[bytes]
    response_text: str
    extracted_memory: Optional[dict]  # Newly added field
    metadata: dict
    prev_interaction_id: Optional[str]
    blob_name: Optional[str]

# --- Nodes ---

async def call_llm_node(state: AgentState):
    """Generates a response using Gemini, returning both AI text and memory."""
    
    # Fetch memory context from Neo4j
    memory_context = await memory_pipeline.build_memory_context(
        state["user_id"], 
        state["query"]
    )
    
    # Enrich the query
    enriched_query = f"""
    Memory Context: {memory_context}
    
    Current User Query: {state["query"]}
    """
    
    # Gemini now returns a dict { "ai_response": "...", "memory": { ... } }
    combined_result = await gemini_service.get_response(
        enriched_query, 
        state["image_bytes"], 
        state["language"]
    )
    
    # Update state with the results
    return {
        "response_text": combined_result.get("ai_response", "AI could not generate a response."),
        "extracted_memory": combined_result.get("memory", {})
    }

async def history_write_node(state: AgentState):
    """
    Saves the interaction to Cosmos DB and updates the Knowledge Graph using already-extracted memory.
    """
    try:
        print(f"DEBUG: Processing history for interaction {state.get('interaction_id')}. Blob: {state.get('blob_name')}")
        
        # 1. Save to Cosmos DB (Primary Interaction Store)
        data = {
            "user_id": state["user_id"],
            "session_id": state["session_id"],
            "interaction_id": state["interaction_id"],
            "user_message": state["query"],
            "ai_response": state["response_text"],
            "language": state["language"],
            "blob_name": state.get("blob_name"),
            "metadata": state.get("metadata", {}),
        }
        await cosmos_client.save_interaction(data)
        
        # 2. Save directly to Neo4j (Memory Graph)
        # Using the memory ALREADY extracted by the same LLM call that answered the user!
        await memory_pipeline.save_interaction_memory(
            user_id=state["user_id"],
            session_id=state["session_id"],
            interaction_id=state["interaction_id"],
            user_message=state["query"],
            ai_response_text=state["response_text"],
            extracted_memory=state.get("extracted_memory", {}),
            prev_interaction_id=state.get("prev_interaction_id")
        )
    except Exception as e:
        import traceback
        print(f"CRITICAL ERROR in history_write_node: {e}")
        traceback.print_exc()
    
    return state

# --- Pipeline Definition ---

def create_agent_graph():
    workflow = StateGraph(AgentState)

    # Add nodes
    workflow.add_node("call_llm", call_llm_node)
    workflow.add_node("history_write", history_write_node)

    # Add edges
    workflow.set_entry_point("call_llm")
    workflow.add_edge("call_llm", "history_write")
    workflow.add_edge("history_write", END)

    return workflow.compile()

# Global compiled graph
agent_graph = create_agent_graph()
