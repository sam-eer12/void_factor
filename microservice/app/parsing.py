import json
from fastapi import HTTPException


def _strip_json_fences(text: str) -> str:
    return text.replace("```json", "").replace("```", "").strip()


def parse_model_json(raw_text: str) -> dict:
    try:
        return json.loads(_strip_json_fences(raw_text))
    except (json.JSONDecodeError, TypeError, AttributeError):
        raise HTTPException(status_code=502, detail="invalid response from model")


def _to_quantity(value) -> float:
    """How many of the described serving the model saw, defaulting to one.

    Anything missing, unparseable or non-positive reads as a single serving: the
    nutrients describe one serving either way, so a bad count costs the
    multiplier rather than the whole reading. No upper bound is applied here —
    the client snaps this onto its stepper's range, and inventing a different
    ceiling in two places is how they come to disagree.
    """
    try:
        quantity = float(value)
    except (TypeError, ValueError):
        return 1.0
    # NaN fails every comparison, so it has to be caught by identity with itself.
    if quantity != quantity or quantity in (float("inf"), float("-inf")):
        return 1.0
    return quantity if quantity > 0 else 1.0


def normalize(data: dict) -> dict:
    """Coerce a provider's parsed JSON into {name, quantity, nutrients:{...}}.

    Accepts either the nested target shape or a flat {food_name, calories, ...}.

    `quantity` is how many of the serving the nutrients describe are on the
    plate; the nutrients themselves are always for one. Read from the aliases a
    model reaches for when it ignores the asked-for key, in the same spirit as
    `food_name` above.
    """
    if not isinstance(data, dict):
        raise HTTPException(status_code=502, detail="invalid response from model")
    nutrients = data.get("nutrients")
    if not isinstance(nutrients, dict):
        nutrients = data
    quantity = data.get("quantity")
    if quantity is None:
        quantity = data.get("servings")
    if quantity is None:
        quantity = data.get("count")
    return {
        "name": data.get("name") or data.get("food_name") or "",
        "quantity": _to_quantity(quantity),
        "nutrients": {
            "calories": nutrients.get("calories"),
            "protein_g": nutrients.get("protein_g"),
            "carbs_g": nutrients.get("carbs_g"),
            "fats_g": nutrients.get("fats_g"),
        },
    }
