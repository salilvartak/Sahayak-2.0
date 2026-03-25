import asyncio
from neo4j import AsyncGraphDatabase
from config import settings

async def check():
    print(f"Checking Neo4j at: {settings.NEO4J_URI}")
    driver = AsyncGraphDatabase.driver(
        settings.NEO4J_URI, 
        auth=(settings.NEO4J_USERNAME, settings.NEO4J_PASSWORD)
    )
    
    async with driver.session() as session:
        # Check counts
        counts = await session.run("MATCH (n) RETURN labels(n) as label, count(*) as count")
        print("\n=== Node Counts ===")
        found = False
        async for record in counts:
            found = True
            print(f"{record['label']}: {record['count']}")
        
        if not found:
            print("Database is EMPTY (0 nodes).")
            
        # Check latest interaction
        print("\n=== Latest Interactions ===")
        latest = await session.run("MATCH (i:Interaction) RETURN i.text as text, i.timestamp as time ORDER BY i.timestamp DESC LIMIT 3")
        async for record in latest:
            print(f"[{record['time']}] {record['text']}")

    await driver.close()

if __name__ == "__main__":
    asyncio.run(check())
