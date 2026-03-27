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

        # Persistent client — reuses TCP + TLS connections across requests (~150ms saved per call)
        self._http = httpx.AsyncClient(
            limits=httpx.Limits(max_connections=10, max_keepalive_connections=5),
        )

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
            "model": "gpt-4o",
            "messages": messages,
            "temperature": 0.3,
            "max_tokens": 1024,
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
                resp = await self._http.post(
                        self.endpoint,
                        headers=headers,
                        json=payload,
                        timeout=30.0,
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
        return await self._fallback_to_gemini(prompt, image_bytes, language_name, sys_prompt)

    async def get_response_with_custom_prompt(
        self,
        prompt: str,
        image_bytes: bytes | None,
        language_name: str,
        custom_system_prompt: str,
        model_override: str = "gpt-4o"
    ) -> dict:
        """Call Workhorse model with the Router's enriched system prompt."""
        lang_cap = language_name.capitalize() if language_name else "English"

        custom_system_prompt += (
            "\n\nYou MUST return your output strictly in JSON format."
            "\nCRITICAL: The 'memory' fields (entities, intent, topic) MUST be in English only,"
            " regardless of the user's language. Never use any non-English script in memory fields."
        )

        if image_bytes:
            mime_type = "image/jpeg"
            b64_image = base64.b64encode(image_bytes).decode("utf-8")
            user_content = [
                {"type": "text", "text": prompt},
                {"type": "image_url", "image_url": {"url": f"data:{mime_type};base64,{b64_image}"}}
            ]
        else:
            user_content = prompt

        messages = [
            {"role": "system", "content": custom_system_prompt},
            {"role": "user", "content": user_content}
        ]

        payload = {
            "model": model_override,
            "messages": messages,
            "temperature": 0.5,
            "max_tokens": 2048 if image_bytes else 1024,
            "response_format": {"type": "json_object"}
        }
        headers = {"api-key": self.api_key, "Content-Type": "application/json"}

        last_error = "Unknown"
        for attempt in range(3):
            try:
                resp = await self._http.post(self.endpoint, headers=headers, json=payload, timeout=60.0)

                if resp.status_code == 200:
                    data = resp.json()
                    content = data["choices"][0]["message"]["content"]
                    return self._parse_response(content, lang_cap)

                last_error = f"HTTP {resp.status_code}"
                _log(f"[Workhorse] Attempt {attempt + 1} failed: {resp.status_code}")
                if resp.status_code in (429, 500, 503) and attempt < 2:
                    await asyncio.sleep((attempt + 1) * 2)
                    continue
                break

            except httpx.TimeoutException:
                last_error = "timeout"
                _log(f"[Workhorse] Timeout on attempt {attempt + 1}")
                if attempt < 2:
                    await asyncio.sleep((attempt + 1) * 2)
            except Exception as e:
                last_error = str(e)
                _log(f"[Workhorse] Error on attempt {attempt + 1}: {e}")
                break

        _log(f"[Workhorse] All attempts failed: {last_error}")
        return await self._fallback_to_gemini(prompt, image_bytes, language_name, custom_system_prompt)

    async def extract_memory(
        self,
        query: str,
        response_text: str,
        language_name: str = "English",
    ) -> dict:
        """
        Lightweight gpt-4o-mini call that extracts structured memory from a
        completed conversation turn.  Called as a background task after the
        streaming response finishes — does NOT block the user.

        Returns the same memory dict shape as get_response_with_custom_prompt:
        { "entities": [...], "intent": "...", "topic": "...",
          "sub_topic": "...", "keywords": [...] }
        """
        # Truncate to keep the prompt small and cheap
        q = (query or "")[:300]
        r = (response_text or "")[:600]

        extraction_prompt = f"""Extract structured memory from this conversation. Return ONLY valid JSON, nothing else.

User said: "{q}"
AI replied: "{r}"

JSON format required:
{{
  "entities": [{{"name": "English name", "type": "Medicine|Symptom|Product|Food|Document|Scheme|Person|Place|Animal|General"}}],
  "intent": "2-5 word user goal in English",
  "topic": "one of: healthcare|products|documents|government|agriculture|finance|nutrition|education|general",
  "sub_topic": "2-4 word specific aspect in English",
  "keywords": ["keyword1", "keyword2", "keyword3"]
}}"""

        payload = {
            "model": "gpt-4o",
            "messages": [
                {"role": "system", "content": "Output ONLY a raw JSON object. No markdown, no wrapper keys, no extra text. Start your response with { and end with }."},
                {"role": "user",   "content": extraction_prompt},
            ],
            "temperature": 0.0,
            "max_tokens":  500,
            # No response_format — it makes the model wrap JSON in {"final": "...escaped string..."}
        }
        headers = {"api-key": self.api_key, "Content-Type": "application/json"}
        try:
            resp = await self._http.post(
                self.endpoint, headers=headers, json=payload, timeout=15.0
            )
            if resp.status_code != 200:
                body = resp.text[:200]
                _log(f"[MemExtract] HTTP {resp.status_code}: {body}")
                return {}
            data = resp.json()
            choices = data.get("choices") or []
            if not choices:
                _log("[MemExtract] Empty choices in response")
                return {}
            content = choices[0].get("message", {}).get("content", "")
            # Strip markdown fences
            raw = content.strip()
            if raw.startswith("```"):
                raw = re.sub(r"^```[a-z]*\n?", "", raw).rstrip("`").strip()

            # Try direct parse first, then fall back to regex extraction
            memory = None
            try:
                memory = json.loads(raw)
            except json.JSONDecodeError:
                m = re.search(r"\{.*\}", raw, re.DOTALL)
                if not m:
                    _log(f"[MemExtract] No JSON found in: {raw[:120]}")
                    return {}
                memory = json.loads(m.group())

            # Unwrap if LLM nested result under a wrapper key ("final", "memory", "result", etc.)
            # Also handles when the wrapper value is itself an escaped JSON string
            depth = 0
            while "topic" not in memory and len(memory) == 1 and depth < 4:
                inner = next(iter(memory.values()))
                if isinstance(inner, dict):
                    memory = inner
                elif isinstance(inner, str):
                    try:
                        parsed = json.loads(inner)
                        if isinstance(parsed, dict):
                            memory = parsed
                        else:
                            break
                    except json.JSONDecodeError:
                        break
                else:
                    break
                depth += 1

            _log(f"[MemExtract] OK — topic={memory.get('topic')} "
                 f"sub={memory.get('sub_topic')} kw={memory.get('keywords')}")
            return memory
        except Exception as e:
            _log(f"[MemExtract] Error: {e}")
            return {}

    async def stream_text(
        self,
        prompt: str,
        image_bytes: bytes | None,
        language_name: str,
        system_prompt_text: str,
        model: str = "gpt-4o",
    ):
        """
        Async generator that streams plain-text tokens from the LLM.
        Yields str chunks as they arrive — caller feeds them to TTS at sentence
        boundaries for low-latency speech output (~1-2 s to first word).
        """
        lang_cap = language_name.capitalize() if language_name else "English"
        lang_enforcement = (
            f"\n\n[IMPORTANT: Respond ONLY in {lang_cap}. "
            "Write plain sentences — no JSON, no bullet points, no numbered lists.]"
        )
        prompt_with_lang = prompt + lang_enforcement

        if image_bytes:
            mime_type = "image/jpeg"
            if image_bytes[:4] == b'\x89PNG':
                mime_type = "image/png"
            b64_image = base64.b64encode(image_bytes).decode("utf-8")
            user_content = [
                {"type": "text", "text": prompt_with_lang},
                {"type": "image_url", "image_url": {"url": f"data:{mime_type};base64,{b64_image}"}}
            ]
        else:
            user_content = prompt_with_lang

        payload = {
            "model": model,
            "messages": [
                {"role": "system", "content": system_prompt_text},
                {"role": "user", "content": user_content},
            ],
            "temperature": 0.3,
            "max_tokens": 1024,
            "stream": True,
        }
        headers = {"api-key": self.api_key, "Content-Type": "application/json"}

        _log(f"[StreamText] model={model} lang={lang_cap} image={'yes' if image_bytes else 'no'}")
        try:
            async with self._http.stream(
                "POST", self.endpoint, headers=headers, json=payload, timeout=30.0
            ) as resp:
                if resp.status_code != 200:
                    _log(f"[StreamText] HTTP error {resp.status_code}")
                    return
                async for line in resp.aiter_lines():
                    if not line.startswith("data: "):
                        continue
                    data_str = line[6:]
                    if data_str == "[DONE]":
                        break
                    try:
                        chunk = json.loads(data_str)
                        choices = chunk.get("choices") or []
                        if not choices:
                            continue  # usage/metadata chunk — no content
                        content = choices[0].get("delta", {}).get("content", "")
                        if content:
                            # Replace newlines so they don't break SSE framing
                            yield content.replace("\n", " ")
                    except json.JSONDecodeError:
                        pass
        except (httpx.RemoteProtocolError, httpx.ReadError):
            # Expected: server closes the TCP connection right after sending [DONE].
            # httpx raises this when it tries to drain the socket for pool reuse
            # and finds it already closed. The stream completed successfully.
            pass
        except Exception as e:
            if str(e).strip():
                _log(f"[StreamText] Error: {e}")

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
                "memory": {"entities": [], "intent": "general interaction", "topic": "general"}
            }

    async def raw_call(self, system_message: str, user_message: str) -> str:
        """Call LLM with custom system message (used by Router)."""
        system_message += "\n\nYou MUST return your output strictly in JSON format."
        messages = [
            {"role": "system", "content": system_message},
            {"role": "user", "content": user_message}
        ]
        payload = {
            "model": "gpt-4o",
            "messages": messages,
            "temperature": 0.1,
            "max_tokens": 2048,
            "response_format": {"type": "json_object"}
        }
        headers = { "api-key": self.api_key, "Content-Type": "application/json" }
        
        last_error = "Unknown"
        for attempt in range(3):
            try:
                resp = await self._http.post(self.endpoint, headers=headers, json=payload, timeout=45.0)
                if resp.status_code == 200:
                    data = resp.json()
                    return data["choices"][0]["message"]["content"]
                last_error = f"HTTP {resp.status_code}"
                _log(f"[RawCall] Attempt {attempt + 1} failed: {resp.status_code}")
                if resp.status_code in (429, 500, 503) and attempt < 2:
                    await asyncio.sleep((attempt + 1) * 2)
                    continue
                break
            except httpx.TimeoutException:
                last_error = "timeout"
                _log(f"[RawCall] Timeout on attempt {attempt + 1}")
                if attempt < 2:
                    await asyncio.sleep((attempt + 1) * 2)
            except Exception as e:
                last_error = str(e)
                _log(f"[RawCall] Error on attempt {attempt + 1}: {e}")
                break
        raise Exception(f"Raw call failed after 3 attempts: {last_error}")

    def _fallback_error(self, lang: str, error_msg: str) -> dict:
        return {
            "ai_response": system_prompt.get_unclear_message(lang),
            "memory": {"entities": [], "intent": f"error: {error_msg}", "topic": "system"}
        }

    async def _fallback_to_gemini(self, prompt: str, image_bytes, language_name: str, sys_prompt: str) -> dict:
        _log("[Gemini Fallback] Azure attempts failed. Trying Native Gemini...")
        if not getattr(settings, "GEMINI_API_KEY", None):
            return self._fallback_error(language_name, "Azure failed and no Gemini API key configured.")

        try:
            import google.generativeai as genai
            genai.configure(api_key=settings.GEMINI_API_KEY)
            model_name = getattr(settings, "GEMINI_MODEL", "gemini-2.5-flash-lite")
            model = genai.GenerativeModel(
                model_name=model_name,
                generation_config={"response_mime_type": "application/json"}
            )
            
            gemini_sys = sys_prompt + "\n\nYou MUST return your output strictly in JSON format."
            
            contents = [gemini_sys, prompt]
            if image_bytes:
                import PIL.Image
                import io
                img = PIL.Image.open(io.BytesIO(image_bytes))
                contents.append(img)
            
            resp = await model.generate_content_async(contents)
            lang_cap = language_name.capitalize() if language_name else "English"
            return self._parse_response(resp.text, lang_cap)
        except Exception as e:
            _log(f"[Gemini Fallback] Failed: {e}")
            return self._fallback_error(language_name, f"Azure and Gemini both failed. Last err: {e}")

# Global instance — used by agent.py
azure_ai_service = AzureAIService()
# Aliases so existing imports of gemini_service / llm_service keep working
llm_service = azure_ai_service
gemini_service = azure_ai_service
