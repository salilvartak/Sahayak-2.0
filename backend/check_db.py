"""
check_db.py — Verify Cosmos DB connectivity and print container stats.

Usage:
    cd backend
    python check_db.py
"""
import asyncio
import sys
import os

sys.path.insert(0, os.path.dirname(__file__))
from config import settings
from azure.cosmos import CosmosClient, exceptions


def check_db():
    print("=== Cosmos DB Health Check ===\n")

    if not settings.AZURE_COSMOS_ENDPOINT:
        print("FAIL  AZURE_COSMOS_ENDPOINT not set in .env")
        return
    if not settings.AZURE_COSMOS_KEY:
        print("FAIL  AZURE_COSMOS_KEY not set in .env")
        return

    print(f"Endpoint : {settings.AZURE_COSMOS_ENDPOINT}")
    print(f"Database : {settings.AZURE_COSMOS_DATABASE}")
    print(f"Container: {settings.AZURE_COSMOS_CONTAINER}\n")

    try:
        client = CosmosClient(settings.AZURE_COSMOS_ENDPOINT, settings.AZURE_COSMOS_KEY)
        db = client.get_database_client(settings.AZURE_COSMOS_DATABASE)
        container = db.get_container_client(settings.AZURE_COSMOS_CONTAINER)

        # Count total items
        count_q = "SELECT VALUE COUNT(1) FROM c"
        count = list(container.query_items(count_q, enable_cross_partition_query=True))[0]
        print(f"OK  Connected. Total interactions: {count}")

        # Show 3 most recent
        recent = list(container.query_items(
            "SELECT c.id, c.user_id, c.timestamp, c.language FROM c ORDER BY c.timestamp DESC",
            enable_cross_partition_query=True
        ))[:3]

        if recent:
            print("\nMost recent 3 interactions:")
            for item in recent:
                print(f"  {item.get('timestamp', '?')[:19]}  user={item.get('user_id', '?')[:20]}  lang={item.get('language', '?')}")

    except exceptions.CosmosHttpResponseError as e:
        print(f"FAIL  Cosmos error: {e.status_code} — {e.message}")
    except Exception as e:
        print(f"FAIL  Unexpected error: {e}")


if __name__ == "__main__":
    check_db()
