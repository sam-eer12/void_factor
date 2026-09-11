from google import genai
from google.genai import types
from fastapi import HTTPException

from app import config
from app.parsing import parse_model_json, normalize


async def call_gemini(api_key_header: str | None, image_bytes: bytes) -> dict:
    api_key = api_key_header or config.DEV_GEMINI_KEY
    if not api_key:
        raise HTTPException(status_code=401, detail="Gemini API Key missing")

    # A client per call rather than a module-level one: the key comes from the
    # caller, so there is no single client to reuse across users.
    client = genai.Client(api_key=api_key)
    try:
        response = client.models.generate_content(
            model=config.GEMINI_MODEL,
            contents=[
                config.PROMPT,
                types.Part.from_bytes(data=image_bytes, mime_type="image/jpeg"),
            ],
        )
        raw_text = response.text
    except Exception:
        # Still one message for every failure, so a bad key remains
        # indistinguishable from an outage. Narrowing this needs the SDK to
        # expose an auth-specific error; noted as a known gap.
        raise HTTPException(status_code=502, detail="provider request failed")
    return normalize(parse_model_json(raw_text))
