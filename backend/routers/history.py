from fastapi import APIRouter, HTTPException, Query
from services.cosmos_client import cosmos_client
from services.blob_service import blob_service
from models.schemas import HistoryResponse, HistoryItem

router = APIRouter()

@router.get("/history", response_model=HistoryResponse)
async def get_history(
    user_id: str = Query(None),
    device_id: str = Query(None),
    limit: int = Query(50)
):
    # Support both current implementation and flutter client
    final_user_id = user_id or device_id
    if not final_user_id:
        raise HTTPException(status_code=400, detail="User ID or Device ID required")
        
    try:
        # Use user_id for the query because it's the partition key in Azure
        query = "SELECT * FROM c WHERE (c.user_id = @id OR c.device_id = @id) ORDER BY c.timestamp DESC"
        
        interactions = list(cosmos_client.container.query_items(
            query=query,
            parameters=[{"name": "@id", "value": final_user_id}],
            enable_cross_partition_query=True 
        ))[:limit]
        
        print(f"DEBUG: Found {len(interactions)} items in Cosmos for ID {final_user_id}")
        
        history_items = []
        for item in interactions:
            image_url = None
            if item.get("blob_name"):
                image_url = await blob_service.get_image_sas_url(item["blob_name"])
            
            # Map robustly to catch both OLD and NEW data formats
            history_items.append(HistoryItem(
                interaction_id=item.get("id", ""),
                query=item.get("user_message") or item.get("query", ""),
                response=item.get("ai_response") or item.get("response", "No response"),
                language=item.get("language", "en"),
                timestamp=item.get("timestamp", ""),
                image_url=image_url
            ))
            
        return HistoryResponse(device_id=final_user_id, items=history_items)
        
    except Exception as e:
        import traceback
        print(f"CRITICAL: Error fetching history for {final_user_id}: {e}")
        traceback.print_exc()
        raise HTTPException(status_code=500, detail=f"History fetch failed: {str(e)}")
