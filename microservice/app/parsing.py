import json
from fastapi import HTTPException


def _strip_json_fences(text: str) -> str:
    return text.replace("```json", "").replace("```", "").strip()


def parse_model_json(raw_text: str) -> dict:
    try:
        return json.loads(_strip_json_fences(raw_text))
    except (json.JSONDecodeError, TypeError, AttributeError):
        raise HTTPException(status_code=502, detail="invalid response from model")


def normalize(data: dict) -> dict:
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
