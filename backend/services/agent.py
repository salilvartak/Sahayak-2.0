from typing import TypedDict, Annotated, List, Optional
import json
import uuid
from langgraph.graph import StateGraph, END
from services.azure_ai_service import azure_ai_service
from services.cosmos_client import cosmos_client
from services.memory_pipeline import memory_pipeline
from services.graph_client import graph_client
from prompts import system_prompt as sp

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
    barcode: Optional[str]
    product_context: Optional[str]
    user_query: Optional[str]

# --- Python-based routing (no LLM round-trip) ---

def _route_request(state: AgentState, routing_context: dict, streaming: bool = False) -> tuple:
    """Select model and build enriched prompt without an extra LLM call.

    streaming=True uses the plain-text base prompt (no JSON output format),
    suitable for the streaming SSE pipeline.
    """
    depth = routing_context.get("session_depth", 0)
    continuity = routing_context.get("continuity_score", 0.0)
    has_image = state.get("image_bytes") is not None
    language = state.get("language", "en")
    is_non_english = not language.startswith("en")
    # Use original user question for complexity — state["query"] is the enriched version
    # which includes product context and memory and is always long
    raw_query = state.get("user_query") or state.get("query") or ""
    query_words = len(raw_query.split())

    # Weighted routing score
    score = 0
    score += 20 if depth >= 5 else (12 if depth >= 3 else 5)
    score += int(continuity * 20)
    score += 20 if query_words > 15 else 5
    score += 20 if has_image else 0
    score += 10 if is_non_english else 0

    # Threshold 50: simple Hindi+image queries score ~40 → mini;
    # long/deep/continuing conversations score 50+ → gpt-4o
    model = "gpt-4o" if score >= 50 else "gpt-4o-mini"

    # Build enriched system prompt = base + optional memory context block
    lang_cap = language.capitalize() if language else "English"
    if streaming:
        base_prompt = sp.get_system_prompt(lang_cap)
    else:
        base_prompt = sp.get_structured_system_prompt(lang_cap)

    topics = routing_context.get("dominant_topics", [])
    entities = routing_context.get("entities_mentioned", [])
    prev_id = state.get("prev_interaction_id")

    dominant_category = routing_context.get("dominant_category")
    sub_topics        = routing_context.get("recent_sub_topics", [])
    recent_intents    = routing_context.get("recent_intents", [])
    entity_types      = routing_context.get("entity_types", [])

    has_context = topics or entities or dominant_category or (prev_id and depth > 1)
    if has_context:
        memory_block = "\n\n## User Memory Context\n"

        if dominant_category:
            memory_block += f"- User's domain: {dominant_category}\n"

        if topics:
            topic_str = ", ".join(str(t) for t in topics[:3])
            if sub_topics:
                topic_str += f" (specifically: {', '.join(str(s) for s in sub_topics[:3])})"
            memory_block += f"- Topics of interest: {topic_str}\n"

        if recent_intents:
            memory_block += f"- Recent goals: {', '.join(str(i) for i in recent_intents[:3])}\n"

        if entity_types:
            memory_block += f"- Entity types discussed: {', '.join(entity_types[:3])}\n"

        if entities:
            memory_block += f"- Known entities: {', '.join(str(e) for e in entities[:5])}\n"

        if prev_id and depth > 1:
            memory_block += (
                f"- Continuing conversation ({depth} turns, "
                f"continuity {continuity:.0%}). Avoid repeating prior explanations.\n"
            )
        base_prompt = memory_block + base_prompt

    print(f"[Router] Model: {model} | score={score} | depth={depth} | streaming={streaming} | image={'yes' if has_image else 'no'}")
    return model, base_prompt


async def build_streaming_context(state: AgentState) -> tuple:
    """Fetch memory context and route for the streaming pipeline.

    Returns (model, plain_text_system_prompt) — no JSON output format,
    suitable for feeding tokens directly to TTS as they stream.
    """
    routing_context = await memory_pipeline.build_routing_context(
        state["user_id"],
        state["session_id"],
        state["query"]
    )
    model, prompt = _route_request(state, routing_context, streaming=True)

    # Inject interrupt context if applicable
    if state.get("was_interruption") and state.get("partial_response"):
        partial = state["partial_response"][:300]
        prompt += (
            "\n\n[INTERRUPT CONTEXT: The user interrupted your previous response. "
            f"You had said: '{partial}'. "
            "Continue naturally — acknowledge the interruption only if helpful.]"
        )

    return model, prompt


