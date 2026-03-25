"""
Quick manual test script for the Sahayak backend.
Run from backend/ directory: python test_api.py

Tests:
  1. GET  /health         - basic health check
  2. POST /ask            - text-only query
  3. POST /ask            - query with an image (uses test_image.jpg if present)
"""

import asyncio
import httpx
import os

BASE_URL = "http://localhost:8000"
DEVICE_ID = "test-device-001"
SESSION_ID = "test-session-001"

async def test_health():
    print("\n=== 1. Health Check ===")
    async with httpx.AsyncClient() as client:
        r = await client.get(f"{BASE_URL}/health")
        print(f"Status : {r.status_code}")
        print(f"Body   : {r.json()}")

async def test_ask_text(query: str, language: str = "English"):
    print(f"\n=== 2. Text Query [{language}] ===")
    print(f"Query: {query}")
    data = {
        "device_id": DEVICE_ID,
        "session_id": SESSION_ID,
        "query": query,
        "language": language,
    }
    async with httpx.AsyncClient(timeout=30.0) as client:
        r = await client.post(f"{BASE_URL}/ask", data=data)
        print(f"Status : {r.status_code}")
        if r.status_code == 200:
            body = r.json()
            print(f"Response : {body['response']}")
            print(f"Interaction ID: {body['interaction_id']}")
        else:
            print(f"Error: {r.text}")

async def test_ask_image(query: str, image_path: str, language: str = "English"):
    print(f"\n=== 3. Image + Text Query [{language}] ===")
    print(f"Query: {query}")
    print(f"Image: {image_path}")

    if not os.path.exists(image_path):
        print(f"  ⚠️  Image file not found: {image_path}. Skipping image test.")
        return

    data = {
        "device_id": DEVICE_ID,
        "session_id": SESSION_ID,
        "query": query,
        "language": language,
    }
    with open(image_path, "rb") as f:
        files = {"image": ("test_image.jpg", f, "image/jpeg")}
        async with httpx.AsyncClient(timeout=30.0) as client:
            r = await client.post(f"{BASE_URL}/ask", data=data, files=files)
    print(f"Status : {r.status_code}")
    if r.status_code == 200:
        body = r.json()
        print(f"Response : {body['response']}")
    else:
        print(f"Error: {r.text}")

async def main():
    # --- Run tests ---
    await test_health()
    await test_ask_text("What is Paracetamol used for?", language="English")
    await test_ask_text("पैरासिटामोल क्या है?", language="Hindi")

    # Image test — place a test_image.jpg in the backend folder, or change path
    image_path = os.path.join(os.path.dirname(__file__), "test_image.jpg")
    await test_ask_image("What is this medicine?", image_path, language="English")

if __name__ == "__main__":
    asyncio.run(main())
