"""Firebase ID token verification on the provider routes.

The routes themselves are covered in test_app.py with auth overridden; this file
covers only who is allowed to reach them.
"""
import time

import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa
from fastapi.testclient import TestClient

from app.main import app
from tests.conftest import ISSUER, PROJECT_ID, UID

client = TestClient(app)

IMAGE = {"image": ("food.jpg", b"x", "image/jpeg")}


def _post(headers):
    return client.post("/api/v1/gemini", headers=headers, files=IMAGE)


def test_missing_authorization_is_rejected(configured):
    assert _post({"X-User-Id": UID}).status_code == 401


def test_non_bearer_authorization_is_rejected(configured, mint):
    resp = _post({"Authorization": mint(), "X-User-Id": UID})
    assert resp.status_code == 401


def test_missing_user_id_header_is_rejected(configured, mint):
    # nginx rejects this with a 400 before FastAPI sees it; a caller reaching the
    # service directly must not get further than one arriving through the proxy.
    assert _post({"Authorization": f"Bearer {mint()}"}).status_code == 401


def test_user_id_not_matching_the_token_is_rejected(mint):
    resp = _post({"Authorization": f"Bearer {mint()}", "X-User-Id": "someone-else"})
    assert resp.status_code == 401


def test_token_for_another_project_is_rejected(mint):
    resp = _post({"Authorization": f"Bearer {mint(aud='other-project')}",
                  "X-User-Id": UID})
    assert resp.status_code == 401


def test_token_from_another_issuer_is_rejected(mint):
    resp = _post({"Authorization": f"Bearer {mint(iss='https://evil.example')}",
                  "X-User-Id": UID})
    assert resp.status_code == 401


def test_expired_token_is_rejected(mint):
    past = int(time.time()) - 60
    resp = _post({"Authorization": f"Bearer {mint(exp=past, iat=past - 3600)}",
                  "X-User-Id": UID})
    assert resp.status_code == 401


def test_token_without_a_subject_is_rejected(mint):
    resp = _post({"Authorization": f"Bearer {mint(sub=None)}", "X-User-Id": UID})
    assert resp.status_code == 401


def test_token_signed_by_another_key_is_rejected(configured):
    impostor = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    now = int(time.time())
    forged = jwt.encode(
        {"sub": UID, "aud": PROJECT_ID, "iss": ISSUER, "iat": now, "exp": now + 3600},
        impostor,
        algorithm="RS256",
    )
    resp = _post({"Authorization": f"Bearer {forged}", "X-User-Id": UID})
    assert resp.status_code == 401


def test_garbage_token_is_rejected(configured):
    resp = _post({"Authorization": "Bearer not-a-jwt", "X-User-Id": UID})
    assert resp.status_code == 401


def test_unconfigured_project_fails_closed(monkeypatch, mint):
    """A deploy that forgot FIREBASE_PROJECT_ID must not look like a working one."""
    monkeypatch.setattr("app.config.FIREBASE_PROJECT_ID", None)
    resp = _post({"Authorization": f"Bearer {mint()}", "X-User-Id": UID})
    assert resp.status_code == 503


def test_a_valid_token_reaches_the_provider(monkeypatch, auth_headers):
    """The happy path stops at the provider call, proving auth let it through."""

    async def _sentinel(api_key_header, image_bytes):
        raise RuntimeError("provider reached")

    monkeypatch.setattr("app.routes.call_gemini", _sentinel)
    with pytest.raises(RuntimeError, match="provider reached"):
        _post(auth_headers)


def test_health_needs_no_token():
    assert client.get("/health").status_code == 200


def test_root_needs_no_token():
    assert client.get("/").status_code == 200
