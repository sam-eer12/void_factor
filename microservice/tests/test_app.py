from fastapi.testclient import TestClient
import json
import respx
from httpx import Response

from app.main import app


client = TestClient(app)

FOOD_JSON = (
    '{"name":"Banana","nutrients":'
    '{"calories":105,"protein_g":1.3,"carbs_g":27,"fats_g":0.4}}'
)

OPENROUTER_URL = "https://openrouter.ai/api/v1/chat/completions"
NVIDIA_URL = "https://integrate.api.nvidia.com/v1/chat/completions"


def _fake_gemini(monkeypatch, text):
    class FakeResponse:
        pass
    fr = FakeResponse()
    fr.text = text

    class FakeModel:
        def __init__(self, *a, **k):
            pass

        def generate_content(self, *a, **k):
            return fr

    monkeypatch.setattr("app.providers.gemini.genai.configure", lambda *a, **k: None)
    monkeypatch.setattr("app.providers.gemini.genai.GenerativeModel", FakeModel)


def _chat_completion(content):
    return {"choices": [{"message": {"content": content}}]}


def test_gemini_returns_standard_shape(monkeypatch):
    _fake_gemini(monkeypatch, FOOD_JSON)
    resp = client.post(
        "/api/v1/gemini",
        headers={"X-Gemini-Key": "test", "X-User-Id": "u1"},
        files={"image": ("food.jpg", b"fakebytes", "image/jpeg")},
    )
    assert resp.status_code == 200
    body = resp.json()
    assert body["name"] == "Banana"
    assert body["nutrients"]["calories"] == 105
    assert set(body["nutrients"]) == {"calories", "protein_g", "carbs_g", "fats_g"}


def test_gemini_missing_key_returns_401(monkeypatch):
    monkeypatch.setattr("app.config.DEV_GEMINI_KEY", None)
    resp = client.post(
        "/api/v1/gemini",
        headers={"X-User-Id": "u1"},
        files={"image": ("food.jpg", b"x", "image/jpeg")},
    )
    assert resp.status_code == 401


def test_gemini_bad_json_returns_502(monkeypatch):
    _fake_gemini(monkeypatch, "not json at all")
    resp = client.post(
        "/api/v1/gemini",
        headers={"X-Gemini-Key": "test", "X-User-Id": "u1"},
        files={"image": ("food.jpg", b"x", "image/jpeg")},
    )
    assert resp.status_code == 502


@respx.mock
def test_openrouter_success():
    route = respx.post(OPENROUTER_URL).mock(
        return_value=Response(200, json=_chat_completion(FOOD_JSON))
    )
    resp = client.post(
        "/api/v1/openrouter",
        headers={"X-OpenRouter-Key": "test", "X-User-Id": "u1"},
        files={"image": ("food.jpg", b"fakebytes", "image/jpeg")},
    )
    assert resp.status_code == 200
    assert resp.json()["name"] == "Banana"
    assert route.called


def test_openrouter_missing_key_returns_401(monkeypatch):
    monkeypatch.setattr("app.config.DEV_OPENROUTER_KEY", None)
    resp = client.post(
        "/api/v1/openrouter",
        headers={"X-User-Id": "u1"},
        files={"image": ("food.jpg", b"x", "image/jpeg")},
    )
    assert resp.status_code == 401


@respx.mock
def test_openrouter_provider_error_returns_502():
    respx.post(OPENROUTER_URL).mock(return_value=Response(500, text="boom"))
    resp = client.post(
        "/api/v1/openrouter",
        headers={"X-OpenRouter-Key": "test", "X-User-Id": "u1"},
        files={"image": ("food.jpg", b"x", "image/jpeg")},
    )
    assert resp.status_code == 502


@respx.mock
def test_nvidia_success():
    route = respx.post(NVIDIA_URL).mock(
        return_value=Response(200, json=_chat_completion(FOOD_JSON))
    )
    resp = client.post(
        "/api/v1/nvidia",
        headers={"X-Nvidia-Key": "test", "X-User-Id": "u1"},
        files={"image": ("food.jpg", b"fakebytes", "image/jpeg")},
    )
    assert resp.status_code == 200
    assert resp.json()["nutrients"]["protein_g"] == 1.3
    assert route.called
    sent = json.loads(route.calls.last.request.content)
    assert sent["model"] == "nvidia/nemotron-3-nano-omni-30b-a3b-reasoning"
    assert sent["max_tokens"] == 65536
    assert sent["stream"] is False


def test_nvidia_missing_key_returns_401(monkeypatch):
    monkeypatch.setattr("app.config.DEV_NVIDIA_KEY", None)
    resp = client.post(
        "/api/v1/nvidia",
        headers={"X-User-Id": "u1"},
        files={"image": ("food.jpg", b"x", "image/jpeg")},
    )
    assert resp.status_code == 401


def test_normalize_flat_shape():
    from app.parsing import normalize
    out = normalize({"food_name": "Apple", "calories": 95, "protein_g": 0.5,
                     "carbs_g": 25, "fats_g": 0.3})
    assert out["name"] == "Apple"
    assert out["nutrients"]["calories"] == 95
    assert set(out["nutrients"]) == {"calories", "protein_g", "carbs_g", "fats_g"}


def test_normalize_non_dict_raises_502():
    from fastapi import HTTPException
    from app.parsing import normalize
    import pytest
    with pytest.raises(HTTPException) as exc:
        normalize([1, 2, 3])
    assert exc.value.status_code == 502


@respx.mock
def test_openrouter_non_dict_json_returns_502():
    # Model returns valid JSON that is a list, not an object.
    respx.post(OPENROUTER_URL).mock(
        return_value=Response(200, json=_chat_completion("[1,2,3]"))
    )
    resp = client.post(
        "/api/v1/openrouter",
        headers={"X-OpenRouter-Key": "test", "X-User-Id": "u1"},
        files={"image": ("food.jpg", b"x", "image/jpeg")},
    )
    assert resp.status_code == 502


@respx.mock
def test_openrouter_non_json_200_returns_502():
    # Provider returns HTTP 200 but a non-JSON body (e.g. an HTML error page).
    respx.post(OPENROUTER_URL).mock(
        return_value=Response(200, text="<html>not json</html>")
    )
    resp = client.post(
        "/api/v1/openrouter",
        headers={"X-OpenRouter-Key": "test", "X-User-Id": "u1"},
        files={"image": ("food.jpg", b"x", "image/jpeg")},
    )
    assert resp.status_code == 502
