from fastapi import APIRouter, HTTPException, BackgroundTasks
from services.cosmos_service import cosmos_service
from models.schemas import ProfileUpdate, ProfileResponse

router = APIRouter()

@router.post("/profile", response_model=ProfileResponse)
async def update_profile(
    background_tasks: BackgroundTasks,
    profile: ProfileUpdate
):
    try:
        profile_data = {
            "text_size_multiplier": profile.text_size_multiplier,
            "voice_speed": profile.voice_speed,
            "dark_mode": profile.dark_mode,
            "tutorial_completed": profile.tutorial_completed
        }
        
        # Save to DB in background
        background_tasks.add_task(
            cosmos_service.save_user_profile,
            profile.device_id,
            profile_data
        )
        
        return ProfileResponse(
            device_id=profile.device_id,
            **profile_data
        )
    except Exception as e:
        print(f"Error updating profile: {e}")
        raise HTTPException(status_code=500, detail=str(e))

@router.get("/profile/{device_id}", response_model=ProfileResponse)
async def get_profile(device_id: str):
    try:
        data = await cosmos_service.get_user_profile(device_id)
        if not data:
            # Return defaults if not found
            return ProfileResponse(
                device_id=device_id,
                text_size_multiplier=1.0,
                voice_speed="Normal",
                dark_mode=False,
                tutorial_completed=False
            )
        
        return ProfileResponse(
            device_id=device_id,
            **data
        )
    except Exception as e:
        print(f"Error fetching profile: {e}")
        raise HTTPException(status_code=500, detail=str(e))
