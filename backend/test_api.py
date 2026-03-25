"""
test_api.py — Smoke-test the running Sahayak backend API endpoints.

Usage:
    cd backend
    # Start server first: uvicorn main:app --reload
    python test_api.py [--base-url http://localhost:8000] [--device-id test-device-001]
"""
import sys
import os
import argparse
import json
import time

import requests

DEFAULT_URL = "http://localhost:8000"
DEFAULT_DEVICE = "test-device-001"


def separator(title: str):
    print(f"\n{'=' * 50}")
    print(f"  {title}")
    print('=' * 50)


def test_health(base: str):
    separator("GET /health")
    r = requests.get(f"{base}/health", timeout=10)
    print(f"Status : {r.status_code}")
    print(f"Body   : {r.text[:200]}")
    assert r.status_code == 200, "Health check failed"
    print("PASS")


def test_ask(base: str, device_id: str):
    separator("POST /ask  (text-only, no image)")
    payload = {
        "device_id": device_id,
        "session_id": f"{device_id}_test",
        "query": "What is 2 + 2? Answer in one sentence.",
        "language": "english",
        "was_interruption": "false",
        "partial_response": "",
        "previous_intent": "",
    }
    start = time.time()
    r = requests.post(f"{base}/ask", data=payload, timeout=90)
    elapsed = int((time.time() - start) * 1000)
    print(f"Status  : {r.status_code}  ({elapsed}ms)")
    if r.status_code == 200:
        data = r.json()
        print(f"Response: {data.get('response', '')[:200]}")
        print(f"IID     : {data.get('interaction_id')}")
        print("PASS")
        return data.get("interaction_id")
    else:
        print(f"FAIL  {r.text[:300]}")
        return None


def test_ask_interrupt(base: str, device_id: str, partial: str):
    separator("POST /ask  (interrupt context)")
    payload = {
        "device_id": device_id,
        "session_id": f"{device_id}_test",
        "query": "Never mind. What is the capital of France?",
        "language": "english",
        "was_interruption": "true",
        "partial_response": partial,
        "previous_intent": "arithmetic",
    }
    r = requests.post(f"{base}/ask", data=payload, timeout=90)
    print(f"Status  : {r.status_code}")
    if r.status_code == 200:
        data = r.json()
        print(f"Response: {data.get('response', '')[:200]}")
        print("PASS")
    else:
        print(f"FAIL  {r.text[:300]}")


def test_history(base: str, device_id: str):
    separator("GET /history")
    r = requests.get(f"{base}/history", params={"device_id": device_id, "limit": 5}, timeout=30)
    print(f"Status : {r.status_code}")
    if r.status_code == 200:
        data = r.json()
        items = data.get("items", [])
        print(f"Items  : {len(items)}")
        for item in items[:3]:
            print(f"  {item.get('timestamp', '?')[:19]}  {item.get('query', '')[:60]}")
        print("PASS")
    else:
        print(f"FAIL  {r.text[:200]}")


def test_profile(base: str, device_id: str):
    separator("POST /profile  +  GET /profile")
    profile = {
        "device_id": device_id,
        "text_size_multiplier": 1.2,
        "voice_speed": "Normal",
        "dark_mode": False,
        "tutorial_completed": True,
    }
    r = requests.post(f"{base}/profile", json=profile, timeout=10)
    print(f"POST status: {r.status_code}")

    r2 = requests.get(f"{base}/profile/{device_id}", timeout=10)
    print(f"GET  status: {r2.status_code}")
    if r2.status_code == 200:
        print(f"Data       : {r2.json()}")
        print("PASS")
    else:
        print(f"FAIL  {r2.text[:200]}")


def main():
    parser = argparse.ArgumentParser(description="Sahayak API smoke tests")
    parser.add_argument("--base-url", default=DEFAULT_URL)
    parser.add_argument("--device-id", default=DEFAULT_DEVICE)
    args = parser.parse_args()

    base = args.base_url.rstrip("/")
    device = args.device_id

    print(f"Target : {base}")
    print(f"Device : {device}")

    try:
        test_health(base)
        iid = test_ask(base, device)
        test_ask_interrupt(base, device, partial="Two plus two equals")
        test_history(base, device)
        test_profile(base, device)
        print("\n\nAll tests passed.")
    except requests.exceptions.ConnectionError:
        print(f"\nFAIL  Cannot connect to {base}. Is the server running?")
        sys.exit(1)
    except AssertionError as e:
        print(f"\nFAIL  {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()
