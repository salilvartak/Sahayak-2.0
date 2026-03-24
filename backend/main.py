from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from routers import ask, history, profile
from services.blob_service import init_blob
from services.cosmos_client import cosmos_client
from services.graph_client import graph_client

app = FastAPI(title="Sahayak Backend")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

@app.on_event("startup")
async def startup_event():
    # Initialize Azure and Neo4j connection services
    await init_blob()
    await cosmos_client.init()
    await graph_client.init()

app.include_router(ask.router, tags=["ask"])
app.include_router(history.router, tags=["history"])
app.include_router(profile.router, tags=["profile"])

@app.get("/health")
async def health_check():
    return {"status": "ok"}
