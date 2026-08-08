import google.generativeai as genai
from fastapi import HTTPException

from app import config
from app.parsing import parse_model_json, normalize


async def call_gemini(api_key_header: str | None, image_bytes: bytes) -> dict:
    api_key = api_key_header or config.DEV_GEMINI_KEY
    if not api_key:
        raise HTTPException(status_code=401, detail="Gemini API Key missing")

    genai.configure(api_key=api_key)
    model = genai.GenerativeModel(config.GEMINI_MODEL)
    try:
        response = model.generate_content(
            [config.PROMPT, {"mime_type": "image/jpeg", "data": image_bytes}]
        )
        raw_text = response.text
    except Exception:
        raise HTTPException(status_code=502, detail="provider request failed")
    return normalize(parse_model_json(raw_text))
