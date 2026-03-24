from pydantic import BaseModel
from typing import Optional, List

class AskResponse(BaseModel):
    response: str
    interaction_id: str  # UUID of the saved Cosmos DB record

class HistoryItem(BaseModel):
    interaction_id: str
    query: str
    response: str
    language: str
    timestamp: str           # ISO 8601
    image_url: Optional[str] = None # Azure Blob SAS URL, None if no image

class HistoryResponse(BaseModel):
    device_id: str
    items: List[HistoryItem]

class ProfileUpdate(BaseModel):
    device_id: str
    text_size_multiplier: float
    voice_speed: str
    dark_mode: bool
    tutorial_completed: bool

class ProfileResponse(BaseModel):
    device_id: str
    text_size_multiplier: float
    voice_speed: str
    dark_mode: bool
    tutorial_completed: bool
