import json
import math
import re

from fastapi import HTTPException

from app.schemas import FoodAnalysis, Nutrients

NUTRIENT_KEYS = ("calories", "protein_g", "carbs_g", "fats_g")

# A number at the start of a string, so "12 g" or "105kcal" — the units a model
# adds when it forgets it was asked for bare numbers — still read as the number.
_LEADING_NUMBER = re.compile(r"\s*(\d+(?:\.\d+)?)")


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


def _to_nutrient(value) -> float | None:
    """One macro as a finite non-negative number, or None when there is none.

    None rather than zero at this stage so `normalize` can tell a reading with a
    gap in it from a reading with nothing in it at all.
    """
    if isinstance(value, bool):
        # bool is an int subclass; `true` is not 1 gram of anything.
        return None
    if isinstance(value, (int, float)):
        number = float(value)
    elif isinstance(value, str):
        match = _LEADING_NUMBER.match(value)
        if match is None:
            return None
        number = float(match.group(1))
    else:
        return None
    if not math.isfinite(number) or number < 0:
        return None
    return number


def normalize(data: dict) -> FoodAnalysis:
    """Coerce a provider's parsed JSON into {name, quantity, nutrients:{...}}.

    Accepts either the nested target shape or a flat {food_name, calories, ...}.

    `quantity` is how many of the serving the nutrients describe are on the
    plate; the nutrients themselves are always for one. Read from the aliases a
    model reaches for when it ignores the asked-for key, in the same spirit as
    `food_name` above.

    Every nutrient leaves as a number. One the model omitted or garbled becomes
    0 — the form shows it and the user can correct it, which is the same thing
    the client did with a null before this contract existed. A reading where
    *none* of the four is usable is not a reading, and is refused as one: a
    food with zero of everything would be saved as a real entry otherwise.
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
    readings = {key: _to_nutrient(nutrients.get(key)) for key in NUTRIENT_KEYS}
    if all(value is None for value in readings.values()):
        raise HTTPException(status_code=502, detail="invalid response from model")
    name = data.get("name") or data.get("food_name") or ""
    return FoodAnalysis(
        name=str(name).strip(),
        quantity=_to_quantity(quantity),
        nutrients=Nutrients(
            **{key: value or 0.0 for key, value in readings.items()}
        ),
    )
