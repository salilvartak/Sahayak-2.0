"""
debug_cosmos.py — Dump recent Cosmos DB interactions to stdout and file.

Usage:
    cd backend
    python debug_cosmos.py [--limit 20] [--device-id <id>] [--out cosmos_output.json]
"""
import asyncio
import json
import argparse
import sys
import os

sys.path.insert(0, os.path.dirname(__file__))
from config import settings
from azure.cosmos import CosmosClient


async def dump_cosmos(limit: int, device_id: str | None, out_file: str):
    if not settings.AZURE_COSMOS_ENDPOINT or not settings.AZURE_COSMOS_KEY:
        print("ERROR: AZURE_COSMOS_ENDPOINT and AZURE_COSMOS_KEY must be set in .env")
        return

    client = CosmosClient(settings.AZURE_COSMOS_ENDPOINT, settings.AZURE_COSMOS_KEY)
    db = client.get_database_client(settings.AZURE_COSMOS_DATABASE)
    container = db.get_container_client(settings.AZURE_COSMOS_CONTAINER)

    if device_id:
        query = "SELECT * FROM c WHERE c.user_id = @id OR c.device_id = @id ORDER BY c.timestamp DESC"
        params = [{"name": "@id", "value": device_id}]
    else:
        query = "SELECT * FROM c ORDER BY c.timestamp DESC"
        params = []

    print(f"Querying Cosmos DB: {settings.AZURE_COSMOS_DATABASE}/{settings.AZURE_COSMOS_CONTAINER}")
    print(f"Filter: device_id={device_id or 'ALL'}  limit={limit}\n")

    items = list(container.query_items(
        query=query,
        parameters=params,
        enable_cross_partition_query=True,
    ))[:limit]

    print(f"Found {len(items)} item(s)\n")
    for i, item in enumerate(items, 1):
        print(f"--- [{i}] {item.get('timestamp', 'no-ts')} ---")
        print(f"  id          : {item.get('id')}")
        print(f"  user_id     : {item.get('user_id') or item.get('device_id')}")
        print(f"  session_id  : {item.get('session_id')}")
        print(f"  language    : {item.get('language')}")
        print(f"  query       : {(item.get('user_message') or item.get('query', ''))[:120]}")
        print(f"  response    : {(item.get('ai_response') or item.get('response', ''))[:120]}")
        print(f"  blob_name   : {item.get('blob_name')}")
        print()

    # Write full JSON to file
    with open(out_file, "w", encoding="utf-8") as f:
        json.dump(items, f, indent=2, default=str)
    print(f"Full JSON written to {out_file}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Dump Cosmos DB interactions")
    parser.add_argument("--limit", type=int, default=20)
    parser.add_argument("--device-id", type=str, default=None)
    parser.add_argument("--out", type=str, default="cosmos_output.json")
    args = parser.parse_args()

    asyncio.run(dump_cosmos(args.limit, args.device_id, args.out))
