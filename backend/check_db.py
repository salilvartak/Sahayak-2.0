import asyncio
from services.cosmos_client import cosmos_client
from services.graph_client import graph_client
from config import settings

async def check():
    print("--- Checking Cosmos DB ---")
    await cosmos_client.init()
    if cosmos_client.container:
        try:
            # Query all items to see if any exist
            query = "SELECT * FROM c ORDER BY c.timestamp DESC"
            items = list(cosmos_client.container.query_items(
                query=query,
                enable_cross_partition_query=True
            ))
            print(f"Total interactions in Cosmos: {len(items)}")
            if items:
                last = items[0]
                print(f"Last Interaction ID: {last.get('id')}")
                print(f"User: {last.get('user_id')}")
                print(f"Message: {last.get('user_message')}")
                print(f"AI Response: {last.get('ai_response')}")
        except Exception as e:
            print(f"Error querying Cosmos: {e}")
    else:
        print("Cosmos container not initialized.")

    print("\n--- Checking Neo4j Graph ---")
    await graph_client.init()
    if graph_client.driver:
        async with graph_client.driver.session() as session:
            # Check basic node count
            res = await session.run("MATCH (n) RETURN count(n) as count")
            count = await res.single()
            print(f"Total nodes in Graph: {count['count']}")

            # Check nodes count by label
            res = await session.run("MATCH (n) RETURN labels(n) as label, count(*) as count")
            records = await res.data()
            print("Graph Node Counts:")
            for r in records:
                print(f"  {r['label']}: {r['count']}")
            
            # Check relationships
            res = await session.run("MATCH ()-[r]->() RETURN type(r) as type, count(*) as count")
            records = await res.data()
            print("Graph Relationship Counts:")
            for r in records:
                print(f"  {r['type']}: {r['count']}")
    else:
        print("Neo4j driver not initialized.")

if __name__ == "__main__":
    asyncio.run(check())
