import uuid
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
            # We use the blocking client. For high-volume async, one might use a wrapper,
            # but for this scale, direct call in thread-safe manner is okay or just 
            # calling it as-is (FastAPI handles it).
            self.client = CosmosClient(settings.AZURE_COSMOS_ENDPOINT, settings.AZURE_COSMOS_KEY)
            
            # Create DB if it doesn't exist
            self.database = self.client.create_database_if_not_exists(id=settings.AZURE_COSMOS_DATABASE)
            
            # Create container if it doesn't exist with partition key /user_id
            self.container = self.database.create_container_if_not_exists(
                id=settings.AZURE_COSMOS_CONTAINER,
                partition_key=PartitionKey(path="/user_id"),
                default_ttl=-1, # Enable TTL
                offer_throughput=400 
            )
            print("Cosmos DB (Primary Storage) initialized successfully with /user_id partition key.")
        except exceptions.CosmosHttpResponseError as ex:
            print(f"Failed to initialize Cosmos DB: {ex.message}")
        except Exception as e:
            print(f"An error occurred during Cosmos DB initialization: {type(e).__name__}: {e}")

    async def save_interaction(self, data: dict):
        """
        Store raw conversation data in Cosmos DB.
        Expects keys: user_id, session_id, interaction_id, user_message, ai_response, language, metadata
        """
        if self.container is None:
            await self.init()
            if self.container is None:
                raise Exception("Cosmos DB not initialized")

        # Prepare document
        doc = {
            "id": data.get("interaction_id", str(uuid.uuid4())),
            "user_id": data["user_id"],
            "session_id": data["session_id"],
            "interaction_id": data.get("interaction_id", str(uuid.uuid4())),
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "user_message": data["user_message"],
            "ai_response": data["ai_response"],
            "language": data["language"],
            "blob_name": data.get("blob_name"),
            "metadata": data.get("metadata", {}),
            "ttl": 7776000 # 90 days
        }

        try:
            self.container.upsert_item(doc)
            print(f"Interaction {doc['id']} saved to Cosmos DB for User {doc['user_id']}.")
            return doc
        except exceptions.CosmosHttpResponseError as ex:
            print(f"Failed to save interaction to Cosmos: {ex.message}")
            raise

    async def get_user_sessions(self, user_id: str):
        """Retrieve list of unique session_ids for a user."""
        if self.container is None:
            await self.init()

        try:
            query = "SELECT DISTINCT c.session_id FROM c WHERE c.user_id = @user_id"
            items = list(self.container.query_items(
                query=query,
                parameters=[{"name": "@user_id", "value": user_id}],
                enable_cross_partition_query=False
            ))
            return [item["session_id"] for item in items]
        except exceptions.CosmosHttpResponseError as ex:
            print(f"Failed to query sessions: {ex.message}")
            return []

    async def get_session_history(self, session_id: str):
        """Retrieve full interaction history for a session."""
        if self.container is None:
            await self.init()

        try:
            # Note: Cross-partition query if user_id is unknown, 
            # ideally we should pass user_id too for efficiency.
            query = "SELECT * FROM c WHERE c.session_id = @session_id ORDER BY c.timestamp ASC"
            items = list(self.container.query_items(
                query=query,
                parameters=[{"name": "@session_id", "value": session_id}],
                enable_cross_partition_query=True 
            ))
            return items
        except exceptions.CosmosHttpResponseError as ex:
            print(f"Failed to query session history: {ex.message}")
            return []

cosmos_client = CosmosClientService()
