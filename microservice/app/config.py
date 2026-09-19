import os
from dotenv import load_dotenv

load_dotenv()

DEV_GEMINI_KEY = os.getenv("x_gemini_key")
DEV_OPENROUTER_KEY = os.getenv("x_openrouter_key")
DEV_NVIDIA_KEY = os.getenv("NVIDIA_API_KEY")

# The Firebase project whose ID tokens this service accepts. Not a secret —
# it already ships inside the Flutter binary. Unset means the /api/ routes
# fail closed with a 503; see app/auth.py.
FIREBASE_PROJECT_ID = os.getenv("FIREBASE_PROJECT_ID")

GEMINI_MODEL = "gemini-3.1-flash-lite-preview"
OPENROUTER_MODEL = os.getenv("OPENROUTER_MODEL", "google/gemini-2.0-flash-001")
NVIDIA_MODEL = "nvidia/nemotron-3-nano-omni-30b-a3b-reasoning"

OPENROUTER_URL = "https://openrouter.ai/api/v1/chat/completions"
NVIDIA_URL = "https://integrate.api.nvidia.com/v1/chat/completions"

# The nutrient figures are asked for per single serving, with the count carried
# separately, because that is the shape the app stores and edits: FoodEntry keeps
# per-serving macros beside a quantity multiplier, and the form's stepper adjusts
# the multiplier. A model that totalled the plate instead would make every figure
# on that form wrong the moment the user corrected the count.
PROMPT = (
    "Analyze the food in this image. Respond with ONLY a JSON object, no markdown, "
    "in exactly this shape: "
    '{"name": <food name string>, "quantity": <number>, '
    '"nutrients": {"calories": <number>, '
    '"protein_g": <number>, "carbs_g": <number>, "fats_g": <number>}}. '
    "The nutrient figures must describe ONE piece or serving on its own, never "
    "the whole plate. If several pieces of the same food are visible, give the "
    "figures for a single piece and set quantity to how many there are. "
    "Set quantity to 1 for a single item, or when you cannot tell how many."
)
