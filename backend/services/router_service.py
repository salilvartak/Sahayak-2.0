import json
from services.azure_ai_service import azure_ai_service
from prompts import system_prompt

class RouterService:
    @property
    def router_prompt(self):
        return """
You are a smart routing layer in a multimodal AI assistant pipeline. Your job is to analyze the incoming request and all available signals, then decide which model to route to and construct the final enriched prompt for that model.

---

## YOUR INPUTS

You will receive a JSON object with the following fields:
{
  "user_id": "string",
  "session_id": "string",
  "query": "string — the user's transcribed voice input",
  "language": "string — BCP-47 code e.g. en-US, ar-SA, hi-IN",
  "image_bytes": "base64 string or null",
  "prev_interaction_id": "string or null",
  "azure_speech_metadata": { "confidence": 0.0–1.0, "duration_ms": number, "snr_db": number },
  "memory_context": {
    "dominant_topics": ["string"],
    "session_depth": number,
    "continuity_score": 0.0–1.0,
    "recent_intents": ["string"],
    "user_interests": ["string"],
    "inferred_domain": "string or null",
    "expertise_hint": "novice | returning | expert | unknown",
    "last_model_used": "string or null",
    "entities_mentioned": ["string"]
  }
}

---

## STEP 1 — COMPUTE A ROUTING SCORE (0–100)

Calculate a composite score using these weighted signals:

| Signal | Weight | How to score |
|---|---|---|
| session_depth | 20 | depth >= 5 -> 20, depth 3–4 -> 12, depth 1–2 -> 5 |
| continuity_score | 20 | score x 20 |
| query complexity | 20 | multi-step/analytical -> 20, factual/simple -> 5 |
| image_bytes present | 15 | present -> 15, null -> 0 |
| inferred_domain | 15 | technical/medical/legal/code -> 15, general -> 5 |
| expertise_hint | 10 | expert -> 10, returning -> 6, novice -> 2 |
| language non-English | 10 | non-English -> 10, English -> 0 |

---

## STEP 2 — SCORE-BASED ROUTING (primary path)

Use this routing table:

| Score | Route to | Reason |
|---|---|---|
| 0–25 | gpt-5-nano | Simple, fast, low-cost |
| 26–45 | gpt-4o-mini | Moderate query, no image |
| 46–65 | gpt-4o | Balanced — default workhorse |
| 66–80 | gpt-5.2-chat | Deep, multi-turn, complex |
| 81–100 | claude-sonnet-4-5 | Nuanced reasoning, long context, multimodal, multilingual |

Additional hard overrides:
- image_bytes is present AND inferred_domain is medical/legal/technical -> force claude-sonnet-4-5
- language is non-English AND continuity_score > 0.7 -> force claude-sonnet-4-5
- session_depth >= 8 -> minimum gpt-5.2-chat regardless of score
- expertise_hint is expert AND domain is code/technical -> minimum gpt-4o

---

## STEP 3 — LLM FALLBACK (when score is ambiguous)

If the routing score falls in the ranges 44–48 or 63–68, reason explicitly to pick the higher/lower tier.

---

## STEP 4 — BUILD THE ENRICHED SYSTEM PROMPT

Once the model is selected, construct the system prompt to send to that model. Use this template:
```
You are a helpful, multimodal AI assistant.

## User context
- Language: {language}
- Session depth: {session_depth} turns
- Expertise level: {expertise_hint}
- Current domain: {inferred_domain or "general"}

## What this user cares about
Topics of interest: {user_interests joined by ", "}
Recent intents: {recent_intents joined by ", "}
Entities in conversation: {entities_mentioned joined by ", "}

## Conversation continuity
{if prev_interaction_id}
This is a continuing conversation (continuity score: {continuity_score}). Maintain context and avoid repeating prior explanations.
{else}
This is a new session. Introduce concepts clearly.
{endif}

## Instructions
- Respond in the user's language: {language}
- Match depth to expertise: {expertise_hint}
- {if image_bytes} An image has been provided. Analyze it in the context of the user's query. {endif}
- Be concise unless the topic demands depth
- Do not repeat information already established in the session

## OUTPUT FORMAT
You MUST return your response as a JSON object with:
1. "ai_response": Spoken text in {language}.
2. "memory": {
     "entities": List of up to 5 key entities in ENGLISH only (e.g. [{"name": "Paracetamol", "type": "Medicine"}]),
     "intent": The user's main goal in ENGLISH only (1-3 words, e.g. "identify medicine"),
     "topic": The core subject in ENGLISH only (1-2 words, e.g. "health")
   }
CRITICAL: The "memory" fields MUST always be in English script only, regardless of the user's language. Never use Hindi, Marathi, Telugu, Tamil, or any non-English script in memory fields.
```

---

## STEP 5 — OUTPUT FORMAT
Return a single JSON object with: selected_model, routing_score, routing_path, override_reason, enriched_system_prompt, routing_reasoning.
"""

    async def route_request(self, state: dict, memory_context: dict) -> dict:
        """Calls the 'Router model' to decide the workhorse model."""
        
        # 1. Prepare inputs
        # NOTE: Never send actual image bytes to the router — base64 alone is
        # ~80-120k tokens and will blow the 128k context limit.
        # The router only needs to know whether an image is present.
        router_input = {
            "user_id": state["user_id"],
            "session_id": state["session_id"],
            "query": state["query"],
            "language": state["language"],
            "image_bytes": "present" if state.get("image_bytes") else None,
            "prev_interaction_id": state.get("prev_interaction_id"),
            "azure_speech_metadata": {
                "confidence": state.get("metadata", {}).get("confidence", 0.9),
                "duration_ms": 0,
                "snr_db": 0
            },
            "memory_context": memory_context
        }

        # 2. Call Azure AI with the Router System Prompt
        # We use the existing get_response but with a override for system prompt
        try:
            # We call the base LLM (GPT-4o or similar) to do the routing
            full_prompt = f"Router Input Signals:\n{json.dumps(router_input, indent=2)}"
            
            # Using a custom internal call to bypass the normal Sahayak system prompt
            # We'll need a simple raw call in azure_ai_service later
            resp = await azure_ai_service.raw_call(
                system_message=self.router_prompt, 
                user_message=full_prompt
            )
            
            return json.loads(resp)
        except Exception as e:
            print(f"Router failure: {e}. Defaulting to gpt-4o.")
            return {
                "selected_model": "gpt-4o",
                "routing_score": 50,
                "routing_path": "fallback-default",
                "enriched_system_prompt": system_prompt.get_structured_system_prompt(state["language"])
            }

router_service = RouterService()
