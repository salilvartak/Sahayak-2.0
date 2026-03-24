import base64
import httpx
import json
import re
from config import settings
from prompts import system_prompt

class LLMService:
    """A service that uses exclusively the Azure Model Router orchestrator."""
    def __init__(self):
        # Azure Router Config
        self.azure_endpoint = settings.AZURE_AI_MODEL_ROUTER_ENDPOINT
        self.azure_key = settings.AZURE_AI_MODEL_ROUTER_KEY
        
        if not self.azure_endpoint or not self.azure_key:
            print("WARNING: Azure AI Model Router credentials missing!")

    async def get_response(
        self,
        prompt: str,
        image_bytes: bytes | None,
        language_name: str
    ) -> dict:
        """Calls the Azure Model Router and returns structured JSON output."""
        lang_cap = language_name.capitalize() if language_name else "English"
        sys_prompt = system_prompt.get_structured_system_prompt(lang_cap)
        
        headers = {
            "Content-Type": "application/json",
            "api-key": self.azure_key
        }
        
        content = [{"type": "text", "text": prompt}]
        if image_bytes:
            base64_image = base64.b64encode(image_bytes).decode('utf-8')
            content.append({
                "type": "image_url",
                "image_url": {
                    "url": f"data:image/jpeg;base64,{base64_image}"
                }
            })
            
        payload = {
            "messages": [
                {"role": "system", "content": sys_prompt},
                {"role": "user", "content": content}
            ],
            "temperature": 0.3, # Lower temperature for better JSON consistency
            "max_tokens": 1500,
            "response_format": {"type": "json_object"}
        }
        
        async with httpx.AsyncClient() as client:
            try:
                response = await client.post(
                    self.azure_endpoint,
                    json=payload,
                    headers=headers,
                    timeout=55.0 # Increased timeout for router
                )
                
                if response.status_code == 200:
                    data = response.json()
                    raw_content = data['choices'][0]['message']['content'].strip()
                    
                    # Robust JSON extraction: handle markdown backticks if present
                    json_str = raw_content
                    if "```json" in raw_content:
                        json_str = re.search(r"```json\s*(.*?)\s*```", raw_content, re.DOTALL).group(1)
                    elif "```" in raw_content:
                        json_str = re.search(r"```\s*(.*?)\s*```", raw_content, re.DOTALL).group(1)
                    
                    try:
                        return json.loads(json_str)
                    except json.JSONDecodeError as je:
                        print(f"JSON Decode Error: {je}. Raw output: {raw_content}")
                        return self._fallback_error(language_name, "JSON malformed")
                else:
                    print(f"Azure Router Error: {response.status_code} - {response.text}")
                    return self._fallback_error(language_name, f"Status: {response.status_code}")
            except Exception as e:
                print(f"Azure Router Exception: {e}")
                import traceback
                traceback.print_exc()
                return self._fallback_error(language_name, str(e))

    def _fallback_error(self, lang: str, error_msg: str) -> dict:
        return {
            "ai_response": system_prompt.get_unclear_message(lang),
            "memory": {"entities": [], "intent": f"error: {error_msg}", "topic": "system"}
        }

# Instance named gemini_service to stay compatible with existing imports
gemini_service = LLMService()
llm_service = gemini_service
