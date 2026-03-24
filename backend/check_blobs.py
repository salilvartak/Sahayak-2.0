import asyncio
from services.cosmos_client import cosmos_client

async def main():
    await cosmos_client.init()
    query = "SELECT c.id, c.blob_name FROM c"
    items = list(cosmos_client.container.query_items(query, enable_cross_partition_query=True))
    for item in items:
        print(f"ID: {item['id']} | Blob: {item.get('blob_name')}")

if __name__ == "__main__":
    asyncio.run(main())
