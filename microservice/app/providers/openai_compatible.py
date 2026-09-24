import base64
import httpx
from fastapi import HTTPException

from app import config, http_pool
from app.parsing import parse_model_json, normalize
from app.schemas import FoodAnalysis


def build_vision_messages(image_bytes: bytes, mime_type: str) -> list:
    b64 = base64.b64encode(image_bytes).decode("utf-8")
    data_uri = f"data:{mime_type};base64,{b64}"
    return [
        {
            "role": "user",
            "content": [
                {"type": "text", "text": config.PROMPT},
                {"type": "image_url", "image_url": {"url": data_uri}},
            ],
        }
    ]


async def call_openai_compatible(
    url: str,
    api_key: str,
    model: str,
    image_bytes: bytes,
    mime_type: str,
    extra_payload: dict | None = None,
) -> FoodAnalysis:
    payload = {
        "model": model,
        "messages": build_vision_messages(image_bytes, mime_type),
    }
    if extra_payload:
        payload.update(extra_payload)
    headers = {"Authorization": f"Bearer {api_key}"}
    try:
        # The shared pool, not a client per call: a fresh client paid a TLS
        # handshake to the provider on every analysis. See app/http_pool.py.
        resp = await http_pool.client().post(url, headers=headers, json=payload)
    except httpx.HTTPError:
        raise HTTPException(status_code=502, detail="provider request failed")
    if resp.status_code != 200:
        raise HTTPException(
            status_code=502, detail=f"provider error: {resp.status_code}"
        )
    try:
        body = resp.json()
        content = body["choices"][0]["message"]["content"]
    except (ValueError, KeyError, IndexError, TypeError):
        raise HTTPException(status_code=502, detail="invalid response from model")
    return normalize(parse_model_json(content))
