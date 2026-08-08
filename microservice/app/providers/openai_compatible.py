import base64
import httpx
from fastapi import HTTPException

from app import config
from app.parsing import parse_model_json, normalize


def build_vision_messages(image_bytes: bytes) -> list:
    b64 = base64.b64encode(image_bytes).decode("utf-8")
    data_uri = f"data:image/jpeg;base64,{b64}"
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
    extra_payload: dict | None = None,
) -> dict:
    payload = {"model": model, "messages": build_vision_messages(image_bytes)}
    if extra_payload:
        payload.update(extra_payload)
    headers = {"Authorization": f"Bearer {api_key}"}
    try:
        async with httpx.AsyncClient(timeout=60) as http_client:
            resp = await http_client.post(url, headers=headers, json=payload)
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