# --- Nodes ---

async def call_llm_node(state: AgentState):
    """Fetch memory context, route, then call the workhorse LLM in one pass."""

    # 1. Fetch memory context from Neo4j
    routing_context = await memory_pipeline.build_routing_context(
        state["user_id"],
        state["session_id"],
        state["query"]
    )

    # 2. Python-based routing — no extra LLM call
    selected_model, enriched_prompt = _route_request(state, routing_context)

    # 3. Inject interrupt context if applicable
    if state.get("was_interruption") and state.get("partial_response"):
        partial = state["partial_response"][:300]
        enriched_prompt += (
            "\n\n[INTERRUPT CONTEXT: The user interrupted your previous response. "
            f"You had said: '{partial}'. "
            "Continue naturally — acknowledge the interruption only if helpful.]"
        )

    # 4. Single LLM call to the workhorse model
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

_LANGUAGE_BCP47 = {
    'hindi':     'hi-IN',
    'marathi':   'mr-IN',
    'english':   'en-IN',
    'telugu':    'te-IN',
    'tamil':     'ta-IN',
    'kannada':   'kn-IN',
    'malayalam': 'ml-IN',
    'gujarati':  'gu-IN',
    'punjabi':   'pa-IN',
    'bengali':   'bn-IN',
    'odia':      'or-IN',
    'assamese':  'as-IN',
    'urdu':      'ur-IN',
}

def _memory_is_empty(memory: dict | None) -> bool:
    """True when memory carries no useful signal (streaming default or missing)."""
    if not memory:
        return True
    topic = (memory.get("topic") or "").strip().lower()
    intent = (memory.get("intent") or "").strip().lower()
    has_entities = bool(memory.get("entities"))
    has_keywords = bool(memory.get("keywords"))
    return (
        not has_entities
        and not has_keywords
        and topic in ("", "general")
        and intent in ("", "general interaction", "general", "conversational")
    )


async def history_write_node(state: AgentState):
    """
    Saves the interaction to Cosmos DB and updates the Knowledge Graph.
    For streaming responses (extracted_memory is empty), runs a fast background
    gpt-4o-mini call to extract memory from the completed response text.
    """
    try:
        print(f"DEBUG: Processing history for interaction {state.get('interaction_id')}. Blob: {state.get('blob_name')}")

        # Normalise language to BCP-47 (payload may carry an enum name like 'hindi')
        raw_lang = state.get("language", "")
        language_code = (
            raw_lang if '-' in raw_lang
            else _LANGUAGE_BCP47.get(raw_lang.lower(), 'hi-IN')
        )

        user_message = state.get("user_query") or state["query"]

        # For streaming responses the extracted_memory is always empty because
        # the stream uses plain-text output (no JSON format).  Run a fast
        # gpt-4o-mini extraction from the completed response text instead.
        extracted_memory = state.get("extracted_memory") or {}
        if _memory_is_empty(extracted_memory):
            print(f"[MemExtract] Streaming path — extracting memory for {state.get('interaction_id')}")
            extracted_memory = await azure_ai_service.extract_memory(
                query=user_message,
                response_text=state.get("response_text", ""),
                language_name=raw_lang,
            )

        # 1. Save to Cosmos DB
        data = {
            "user_id":        state["user_id"],
            "session_id":     state["session_id"],
            "interaction_id": state["interaction_id"],
            "user_message":   user_message,
            "ai_response":    state["response_text"],
            "language":       language_code,
            "blob_name":      state.get("blob_name"),
            "metadata":       state.get("metadata", {}),
        }
        await cosmos_client.save_interaction(data)

        # 2. Save to Neo4j — use freshly extracted memory
        await memory_pipeline.save_interaction_memory(
            user_id=state["user_id"],
            session_id=state["session_id"],
            interaction_id=state["interaction_id"],
            user_message=user_message,
            ai_response_text=state["response_text"],
            extracted_memory=extracted_memory,
            prev_interaction_id=state.get("prev_interaction_id"),
            language=language_code,
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
