from fastapi.testclient import TestClient
import json
import pytest
import respx
from httpx import Response

from app.auth import verify_caller
from app.main import app


client = TestClient(app)


@pytest.fixture(autouse=True)
def _authenticated():
    """These tests are about providers, not about who may call them.

    Auth is replaced wholesale rather than by minting a token per request, so a
    change to the token format can never quietly turn a provider test green.
    test_auth.py covers the real verifier.
    """
    app.dependency_overrides[verify_caller] = lambda: "u1"
    yield
    app.dependency_overrides.clear()

FOOD_JSON = (
    '{"name":"Banana","nutrients":'
    '{"calories":105,"protein_g":1.3,"carbs_g":27,"fats_g":0.4}}'
)

OPENROUTER_URL = "https://openrouter.ai/api/v1/chat/completions"
NVIDIA_URL = "https://integrate.api.nvidia.com/v1/chat/completions"


def _fake_gemini(monkeypatch, text):
    """Stubs the async provider call.

    The fake mirrors `client.aio.models.generate_content`, not the synchronous
    `client.models.generate_content`: a stub of the sync path would still pass
    if the provider quietly reverted to the call that blocks the event loop.
    """
    class FakeResponse:
        pass
    fr = FakeResponse()
    fr.text = text

    class FakeAsyncModels:
        async def generate_content(self, *a, **k):
            return fr

    class FakeAio:
        def __init__(self):
            self.models = FakeAsyncModels()

    class FakeClient:
        def __init__(self, *a, **k):
            self.aio = FakeAio()

    monkeypatch.setattr("app.providers.gemini.genai.Client", FakeClient)


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


# ── The serving count ──
#
# The nutrients describe one serving; `quantity` says how many of it are on the
# plate. The split exists because that is how the app stores and edits an entry,
# so these tests pin both halves of the contract.

MULTI_PIECE_JSON = (
    '{"name":"Samosa","quantity":3,"nutrients":'
    '{"calories":262,"protein_g":3.5,"carbs_g":24,"fats_g":17}}'
)


def test_response_carries_the_serving_count(monkeypatch):
    _fake_gemini(monkeypatch, MULTI_PIECE_JSON)
    resp = client.post(
        "/api/v1/gemini",
        headers={"X-Gemini-Key": "test", "X-User-Id": "u1"},
        files={"image": ("food.jpg", b"fakebytes", "image/jpeg")},
    )
    body = resp.json()
    assert body["quantity"] == 3
    # Per piece, not per plate: 262 is one samosa. Totalling here would make the
    # form's per-serving fields wrong the moment the user changed the count.
    assert body["nutrients"]["calories"] == 262


def test_response_defaults_the_count_to_one(monkeypatch):
    # FOOD_JSON predates the field, which is exactly what an older or lazier
    # model still returns.
    _fake_gemini(monkeypatch, FOOD_JSON)
    resp = client.post(
        "/api/v1/gemini",
        headers={"X-Gemini-Key": "test", "X-User-Id": "u1"},
        files={"image": ("food.jpg", b"fakebytes", "image/jpeg")},
    )
    assert resp.json()["quantity"] == 1.0


def test_normalize_reads_the_count():
    from app.parsing import normalize
    assert normalize({"name": "Samosa", "quantity": 3})["quantity"] == 3.0


def test_normalize_reads_a_count_the_model_named_differently():
    from app.parsing import normalize
    # The prompt asks for `quantity`; a model that answers `servings` or `count`
    # has still counted the plate, and dropping that to 1 would silently third
    # the user's calories.
    assert normalize({"name": "Samosa", "servings": 2})["quantity"] == 2.0
    assert normalize({"name": "Samosa", "count": 4})["quantity"] == 4.0


def test_normalize_defaults_a_missing_count_to_one():
    from app.parsing import normalize
    assert normalize({"name": "Banana"})["quantity"] == 1.0


def test_normalize_defaults_an_unusable_count_to_one():
    from app.parsing import normalize
    # The nutrients still describe one serving, so a nonsense count costs the
    # multiplier rather than the reading.
    for bad in (None, 0, -2, "lots", "", [3], float("nan"), float("inf")):
        assert normalize({"name": "Banana", "quantity": bad})["quantity"] == 1.0


def test_normalize_accepts_a_count_sent_as_a_string():
    from app.parsing import normalize
    assert normalize({"name": "Samosa", "quantity": "3"})["quantity"] == 3.0


def test_prompt_asks_for_per_serving_figures_and_a_count():
    from app import config
    # The whole split depends on the model being told about it, and the prompt
    # is the only place that happens.
    assert '"quantity"' in config.PROMPT
    assert "ONE piece or serving" in config.PROMPT
    assert "never the whole plate" in config.PROMPT.replace("\n", " ")
