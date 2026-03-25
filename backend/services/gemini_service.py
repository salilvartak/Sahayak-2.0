# Azure AI Model Router is now the primary LLM service.
# This module re-exports for backward compatibility with existing imports.
from services.azure_ai_service import azure_ai_service, llm_service

# Legacy aliases
gemini_service = azure_ai_service
LLMService = type(azure_ai_service)  # expose class if needed

__all__ = ["gemini_service", "llm_service", "azure_ai_service"]
