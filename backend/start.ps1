# Sahayak Backend Startup Script
# Run this instead of uvicorn directly to avoid charmap encoding errors on Windows
$env:PYTHONIOENCODING = "utf-8"
uvicorn main:app --host 0.0.0.0 --port 8000 --reload
