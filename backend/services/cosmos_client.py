import uuid
import asyncio
from datetime import datetime, timezone
from azure.cosmos import CosmosClient, PartitionKey, exceptions
from config import settings


class CosmosClientService:
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
            self.client = CosmosClient(settings.AZURE_COSMOS_ENDPOINT, settings.AZURE_COSMOS_KEY)
            self.database = self.client.create_database_if_not_exists(id=settings.AZURE_COSMOS_DATABASE)
            self.container = self.database.create_container_if_not_exists(
                id=settings.AZURE_COSMOS_CONTAINER,
                partition_key=PartitionKey(path="/user_id"),
                default_ttl=-1,
                offer_throughput=400,
            )
            print("Cosmos DB (Primary Storage) initialized successfully with /user_id partition key.")
        except exceptions.CosmosHttpResponseError as ex:
            print(f"Failed to initialize Cosmos DB: {ex.message}")

    async def save_interaction(self, data: dict):
        """Store raw conversation data in Cosmos DB."""
        if self.container is None:
            await self.init()

        user_id = data.get("user_id") or data.get("device_id")
        doc = {
            "id": data.get("interaction_id", str(uuid.uuid4())),
            "type": "interaction",
            "user_id": user_id,
            "device_id": user_id,
            "session_id": data.get("session_id"),
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "user_message": data.get("user_message") or data.get("query"),
            "query": data.get("user_message") or data.get("query"),
            "ai_response": data.get("ai_response") or data.get("response"),
            "response": data.get("ai_response") or data.get("response"),
            "language": data.get("language"),
            "blob_name": data.get("blob_name"),
            "ttl": 7776000,  # 90 days
        }
        try:
            # upsert_item is synchronous — run in thread to avoid blocking the event loop
            await asyncio.to_thread(self.container.upsert_item, doc)
            print(f"Interaction {doc['id']} saved to Cosmos DB for Device {user_id}.")
            return doc
        except exceptions.CosmosHttpResponseError as ex:
            print(f"Failed to save interaction to Cosmos: {ex.message}")
            raise

    async def get_history_for_device(self, device_id: str, limit: int = 50):
        """Retrieve interaction history for a device."""
        if self.container is None:
            await self.init()
        try:
            query = (
                "SELECT * FROM c "
                "WHERE c.device_id = @id AND c.type = 'interaction' "
                "ORDER BY c.timestamp DESC"
            )
            items = await asyncio.to_thread(
                lambda: list(self.container.query_items(
                    query=query,
                    parameters=[{"name": "@id", "value": device_id}],
                    partition_key=device_id,
                ))[:limit]
            )
            return items
        except exceptions.CosmosHttpResponseError as ex:
            print(f"Failed to query history: {ex.message}")
            return []

    async def get_last_interaction_id(self, device_id: str, session_id: str):
        """Retrieve the last interaction ID for a given session."""
        if self.container is None:
            await self.init()
        try:
            query = (
                "SELECT TOP 1 c.id FROM c "
                "WHERE c.session_id = @sid AND c.type = 'interaction' "
                "ORDER BY c.timestamp DESC"
            )
            items = await asyncio.to_thread(
                lambda: list(self.container.query_items(
                    query=query,
                    parameters=[{"name": "@sid", "value": session_id}],
                    partition_key=device_id,
                ))
            )
            if items:
                return items[0].get("id")
        except exceptions.CosmosHttpResponseError as ex:
            print(f"Failed to get last interaction id: {ex.message}")
        return None


cosmos_client = CosmosClientService()
