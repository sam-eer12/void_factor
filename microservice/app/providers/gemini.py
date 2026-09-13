import httpx
from google import genai
from google.genai import types
from fastapi import HTTPException

from app import config
from app.parsing import parse_model_json, normalize


# One connection pool to Google per worker process, shared by every request.
#
# The SDK builds its own httpx.AsyncClient for each genai.Client it is not given
# one for, which — with a client per call, below — would mean a fresh TLS
# handshake to Google on every analysis and a pool left to be closed by
# __del__, which only runs if garbage collection happens to fire inside a live
# event loop. Handing the SDK a client also stops it closing one it does not
# own: BaseApiClient.aclose skips a caller-supplied client deliberately, so the
# pool's lifetime is ours to manage (see aclose below).
#
# Pooling across callers is safe even though the key differs per request: the
# key travels as a request header, not as a property of the connection.
#
# 60s to match the other providers, and to stay inside nginx's 90s read timeout
# so a slow call is cut off here rather than by the proxy.
_http_client = httpx.AsyncClient(timeout=60)

# The SDK copies this rather than holding the instance, so one shared object
# cannot be mutated by one caller into another caller's client.
_HTTP_OPTIONS = types.HttpOptions(httpx_async_client=_http_client)


async def aclose() -> None:
    """Releases the shared pool. Wired to app shutdown in app/main.py."""
    await _http_client.aclose()


async def call_gemini(api_key_header: str | None, image_bytes: bytes) -> dict:
    api_key = api_key_header or config.DEV_GEMINI_KEY
    if not api_key:
        raise HTTPException(status_code=401, detail="Gemini API Key missing")

    # A client per call rather than a module-level one: the key comes from the
    # caller, so there is no single client to reuse across users. It costs no
    # sockets, being a thin wrapper over the shared pool above.
    client = genai.Client(api_key=api_key, http_options=_HTTP_OPTIONS)
    try:
        # The async entry point, not models.generate_content. The synchronous
        # one blocks the event loop for the whole provider round trip, so a
        # single vision call — seconds, not milliseconds — stalls every other
        # request the worker is serving, however little work they need.
        response = await client.aio.models.generate_content(
            model=config.GEMINI_MODEL,
            contents=[
                config.PROMPT,
                types.Part.from_bytes(data=image_bytes, mime_type="image/jpeg"),
            ],
        )
        raw_text = response.text
    except Exception:
        # Still one message for every failure, so a bad key remains
        # indistinguishable from an outage. Narrowing this needs the SDK to
        # expose an auth-specific error; noted as a known gap.
        raise HTTPException(status_code=502, detail="provider request failed")
    return normalize(parse_model_json(raw_text))
