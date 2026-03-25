import json
import re
import sys
import base64
import asyncio
import httpx
from config import settings
from prompts import system_prompt

def _log(msg: str):
    """Force-flushed, encoding-safe print for Windows terminals (cp1252 safe)."""
    try:
        # Encode to stdout's encoding (cp1252 on Windows), replacing un-encodable chars
        safe = msg.encode(sys.stdout.encoding or "utf-8", errors="replace") \
                  .decode(sys.stdout.encoding or "utf-8", errors="replace")
        print(safe, flush=True)
    except Exception:
        pass  # Never let a log call crash the request handler


class AzureAIService:
    """
    Primary LLM service using Azure AI Model Router (OpenAI-compatible endpoint).
    Falls back to a structured error response if the call fails.
    """

    def __init__(self):
        self.endpoint = settings.AZURE_AI_MODEL_ROUTER_ENDPOINT
        self.api_key = settings.AZURE_AI_MODEL_ROUTER_KEY

        if not self.endpoint or not self.api_key:
            _log("WARNING: Azure AI Model Router endpoint or key not configured.")
        else:
            _log(f"[AzureAI] Service initialized. Endpoint: {self.endpoint[:60]}...")

    async def get_response(
        self,
        prompt: str,
        image_bytes: bytes | None,
        language_name: str
    ) -> dict:
        """
        Calls Azure AI Model Router with optional image support.
        Returns a dict: { "ai_response": str, "memory": { "entities": [], "intent": str, "topic": str } }
        """
        lang_cap = language_name.capitalize() if language_name else "English"
        _log(f"\n[AzureAI] --- New Request ---")
        _log(f"[AzureAI] language : '{language_name}' -> '{lang_cap}'")

        sys_prompt = system_prompt.get_structured_system_prompt(lang_cap)

        # Append a hard language enforcement line to the user prompt.
        # This is critical: models follow end-of-prompt instructions most reliably.
        lang_enforcement = f"\n\n[IMPORTANT: You MUST respond ONLY in {lang_cap}. Do NOT use any other language.]"
        prompt_with_lang = prompt + lang_enforcement

        # Build user message content
        if image_bytes:
            # Detect MIME type
            mime_type = "image/jpeg"
            if image_bytes[:4] == b'\x89PNG':
                mime_type = "image/png"
            elif image_bytes[4:8] == b'ftyp':
                mime_type = "image/heic"
            _log(f"[AzureAI] image    : {len(image_bytes)} bytes ({mime_type})")

            b64_image = base64.b64encode(image_bytes).decode("utf-8")
            user_content = [
                {"type": "text", "text": prompt_with_lang},
                {
                    "type": "image_url",
                    "image_url": {
                        "url": f"data:{mime_type};base64,{b64_image}"
                    }
                }
            ]
        else:
            _log(f"[AzureAI] image    : None")
            user_content = prompt_with_lang

        messages = [
            {"role": "system", "content": sys_prompt},
            {"role": "user", "content": user_content}
        ]

        payload = {
            "messages": messages,
            "temperature": 0.3,
            "max_tokens": 4096,
            "response_format": {"type": "json_object"}
        }

        headers = {
            "Content-Type": "application/json",
            "api-key": self.api_key
        }

        # Retry loop: up to 3 attempts with exponential backoff
        last_error = "Unknown"
        for attempt in range(3):
            try:
                async with httpx.AsyncClient(timeout=30.0) as client:
                    resp = await client.post(
                        self.endpoint,
                        headers=headers,
                        json=payload
                    )

                if resp.status_code == 200:
                    data = resp.json()
                    choice = data.get("choices", [{}])[0]
                    content = choice.get("message", {}).get("content", "")
                    
                    if not content:
                        finish_reason = choice.get("finish_reason", "unknown")
                        _log(f"[AzureAI] Error: Empty content received. Finish reason: {finish_reason}")
                        if finish_reason == "content_filter":
                            return self._fallback_error(lang_cap, "Azure content filter blocked the response.")
                        # Log the whole data object to see what's happening
                        _log(f"[AzureAI] Full Response Data: {data}")
                        return self._fallback_error(lang_cap, "Empty response from AI.")

                    _log(f"[AzureAI] OK - Success (Attempt {attempt + 1})")
                    return self._parse_response(content, lang_cap)

                elif resp.status_code in (429, 503):
                    wait_sec = (attempt + 1) * 2
                    _log(f"[AzureAI] WARN - Status {resp.status_code}. Retrying in {wait_sec}s... (Attempt {attempt + 1})")
                    last_error = f"HTTP {resp.status_code}: {resp.text[:200]}"
                    await asyncio.sleep(wait_sec)
                    continue

                else:
                    last_error = f"HTTP {resp.status_code}: {resp.text[:200]}"
                    _log(f"[AzureAI] ERROR - {resp.status_code}: {resp.text[:200]}")
                    break

            except httpx.TimeoutException:
                last_error = "Request timed out"
                _log(f"[AzureAI] TIMEOUT (Attempt {attempt + 1})")
                if attempt < 2:
                    await asyncio.sleep((attempt + 1) * 2)
                continue
            except Exception as e:
                last_error = f"{type(e).__name__}: {e}"
                _log(f"[AzureAI] UNEXPECTED ERROR: {last_error}")
                break

        _log(f"[AzureAI] TOTAL FAILURE. Last error: {last_error}")
        return self._fallback_error(language_name, last_error)

    def _parse_response(self, content: str, language_name: str) -> dict:
        """Parse JSON string from the LLM into the expected dict format."""
        try:
            raw = content.strip()
            # Strip markdown code fences if present
            if "```json" in raw:
                raw = re.search(r"```json\s*(.*?)\s*```", raw, re.DOTALL).group(1)
            elif "```" in raw:
                raw = re.search(r"```\s*(.*?)\s*```", raw, re.DOTALL).group(1)

            result = json.loads(raw)
            # Validate expected keys
            if "ai_response" not in result:
                result["ai_response"] = system_prompt.get_unclear_message(language_name)
            if "memory" not in result:
                result["memory"] = {"entities": [], "intent": "", "topic": ""}
            return result
        except (json.JSONDecodeError, AttributeError, Exception) as e:
            _log(f"[AzureAI] Info: Not raw JSON, attempting text-wrap fallback.")
            # If it's not JSON, assume the whole content is the response
            return {
                "ai_response": content.strip(),
                "memory": {"entities": [], "intent": "conversational", "topic": "general"}
            }

    def _fallback_error(self, lang: str, error_msg: str) -> dict:
        return {
            "ai_response": system_prompt.get_unclear_message(lang),
            "memory": {"entities": [], "intent": f"error: {error_msg}", "topic": "system"}
        }

# Global instance — used by agent.py
azure_ai_service = AzureAIService()
# Aliases so existing imports of gemini_service / llm_service keep working
llm_service = azure_ai_service
gemini_service = azure_ai_service
