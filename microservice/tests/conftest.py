"""Shared fixtures: a throwaway RSA key and a Firebase-shaped token minted from it.

Tests verify real tokens through real PyJWT rather than stubbing the decode. The
only seam is `app.auth.signing_key_for` — the network fetch of Google's public
keys — so signature, audience, issuer and expiry are all genuinely exercised.
"""
import time

import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa

PROJECT_ID = "test-project"
ISSUER = f"https://securetoken.google.com/{PROJECT_ID}"
UID = "u1"


@pytest.fixture(scope="session")
def signing_key():
    # 2048 is the smallest size Google uses and the slowest part of this suite;
    # generated once per session rather than per test.
    return rsa.generate_private_key(public_exponent=65537, key_size=2048)


@pytest.fixture
def configured(monkeypatch, signing_key):
    """Points the verifier at the test project and the test key."""
    monkeypatch.setattr("app.config.FIREBASE_PROJECT_ID", PROJECT_ID)
    monkeypatch.setattr(
        "app.auth.signing_key_for", lambda token: signing_key.public_key()
    )


@pytest.fixture
def mint(signing_key, configured):
    """Mints a token that passes by default; kwargs override any claim."""

    def _mint(**overrides):
        now = int(time.time())
        claims = {
            "sub": UID,
            "aud": PROJECT_ID,
            "iss": ISSUER,
            "iat": now,
            "exp": now + 3600,
        }
        claims.update(overrides)
        # Claims set to None are removed, so a test can mint a token *missing* a
        # claim rather than one holding a wrong value.
        claims = {k: v for k, v in claims.items() if v is not None}
        return jwt.encode(claims, signing_key, algorithm="RS256")

    return _mint


@pytest.fixture
def auth_headers(mint):
    return {"Authorization": f"Bearer {mint()}", "X-User-Id": UID}
