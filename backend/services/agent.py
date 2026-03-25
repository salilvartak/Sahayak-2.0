from typing import TypedDict, Annotated, List, Optional
import json
import uuid
from langgraph.graph import StateGraph, END
from services.router_service import router_service
from services.azure_ai_service import azure_ai_service
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
    extracted_memory: Optional[dict]
    metadata: dict
    prev_interaction_id: Optional[str]
    blob_name: Optional[str]
    # PART 7 — Interrupt context
    was_interruption: Optional[bool]
    partial_response: Optional[str]
    previous_intent: Optional[str]

# --- Nodes ---

async def call_llm_node(state: AgentState):
    """Router-based LLM node that picks the best model and generates the final response."""
    
    # 1. Fetch memory context and signals from Neo4j
    routing_context = await memory_pipeline.build_routing_context(
        state["user_id"], 
        state["session_id"],
        state["query"]
    )
    
    # 2. Call the Smart Router to get selected_model and enriched_prompt
    router_resp = await router_service.route_request(state, routing_context)
    selected_model = router_resp.get("selected_model", "gpt-4o")
    enriched_prompt = router_resp.get("enriched_system_prompt", "")

    # PART 7 — Inject interrupt context so the LLM can continue naturally
    if state.get("was_interruption") and state.get("partial_response"):
        partial = state["partial_response"][:300]
        enriched_prompt += (
            "\n\n[INTERRUPT CONTEXT: The user interrupted your previous response. "
            f"You had said: '{partial}'. "
            "Continue the conversation naturally — acknowledge the interruption "
            "only if helpful, then address the new request directly.]"
        )
        print(f"[Agent] Interrupt context injected. Partial: '{partial[:80]}...'")
    
    print(f"[Router] Chosen Model: {selected_model} (Score: {router_resp.get('routing_score')})")
    
    # 3. Call the Workhorse model (using the current azure_ai_service but we pass the model name)
    # Note: Currently azure_ai_service uses a hard-coded endpoint. 
    # Let's use the enriched system prompt instead of the old one.
    combined_result = await azure_ai_service.get_response_with_custom_prompt(
        prompt=state["query"],
        image_bytes=state["image_bytes"],
        language_name=state["language"],
        custom_system_prompt=enriched_prompt,
        model_override=selected_model
    )
    
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
