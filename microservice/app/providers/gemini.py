from google import genai
from google.genai import types
from fastapi import HTTPException

from app import config, http_pool, images
from app.parsing import parse_model_json, normalize
from app.schemas import FoodAnalysis


async def call_gemini(
    api_key_header: str | None, image_bytes: bytes, mime_type: str
) -> FoodAnalysis:
    api_key = api_key_header or config.DEV_GEMINI_KEY
    if not api_key:
        raise HTTPException(status_code=401, detail="Gemini API Key missing")
    images.require_one_of(mime_type, images.SUPPORTED)

    # A client per call rather than a module-level one: the key comes from the
    # caller, so there is no single client to reuse across users. It costs no
    # sockets, being a thin wrapper over the shared pool (app/http_pool.py).
    #
    # Without a client handed in, the SDK builds its own httpx pool per
    # genai.Client — a fresh TLS handshake to Google on every analysis, and a
    # pool left for __del__ to close. Handing it ours also stops it closing one
    # it does not own: BaseApiClient.aclose skips a caller-supplied client
    # deliberately, so the pool's lifetime is the app's to manage.
    client = genai.Client(
        api_key=api_key,
        http_options=types.HttpOptions(httpx_async_client=http_pool.client()),
    )
    try:
        # The async entry point, not models.generate_content. The synchronous
        # one blocks the event loop for the whole provider round trip, so a
        # single vision call — seconds, not milliseconds — stalls every other
        # request the worker is serving, however little work they need.
        response = await client.aio.models.generate_content(
            model=config.GEMINI_MODEL,
            contents=[
                config.PROMPT,
                types.Part.from_bytes(data=image_bytes, mime_type=mime_type),
            ],
        )
        raw_text = response.text
    except Exception:
        # Still one message for every failure, so a bad key remains
        # indistinguishable from an outage. Narrowing this needs the SDK to
        # expose an auth-specific error; noted as a known gap.
        raise HTTPException(status_code=502, detail="provider request failed")
    return normalize(parse_model_json(raw_text))
