from fastapi import HTTPException

from app import config, images
from app.providers.openai_compatible import call_openai_compatible
from app.schemas import FoodAnalysis


async def call_nvidia(
    api_key_header: str | None, image_bytes: bytes, mime_type: str
) -> FoodAnalysis:
    api_key = api_key_header or config.DEV_NVIDIA_KEY
    if not api_key:
        raise HTTPException(status_code=401, detail="NVIDIA API Key missing")
    images.require_one_of(mime_type, images.ACCEPTED_BY_OPENAI_COMPATIBLE)
    return await call_openai_compatible(
        config.NVIDIA_URL,
        api_key,
        config.NVIDIA_MODEL,
        image_bytes,
        mime_type,
        extra_payload={
            "max_tokens": 65536,
            "reasoning_budget": 16384,
            "temperature": 0.6,
            "top_p": 0.95,
            "stream": False,
        },
    )
