from azure.storage.blob import BlobServiceClient, generate_blob_sas, BlobSasPermissions
from datetime import datetime, timedelta, timezone
from config import settings

class BlobService:
    def __init__(self):
        self.client = None
        self.container_client = None

    async def init(self):
        """Initialize connection and container."""
        if not settings.AZURE_STORAGE_CONNECTION_STRING:
            print("WARNING: Azure Storage Connection String not configured.")
            return

        try:
            self.client = BlobServiceClient.from_connection_string(settings.AZURE_STORAGE_CONNECTION_STRING)
            self.container_client = self.client.get_container_client(settings.AZURE_STORAGE_CONTAINER)
            
            # Create container if it doesn't exist (it defaults to private access)
            if not self.container_client.exists():
                self.container_client.create_container()
            print("Azure Blob Storage initialized successfully.")
        except Exception as e:
            print(f"Failed to initialize Blob Storage: {e}")

    async def upload_image(
        self,
        device_id: str,
        interaction_id: str,
        image_bytes: bytes
    ) -> str:
        """Upload image to storage and return blob name."""
        if self.container_client is None:
            await self.init()
            if self.container_client is None:
                raise Exception("Blob Storage not initialized")

        blob_name = f"{device_id}/{interaction_id}/frame.jpg"
        blob_client = self.container_client.get_blob_client(blob_name)
        
        try:
            blob_client.upload_blob(image_bytes, overwrite=True)
            return blob_name
        except Exception as e:
            print(f"Failed to upload image: {e}")
            raise

    async def get_image_sas_url(self, blob_name: str, expiry_hours: int = 24) -> str:
        """Generate a read-only SAS URL for the blob."""
        if self.client is None:
            await self.init()
            if self.client is None:
                return ""

        try:
            # Generate SAS token
            sas_token = generate_blob_sas(
                account_name=self.client.account_name,
                container_name=settings.AZURE_STORAGE_CONTAINER,
                blob_name=blob_name,
                account_key=self.client.credential.account_key,
                permission=BlobSasPermissions(read=True),
                expiry=datetime.now(timezone.utc) + timedelta(hours=expiry_hours)
            )
            blob_url = f"https://{self.client.account_name}.blob.core.windows.net/{settings.AZURE_STORAGE_CONTAINER}/{blob_name}?{sas_token}"
            return blob_url
        except Exception as e:
            print(f"Failed to generate SAS URL for {blob_name}: {e}")
            return ""

blob_service = BlobService()

async def init_blob():
    await blob_service.init()
