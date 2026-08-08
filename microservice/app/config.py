import os
from dotenv import load_dotenv

load_dotenv()

DEV_GEMINI_KEY = os.getenv("x_gemini_key")
DEV_OPENROUTER_KEY = os.getenv("x_openrouter_key")
DEV_NVIDIA_KEY = os.getenv("NVIDIA_API_KEY")

GEMINI_MODEL = "gemini-3.1-flash-lite-preview"
OPENROUTER_MODEL = os.getenv("OPENROUTER_MODEL", "google/gemini-2.0-flash-001")
NVIDIA_MODEL = "nvidia/nemotron-3-nano-omni-30b-a3b-reasoning"

OPENROUTER_URL = "https://openrouter.ai/api/v1/chat/completions"
NVIDIA_URL = "https://integrate.api.nvidia.com/v1/chat/completions"

PROMPT = (
    "Analyze the food in this image. Respond with ONLY a JSON object, no markdown, "
    "in exactly this shape: "
    '{"name": <food name string>, "nutrients": {"calories": <number>, '
    '"protein_g": <number>, "carbs_g": <number>, "fats_g": <number>}}'
)
