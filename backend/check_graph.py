"""
check_graph.py — Verify Neo4j connectivity and print graph statistics.

Usage:
    cd backend
    python check_graph.py [--user-id <id>]
"""
import asyncio
import sys
import os
import argparse

sys.path.insert(0, os.path.dirname(__file__))
from config import settings


async def check_graph(user_id: str | None):
    print("=== Neo4j Graph Health Check ===\n")

    if not settings.NEO4J_URI:
        print("FAIL  NEO4J_URI not set in .env")
        return

    print(f"URI      : {settings.NEO4J_URI}")
    print(f"Username : {settings.NEO4J_USERNAME}\n")

    try:
        from neo4j import AsyncGraphDatabase

        driver = AsyncGraphDatabase.driver(
            settings.NEO4J_URI,
            auth=(settings.NEO4J_USERNAME, settings.NEO4J_PASSWORD or ""),
        )

        async with driver.session() as session:
            # Node counts
            for label in ["User", "Session", "Interaction", "Intent", "Topic", "Entity"]:
                result = await session.run(f"MATCH (n:{label}) RETURN count(n) AS cnt")
                record = await result.single()
                print(f"  {label:<15}: {record['cnt']} nodes")

            # Relationship counts
            result = await session.run("MATCH ()-[r]->() RETURN type(r) AS t, count(r) AS cnt ORDER BY cnt DESC")
            records = await result.fetch(10)
            if records:
                print("\nRelationships:")
                for r in records:
                    print(f"  {r['t']:<25}: {r['cnt']}")

            # User-specific stats
            if user_id:
                print(f"\nUser '{user_id}':")
                result = await session.run(
                    "MATCH (u:User {id: $uid})-[:HAS_SESSION]->(s:Session)-[:HAS_INTERACTION]->(i:Interaction) "
                    "RETURN count(i) AS interactions, count(DISTINCT s) AS sessions",
                    uid=user_id
                )
                rec = await result.single()
                if rec:
                    print(f"  Sessions     : {rec['sessions']}")
                    print(f"  Interactions : {rec['interactions']}")

                result = await session.run(
                    "MATCH (u:User {id: $uid})-[:INTERESTED_IN]->(t:Topic) RETURN t.name AS topic",
                    uid=user_id
                )
                topics = [r["topic"] async for r in result]
                if topics:
                    print(f"  Topics       : {', '.join(topics)}")

        await driver.close()
        print("\nOK  Neo4j connection successful")

    except Exception as e:
        print(f"FAIL  {e}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Check Neo4j graph")
    parser.add_argument("--user-id", type=str, default=None)
    args = parser.parse_args()

    asyncio.run(check_graph(args.user_id))
