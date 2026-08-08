from fastapi.testclient import TestClient
import app as appmod
from app import app

client = TestClient(app)

FOOD_JSON = (
    '{"name":"Banana","nutrients":'
    '{"calories":105,"protein_g":1.3,"carbs_g":27,"fats_g":0.4}}'
)


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

    monkeypatch.setattr("app.genai.configure", lambda *a, **k: None)
    monkeypatch.setattr("app.genai.GenerativeModel", FakeModel)


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
    monkeypatch.setattr("app.DEV_GEMINI_KEY", None)
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
