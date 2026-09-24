"""Upload validation, the response contract, the shared pool, and the uid
nginx rate-limits on.

Provider tests here replace auth wholesale, as test_app.py does. The
/internal/verify tests at the bottom use real minted tokens instead, because
there the verification *is* the thing under test.
"""
import base64
import json

import pytest
import respx
from fastapi import HTTPException
from fastapi.testclient import TestClient
from httpx import Response

from app import http_pool, images
from app.auth import verify_caller
from app.main import app
from app.parsing import normalize
from tests.conftest import JPEG, UID

client = TestClient(app)

OPENROUTER_URL = "https://openrouter.ai/api/v1/chat/completions"
FOOD_JSON = (
    '{"name":"Banana","nutrients":'
    '{"calories":105,"protein_g":1.3,"carbs_g":27,"fats_g":0.4}}'
)

PNG = b"\x89PNG\r\n\x1a\n" + b"\x00" * 16
WEBP = b"RIFF\x00\x00\x00\x00WEBPVP8 " + b"\x00" * 8
HEIC = b"\x00\x00\x00\x18ftypheic" + b"\x00" * 12
HEIF = b"\x00\x00\x00\x18ftypmif1" + b"\x00" * 12


@pytest.fixture
def as_user():
    app.dependency_overrides[verify_caller] = lambda: UID
    yield
    app.dependency_overrides.clear()


def _chat_completion(content):
    return {"choices": [{"message": {"content": content}}]}


def _post(provider, data, key_header):
    return client.post(
        f"/api/v1/{provider}",
        headers={key_header: "test", "X-User-Id": UID},
        files={"image": ("meal.jpg", data, "image/jpeg")},
    )


# ── Upload validation ──


@pytest.mark.parametrize(
    "data, expected",
    [
        (JPEG, images.JPEG),
        (PNG, images.PNG),
        (WEBP, images.WEBP),
        (HEIC, images.HEIC),
        (HEIF, images.HEIF),
        (b"GIF89a" + b"\x00" * 16, None),
        (b"%PDF-1.7", None),
        (b"<html>", None),
        (b"RIFF\x00\x00\x00\x00WAVE", None),
        (b"\x00\x00\x00\x18ftypisom", None),  # an MP4, not an image
        (b"\xff\xd8", None),  # too short to be sure of anything
    ],
)
def test_sniff_decides_from_the_bytes(data, expected):
    assert images.sniff(data) == expected


def test_a_non_image_is_refused_before_the_provider(as_user, monkeypatch):
    # The declared type says JPEG. The bytes say otherwise, and the bytes win.
    async def _provider_must_not_run(*a, **k):
        raise AssertionError("provider reached")

    monkeypatch.setattr("app.routes.call_gemini", _provider_must_not_run)
    resp = _post("gemini", b"this is not a photo", "X-Gemini-Key")
    assert resp.status_code == 415
    assert resp.json()["detail"] == "image: unrecognised format"


def test_an_empty_upload_is_refused(as_user):
    resp = _post("gemini", b"", "X-Gemini-Key")
    assert resp.status_code == 400
    assert resp.json()["detail"].startswith("image:")


def test_an_oversized_upload_is_refused(as_user, monkeypatch):
    monkeypatch.setattr("app.images.MAX_IMAGE_BYTES", len(JPEG) - 1)
    resp = _post("gemini", JPEG, "X-Gemini-Key")
    assert resp.status_code == 413
    assert resp.json()["detail"] == "image: too large"


def test_an_upload_at_the_cap_is_accepted(as_user, monkeypatch):
    monkeypatch.setattr("app.images.MAX_IMAGE_BYTES", len(JPEG))
    seen = {}

    async def _fake_gemini(key, data, mime):
        seen["len"] = len(data)
        return normalize(json.loads(FOOD_JSON))

    monkeypatch.setattr("app.routes.call_gemini", _fake_gemini)
    assert _post("gemini", JPEG, "X-Gemini-Key").status_code == 200
    assert seen["len"] == len(JPEG)


@respx.mock
def test_the_detected_type_is_what_the_provider_is_told(as_user):
    # Named meal.jpg and declared image/jpeg, as the app sends every upload. It
    # is a PNG, and the provider must be told so.
    route = respx.post(OPENROUTER_URL).mock(
        return_value=Response(200, json=_chat_completion(FOOD_JSON))
    )
    assert _post("openrouter", PNG, "X-OpenRouter-Key").status_code == 200
    sent = json.loads(route.calls.last.request.content)
    url = sent["messages"][0]["content"][1]["image_url"]["url"]
    assert url == "data:image/png;base64," + base64.b64encode(PNG).decode()


def test_gemini_is_told_the_detected_type(as_user, monkeypatch):
    seen = {}

    class FakeModels:
        async def generate_content(self, *, model, contents):
            seen["mime"] = contents[1].inline_data.mime_type

            class R:
                text = FOOD_JSON

            return R()

    class FakeClient:
        def __init__(self, *a, **k):
            self.aio = type("Aio", (), {"models": FakeModels()})()

    monkeypatch.setattr("app.providers.gemini.genai.Client", FakeClient)
    assert _post("gemini", HEIC, "X-Gemini-Key").status_code == 200
    assert seen["mime"] == "image/heic"


