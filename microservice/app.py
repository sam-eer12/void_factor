from fastapi import FastAPI, Header, UploadFile, File, HTTPException
import google.generativeai as genai
import json
import os
from dotenv import load_dotenv

load_dotenv()

app = FastAPI()

DEV_GEMINI_KEY = os.getenv("x_gemini_key")
DEV_OPENROUTER_KEY = os.getenv("x_openrouter_key")
DEV_NVIDIA_KEY = os.getenv("NVIDIA_API_KEY")

GEMINI_MODEL = "gemini-3.1-flash-lite-preview"

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


@app.get("/")
async def root():
    return {"message": "Welcome to the Void Factor Microservice"}


@app.get("/health")
async def health_check():
    return {"status": "healthy"}


if __name__ == "__main__":
    import uvicorn

    uvicorn.run("app:app", host="0.0.0.0", port=8000, reload=True)
