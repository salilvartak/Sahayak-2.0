from pydantic_settings import BaseSettings
from typing import Optional

class Settings(BaseSettings):
    # Gemini (Optional fallback)
    GEMINI_API_KEY: Optional[str] = None
    GEMINI_MODEL: str = "gemini-1.5-flash"

    # Azure AI Model Router (Primary)
    AZURE_AI_MODEL_ROUTER_ENDPOINT: Optional[str] = None
    AZURE_AI_MODEL_ROUTER_KEY: Optional[str] = None

    # Azure Storage
    AZURE_STORAGE_CONNECTION_STRING: Optional[str] = None
    AZURE_STORAGE_CONTAINER: str = "sahayak"

    # Azure Cosmos DB
    AZURE_COSMOS_ENDPOINT: Optional[str] = None
    AZURE_COSMOS_KEY: Optional[str] = None
    AZURE_COSMOS_DATABASE: str = "sahayak-cosmos-db"
    AZURE_COSMOS_CONTAINER: str = "conversations"

    # Neo4j
    NEO4J_URI: Optional[str] = None
    NEO4J_USERNAME: str = "neo4j"
    NEO4J_PASSWORD: Optional[str] = None

    class Config:
        env_file = ".env"
        extra = "allow"  # Allow extra environment variables

settings = Settings()