@respx.mock
def test_heic_is_refused_by_a_provider_that_cannot_read_it(as_user):
    route = respx.post(OPENROUTER_URL).mock(
        return_value=Response(200, json=_chat_completion(FOOD_JSON))
    )
    resp = _post("openrouter", HEIC, "X-OpenRouter-Key")
    assert resp.status_code == 415
    assert resp.json()["detail"] == "image: format not supported by this provider"
    assert not route.called


# ── The response contract ──


def test_a_missing_nutrient_ships_as_zero_not_null():
    out = normalize({"name": "Toast", "calories": 80}).model_dump()
    assert out["nutrients"] == {
        "calories": 80.0, "protein_g": 0.0, "carbs_g": 0.0, "fats_g": 0.0,
    }


def test_nutrients_the_model_wrote_with_units_still_read():
    out = normalize({"name": "Rice", "nutrients": {
        "calories": "206 kcal", "protein_g": "4.3g", "carbs_g": " 45 ",
        "fats_g": "0.4 grams",
    }})
    assert out.nutrients.model_dump() == {
        "calories": 206.0, "protein_g": 4.3, "carbs_g": 45.0, "fats_g": 0.4,
    }


@pytest.mark.parametrize(
    "bad", [None, "", "lots", -5, float("nan"), float("inf"), True, [1], {"a": 1}]
)
def test_an_unusable_nutrient_reads_as_zero(bad):
    out = normalize({"name": "Toast", "calories": 80, "protein_g": bad})
    assert out.nutrients.protein_g == 0.0


def test_a_reading_with_no_usable_nutrient_is_not_a_reading():
    with pytest.raises(HTTPException) as exc:
        normalize({"name": "Mystery", "nutrients": {"calories": None}})
    assert exc.value.status_code == 502
    with pytest.raises(HTTPException):
        normalize({"name": "Mystery"})


def test_the_name_is_always_a_string():
    assert normalize({"name": None, "calories": 1}).name == ""
    assert normalize({"name": "  Dal  ", "calories": 1}).name == "Dal"


def test_the_contract_is_published():
    schema = client.get("/openapi.json").json()
    analysis = schema["components"]["schemas"]["FoodAnalysis"]
    assert set(analysis["required"]) == {"name", "quantity", "nutrients"}
    nutrients = schema["components"]["schemas"]["Nutrients"]
    assert set(nutrients["required"]) == {
        "calories", "protein_g", "carbs_g", "fats_g",
    }
    # /internal/verify is nginx's business, not a client's.
    assert "/internal/verify" not in schema["paths"]


@respx.mock
def test_the_wire_body_has_no_nulls(as_user):
    respx.post(OPENROUTER_URL).mock(
        return_value=Response(
            200, json=_chat_completion('{"name":"Egg","calories":78}')
        )
    )
    body = _post("openrouter", JPEG, "X-OpenRouter-Key").json()
    assert body == {
        "name": "Egg",
        "quantity": 1.0,
        "nutrients": {
            "calories": 78.0, "protein_g": 0.0, "carbs_g": 0.0, "fats_g": 0.0,
        },
    }


# ── The shared pool ──


@respx.mock
def test_openai_compatible_calls_share_one_pool(as_user, monkeypatch):
    respx.post(OPENROUTER_URL).mock(
        return_value=Response(200, json=_chat_completion(FOOD_JSON))
    )
    built = []
    real = http_pool.httpx.AsyncClient

    def _counting(*a, **k):
        built.append(1)
        return real(*a, **k)

    monkeypatch.setattr(http_pool, "_client", None)
    monkeypatch.setattr(http_pool.httpx, "AsyncClient", _counting)
    for _ in range(3):
        assert _post("openrouter", JPEG, "X-OpenRouter-Key").status_code == 200
    assert len(built) == 1


def test_a_closed_pool_is_rebuilt_rather_than_reused():
    import asyncio

    first = http_pool.client()
    asyncio.run(http_pool.aclose())
    second = http_pool.client()
    assert first.is_closed
    assert second is not first and not second.is_closed


# ── The uid nginx rate-limits on ──


def test_verify_hands_nginx_the_verified_uid(auth_headers):
    resp = client.get("/internal/verify", headers=auth_headers)
    assert resp.status_code == 204
    assert resp.headers["X-Verified-Uid"] == UID


def test_verify_refuses_a_forged_token(configured):
    resp = client.get(
        "/internal/verify",
        headers={"Authorization": "Bearer forged", "X-User-Id": UID},
    )
    assert resp.status_code == 401
    assert "X-Verified-Uid" not in resp.headers


def test_verify_refuses_a_borrowed_uid(mint):
    # A real token for one user, presented with another user's id: the case
    # that used to spend the victim's rate-limit bucket.
    resp = client.get(
        "/internal/verify",
        headers={"Authorization": f"Bearer {mint()}", "X-User-Id": "victim"},
    )
    assert resp.status_code == 401
    assert "X-Verified-Uid" not in resp.headers
