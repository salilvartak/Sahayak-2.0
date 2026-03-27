import uuid
import asyncio
from fastapi import APIRouter, UploadFile, File, Form, BackgroundTasks, HTTPException
from fastapi.responses import StreamingResponse
from services.blob_service import blob_service
from services.cosmos_client import cosmos_client
from services.azure_ai_service import azure_ai_service
from services.open_food_facts_service import open_food_facts_service
from models.schemas import AskResponse

router = APIRouter()

@router.post("/ask", response_model=AskResponse)
async def ask(
    background_tasks: BackgroundTasks,
    device_id: str = Form(...),
    session_id: str = Form("default"),
    query: str = Form(...),
    language: str = Form(...),
    image: UploadFile = File(None),
    was_interruption: bool = Form(False),
    partial_response: str = Form(""),
    previous_intent: str = Form(""),
    barcode: str = Form(""),
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
        prev_interaction_id = await cosmos_client.get_last_interaction_id(device_id, session_id)
        
        product_data = await open_food_facts_service.fetch_product(barcode)
        product_context = open_food_facts_service.build_prompt_context(barcode, product_data) if barcode else ""

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
            "prev_interaction_id": prev_interaction_id,
            "was_interruption": was_interruption,
            "partial_response": partial_response,
            "previous_intent": previous_intent,
            "barcode": barcode or None,
            "product_context": product_context or None,
            "user_query": query,
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


@router.post("/ask/stream")
async def ask_stream(
    background_tasks: BackgroundTasks,
    device_id: str = Form(...),
    session_id: str = Form("default"),
    query: str = Form(...),
    language: str = Form(...),
    image: UploadFile = File(None),
    was_interruption: bool = Form(False),
    partial_response: str = Form(""),
    previous_intent: str = Form(""),
    barcode: str = Form(""),
):
    """SSE streaming endpoint — yields plain-text tokens as they arrive from the
    LLM so the Flutter client can pipe each sentence to TTS immediately, giving
    the user speech ~1–2 s after they stop talking instead of waiting for the
    full response."""
    interaction_id = str(uuid.uuid4())
    image_bytes = None
    blob_name = None

    if image:
        try:
            image_bytes = await image.read()
            blob_name = f"{device_id}/{interaction_id}/frame.jpg"
            background_tasks.add_task(
                blob_service.upload_image, device_id, interaction_id, image_bytes
            )
        except Exception as e:
            print(f"[ask/stream] Error reading image: {e}")
            raise HTTPException(status_code=400, detail="Could not read image file")

    prev_interaction_id = await cosmos_client.get_last_interaction_id(device_id, session_id)

    product_data = await open_food_facts_service.fetch_product(barcode)
    product_context = open_food_facts_service.build_prompt_context(barcode, product_data) if barcode else ""
    if barcode:
        print(f"[ask/stream] barcode={barcode} | product={'found' if product_data else 'not in OFF'} | ctx={len(product_context)}chars", flush=True)

    state = {
        "user_id": device_id,
        "session_id": session_id,
        "interaction_id": interaction_id,
        "query": query,
        "language": language,
        "image_bytes": image_bytes,
        "blob_name": blob_name,
        "metadata": {"user_id": device_id},
        "prev_interaction_id": prev_interaction_id,
        "was_interruption": was_interruption,
        "partial_response": partial_response,
        "previous_intent": previous_intent,
        "response_text": "",
        "extracted_memory": {},
        "barcode": barcode or None,
        "product_context": product_context or None,
        "user_query": query,
    }
    print(f"[ask/stream] query='{query}' | language='{language}' | image={'yes' if image_bytes else 'no'}", flush=True)

    from services.agent import build_streaming_context, history_write_node

    model, system_prompt_text = await build_streaming_context(state)

    full_response: list[str] = []

    async def generate():
        async for token in azure_ai_service.stream_text(
            prompt=query,
            image_bytes=image_bytes,
            language_name=language,
            system_prompt_text=system_prompt_text,
            model=model,
        ):
            full_response.append(token)
            yield f"data: {token}\n\n"

        # Stream complete — persist to Cosmos + Neo4j in background
        if not state.get("extracted_memory"):
            state["extracted_memory"] = {
                "entities": [],
                "intent": "general interaction",
                "topic": "general",
            }
        state["response_text"] = "".join(full_response)
        asyncio.create_task(history_write_node(state))
        yield "data: [DONE]\n\n"

    return StreamingResponse(generate(), media_type="text/event-stream")
