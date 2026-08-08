from fastapi import FastAPI, Header, UploadFile, File, HTTPException
import google.generativeai as genai
import httpx
import base64
import json
import os
from dotenv import load_dotenv

load_dotenv()

app = FastAPI()

DEV_GEMINI_KEY = os.getenv("x_gemini_key")
DEV_OPENROUTER_KEY = os.getenv("x_openrouter_key")
DEV_NVIDIA_KEY = os.getenv("NVIDIA_API_KEY")

GEMINI_MODEL = "gemini-3.1-flash-lite-preview"
OPENROUTER_MODEL = os.getenv("OPENROUTER_MODEL", "google/gemini-2.0-flash-001")

PROMPT = (
    "Analyze the food in this image. Respond with ONLY a JSON object, no markdown, "
    "in exactly this shape: "
    '{"name": <food name string>, "nutrients": {"calories": <number>, '
    '"protein_g": <number>, "carbs_g": <number>, "fats_g": <number>}}'
)


def _strip_json_fences(text: str) -> str:
    return text.replace("```json", "").replace("```", "").strip()


def _parse_model_json(raw_text: str) -> dict:
    try:
        return json.loads(_strip_json_fences(raw_text))
    except (json.JSONDecodeError, TypeError, AttributeError):
        raise HTTPException(status_code=502, detail="invalid response from model")


def _normalize(data: dict) -> dict:
    """Coerce a provider's parsed JSON into {name, nutrients:{...}}.

    Accepts either the nested target shape or a flat {food_name, calories, ...}.
    """
    nutrients = data.get("nutrients")
    if not isinstance(nutrients, dict):
        nutrients = data
    return {
        "name": data.get("name") or data.get("food_name") or "",
        "nutrients": {
            "calories": nutrients.get("calories"),
            "protein_g": nutrients.get("protein_g"),
            "carbs_g": nutrients.get("carbs_g"),
            "fats_g": nutrients.get("fats_g"),
        },
    }


def _build_vision_messages(image_bytes: bytes) -> list:
    b64 = base64.b64encode(image_bytes).decode("utf-8")
    data_uri = f"data:image/jpeg;base64,{b64}"
    return [
        {
            "role": "user",
            "content": [
                {"type": "text", "text": PROMPT},
                {"type": "image_url", "image_url": {"url": data_uri}},
            ],
        }
    ]


async def _call_openai_compatible(
    url: str,
    api_key: str,
    model: str,
    image_bytes: bytes,
    extra_payload: dict | None = None,
) -> dict:
    payload = {"model": model, "messages": _build_vision_messages(image_bytes)}
    if extra_payload:
        payload.update(extra_payload)
    headers = {"Authorization": f"Bearer {api_key}"}
    try:
        async with httpx.AsyncClient(timeout=60) as http_client:
            resp = await http_client.post(url, headers=headers, json=payload)
    except httpx.HTTPError as e:
        raise HTTPException(status_code=502, detail=f"provider request failed: {e}")
    if resp.status_code != 200:
        raise HTTPException(
            status_code=502, detail=f"provider error: {resp.status_code}"
        )
    body = resp.json()
    try:
        content = body["choices"][0]["message"]["content"]
    except (KeyError, IndexError, TypeError):
        raise HTTPException(status_code=502, detail="invalid response from model")
    return _normalize(_parse_model_json(content))


@app.post("/api/v1/gemini")
async def analyze_with_gemini(
    image: UploadFile = File(...),
    x_gemini_key: str = Header(None),
):
    api_key = x_gemini_key or DEV_GEMINI_KEY
    if not api_key:
        raise HTTPException(status_code=401, detail="Gemini API Key missing")

    genai.configure(api_key=api_key)
    model = genai.GenerativeModel(GEMINI_MODEL)
    image_data = await image.read()
    try:
        response = model.generate_content(
            [PROMPT, {"mime_type": "image/jpeg", "data": image_data}]
        )
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"provider request failed: {e}")
    return _normalize(_parse_model_json(response.text))


@app.post("/api/v1/openrouter")
async def analyze_with_openrouter(
    image: UploadFile = File(...),
    x_openrouter_key: str = Header(None),
):
    api_key = x_openrouter_key or DEV_OPENROUTER_KEY
    if not api_key:
        raise HTTPException(status_code=401, detail="OpenRouter API Key missing")
    image_data = await image.read()
    return await _call_openai_compatible(
        "https://openrouter.ai/api/v1/chat/completions",
        api_key,
        OPENROUTER_MODEL,
        image_data,
    )


@app.get("/")
async def root():
    return {"message": "Welcome to the Void Factor Microservice"}


@app.get("/health")
async def health_check():
    return {"status": "healthy"}


if __name__ == "__main__":
    import uvicorn

    uvicorn.run("app:app", host="0.0.0.0", port=8000, reload=True)
