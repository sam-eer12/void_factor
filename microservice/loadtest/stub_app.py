"""The real app with exactly one seam replaced, served by uvicorn under load.

What stays real: nginx-shaped headers, starlette's multipart parsing of a real
JPEG-sized body, the RS256 signature check, route dispatch, `call_gemini` itself
— its key check, its exception handling, its 502 conversion — and the JSON parse
and normalise of the model's answer. Those are the work this service does per
request, and they are what the numbers are meant to measure.

What is replaced is one level below the provider function: `genai.Client`, so the
SDK's network call to Google never happens. Replacing `call_gemini` wholesale
would have been easier and would have measured a route that cannot fail, which
is no use for asking how the service behaves when the provider does fail. The
fake still base64-encodes the image, because the body a provider is sent is
base64 of the upload and that encoding is our CPU, not theirs.

Only the Gemini provider is faked. The OpenRouter and NVIDIA routes still hold
their real implementations and answer 401 without a key, which is what keeps a
load test from reaching a real provider by a typo in a path.

Google's public keys are stubbed too (`app.auth.signing_key_for`), the same seam
the unit tests use. Verification itself still runs against a real 2048-bit key.

Configured by environment so one module serves every phase:

  LOADTEST_PROVIDER_MS    simulated provider round trip (default 0)
  LOADTEST_FAIL_PCT       percent of provider calls that raise (default 0)
  LOADTEST_ENCODE         base64 the image as the SDK would (default 1)
"""
import asyncio
import base64
import os
import random

from app import auth, config
from app.main import create_app
from app.providers import gemini
from loadtest.keys import PROJECT_ID, public_key

config.FIREBASE_PROJECT_ID = PROJECT_ID
auth.signing_key_for = lambda token: public_key()

PROVIDER_DELAY = float(os.getenv("LOADTEST_PROVIDER_MS", "0")) / 1000
FAIL_PCT = float(os.getenv("LOADTEST_FAIL_PCT", "0"))
ENCODE = os.getenv("LOADTEST_ENCODE", "1") == "1"

# Shaped like a real Gemini answer, fences included, so the parse path that runs
# in production runs here too.
_RAW_ANSWER = (
    '```json\n{"name": "grilled chicken salad", "quantity": 1, '
    '"nutrients": {"calories": 412, '
    '"protein_g": 38.5, "carbs_g": 14.2, "fats_g": 22.1}}\n```'
)


class _Response:
    text = _RAW_ANSWER


class _Models:
    async def generate_content(self, *, model, contents):
        if ENCODE:
            for part in contents:
                inline = getattr(part, "inline_data", None)
                if inline is not None and inline.data:
                    base64.b64encode(inline.data)
        if PROVIDER_DELAY:
            await asyncio.sleep(PROVIDER_DELAY)
        if FAIL_PCT and random.random() * 100 < FAIL_PCT:
            # A bare exception, not an HTTPException: the point is to exercise
            # the provider module's own `except Exception` and watch it become
            # a 502, rather than to hand the route a 502 already made.
            raise RuntimeError("simulated provider failure")
        return _Response()


class _Aio:
    models = _Models()


class _FakeClient:
    """Stands in for genai.Client. Built per request by the real call_gemini,
    so its construction cost is on the measured path exactly as it is in
    production."""

    aio = _Aio()

    def __init__(self, *, api_key, http_options=None):
        self.api_key = api_key


gemini.genai.Client = _FakeClient

app = create_app()
