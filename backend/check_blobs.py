"""
check_blobs.py — Verify Azure Blob Storage connectivity and list recent blobs.

Usage:
    cd backend
    python check_blobs.py [--limit 20] [--device-id <id>]
"""
import sys
import os
import argparse

sys.path.insert(0, os.path.dirname(__file__))
from config import settings
from azure.storage.blob import BlobServiceClient


def check_blobs(limit: int, device_id: str | None):
    print("=== Azure Blob Storage Health Check ===\n")

    if not settings.AZURE_STORAGE_CONNECTION_STRING:
        print("FAIL  AZURE_STORAGE_CONNECTION_STRING not set in .env")
        return

    container_name = settings.AZURE_STORAGE_CONTAINER
    print(f"Container: {container_name}\n")

    try:
        client = BlobServiceClient.from_connection_string(
            settings.AZURE_STORAGE_CONNECTION_STRING
        )
        container_client = client.get_container_client(container_name)

        prefix = f"{device_id}/" if device_id else None
        blobs = list(container_client.list_blobs(name_starts_with=prefix))
        blobs.sort(key=lambda b: b.last_modified, reverse=True)

        print(f"OK  Connected. Total blobs{' for device ' + device_id if device_id else ''}: {len(blobs)}")

        for blob in blobs[:limit]:
            size_kb = (blob.size or 0) / 1024
            ts = blob.last_modified.strftime("%Y-%m-%d %H:%M:%S") if blob.last_modified else "?"
            print(f"  {ts}  {size_kb:6.1f} KB  {blob.name}")

        if len(blobs) > limit:
            print(f"  ... and {len(blobs) - limit} more")

    except Exception as e:
        print(f"FAIL  {e}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Check Azure Blob Storage")
    parser.add_argument("--limit", type=int, default=20)
    parser.add_argument("--device-id", type=str, default=None)
    args = parser.parse_args()

    check_blobs(args.limit, args.device_id)
