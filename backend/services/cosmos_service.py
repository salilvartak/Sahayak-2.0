import uuid
from datetime import datetime, timezone
import asyncio
from azure.cosmos import CosmosClient, PartitionKey, exceptions
from config import settings

class CosmosService:
    def __init__(self):
        self.client = None
        self.database = None
        self.container = None

    async def init(self):
        """Initialize connection and required database/container."""
        if not settings.AZURE_COSMOS_ENDPOINT or not settings.AZURE_COSMOS_KEY:
            print("WARNING: Azure Cosmos DB endpoint or key not configured.")
            return

        try:
            # We use asyncio to run the blocking client in a separate thread if needed, 
            # or just call it directly. azure-cosmos doesn't have a truly async native client,
            # but we can wrap it or just call it since we're using FastAPI's background tasks.
            self.client = CosmosClient(settings.AZURE_COSMOS_ENDPOINT, settings.AZURE_COSMOS_KEY)
            
            # Create DB if it doesn't exist
            self.database = self.client.create_database_if_not_exists(id=settings.AZURE_COSMOS_DATABASE)
            
            # Create container if it doesn't exist with partition key /device_id
            self.container = self.database.create_container_if_not_exists(
                id=settings.AZURE_COSMOS_CONTAINER,
                partition_key=PartitionKey(path="/device_id"),
                default_ttl=-1, # Enable TTL on container level, -1 means on by default but documents can override
                offer_throughput=400 # Explicitly set minimum RU/s to avoid exceeding account limits
            )
            print("Cosmos DB initialized successfully.")
        except exceptions.CosmosHttpResponseError as ex:
            print(f"Failed to initialize Cosmos DB: {ex.message}")
        except Exception as e:
            print(f"An error occurred during Cosmos DB initialization: {type(e).__name__}: {e}")

    async def save_interaction(
        self,
        device_id: str,
        interaction_id: str,
        query: str,
        response: str,
        language: str,
        blob_name: str | None = None,
    ):
        """Save a single interaction to Cosmos DB."""
        if self.container is None:
            # If not initialized, try one more time
            await self.init()
            if self.container is None:
                print("Cannot save interaction: Cosmos DB container not initialized.")
                return

        interaction_doc = {
            "id": interaction_id,
            "type": "interaction",
            "device_id": device_id,
            "query": query,
            "response": response,
            "language": language,
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "blob_name": blob_name,
            "ttl": 7776000 # 90 days in seconds
        }

        try:
            print(f"DEBUG: Saving to Cosmos for {device_id}")
            print(f"  Query: {query[:100]}...")
            print(f"  Response: {response[:100]}...")
            self.container.upsert_item(interaction_doc)
            print(f"Interaction {interaction_id} saved to Cosmos DB.")
        except exceptions.CosmosHttpResponseError as ex:
            print(f"Failed to save interaction: {ex.message}")

    async def save_user_profile(self, device_id: str, profile_data: dict):
        """Save user profile (settings) to Cosmos DB."""
        if self.container is None:
            await self.init()
            if self.container is None:
                return

        profile_doc = {
            "id": f"profile_{device_id}",
            "type": "profile",
            "device_id": device_id,
            "data": profile_data,
            "timestamp": datetime.now(timezone.utc).isoformat()
        }
        # Profiles don't have TTL (keep forever)
        
        try:
            self.container.upsert_item(profile_doc)
            print(f"Profile for {device_id} updated in Cosmos DB.")
        except exceptions.CosmosHttpResponseError as ex:
            print(f"Failed to save profile: {ex.message}")

    async def get_user_profile(self, device_id: str):
        """Fetch user profile from Cosmos DB."""
        if self.container is None:
            await self.init()
            if self.container is None:
                return None

        try:
            profile_id = f"profile_{device_id}"
            item = self.container.read_item(item=profile_id, partition_key=device_id)
            return item.get("data")
        except exceptions.CosmosResourceNotFoundError:
            return None
        except exceptions.CosmosHttpResponseError as ex:
            print(f"Failed to read profile: {ex.message}")
            return None

    async def get_interactions(self, device_id: str, limit: int = 50):
        """Retrieve historical interactions for a device."""
        if self.container is None:
            await self.init()
            if self.container is None:
                return []

        try:
            query = f"SELECT * FROM c WHERE c.device_id = @device_id AND c.type = 'interaction' ORDER BY c.timestamp DESC OFFSET 0 LIMIT {limit}"
            items = list(self.container.query_items(
                query=query,
                parameters=[{"name": "@device_id", "value": device_id}],
                enable_cross_partition_query=False
            ))
            return items
        except exceptions.CosmosHttpResponseError as ex:
            print(f"Failed to query interactions: {ex.message}")
            return []

cosmos_service = CosmosService()

async def init_cosmos():
    await cosmos_service.init()
