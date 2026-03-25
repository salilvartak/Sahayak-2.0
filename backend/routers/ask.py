import uuid
from fastapi import APIRouter, UploadFile, File, Form, BackgroundTasks, HTTPException
from services.agent import agent_graph
from services.blob_service import blob_service
from services.cosmos_client import cosmos_client
from models.schemas import AskResponse

router = APIRouter()

@router.post("/ask", response_model=AskResponse)
async def ask(
    background_tasks: BackgroundTasks,
    device_id: str = Form(...),          # Map device_id from flutter to user_id
    session_id: str = Form("default"),   # Session ID
    query: str = Form(...),
    language: str = Form(...),
    image: UploadFile = File(None)
):
    interaction_id = str(uuid.uuid4())
    image_bytes = None
    blob_name = None
    
    if image:
        try:
            image_bytes = await image.read()
            # Explicitly define blob name to store in Cosmos too
            blob_name = f"{device_id}/{interaction_id}/frame.jpg"
            
            # Upload to blob in background
            background_tasks.add_task(
                blob_service.upload_image,
                device_id,
                interaction_id,
                image_bytes
            )
        except Exception as e:
            print(f"Error reading image: {e}")
            raise HTTPException(status_code=400, detail="Could not read image file")
            
    try:
        # 0. Get the previous interaction ID for this session to maintain history chain
        prev_interaction_id = await cosmos_client.get_last_interaction_id(session_id)
        
        # Prepare state for LangGraph pipeline
        state = {
            "user_id": device_id,
            "session_id": session_id,
            "interaction_id": interaction_id,
            "query": query,
            "language": language,
            "image_bytes": image_bytes,
            "blob_name": blob_name,
            "metadata": {"user_id": device_id},
            "prev_interaction_id": prev_interaction_id
        }
        print(f"[ask] query='{query}' | language='{language}' | image={'yes' if image_bytes else 'no'} ({len(image_bytes) if image_bytes else 0} bytes)", flush=True)

        # 1. OPTIMIZATION: Get LLM response directly to avoid pipeline overhead
        # Import inside for now or at top
        from services.agent import call_llm_node, history_write_node
        
        result = await call_llm_node(state)
        
        # 2. Update state with AI response and memory for background processing
        state.update(result)
        background_tasks.add_task(history_write_node, state)
        
        return AskResponse(response=result["response_text"], interaction_id=interaction_id)
        
    except Exception as e:
        print(f"Error in /ask end-point: {e}")
        raise HTTPException(status_code=500, detail=str(e))
