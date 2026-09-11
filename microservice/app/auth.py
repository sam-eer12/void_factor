"""Firebase ID token verification.

Firebase ID tokens are RS256 JWTs signed by Google. Verifying one needs only
Google's public keys and the project id — both public — so this deliberately
does not use `firebase-admin`, which would require a service-account JSON on the
server: a real credential to provision, rotate and leak, for no security gain.

What this buys and what it does not: a forged `X-User-Id` can no longer reach a
provider. It can still mint a fresh nginx rate-limit bucket, because nginx keys
on that header before FastAPI ever sees the request. Authorization is enforced;
the bucket is not. See the design doc for why that residue is accepted.
"""
from fastapi import Header, HTTPException
import jwt
from jwt import PyJWKClient

from app import config

# Google publishes the securetoken signing keys in JWKS form here. The x509
# variant carries the same keys as PEM certificates; JWKS is used because
# PyJWKClient consumes it directly, including the kid lookup.
JWKS_URL = (
    "https://www.googleapis.com/service_accounts/v1/jwk/"
    "securetoken@system.gserviceaccount.com"
)

_client: PyJWKClient | None = None


def signing_key_for(token: str):
    """The public key Google signed [token] with.

    The single seam in this module: tests replace this and let everything else —
    signature, audience, issuer, expiry — run for real.

    `PyJWKClient` caches the key set in memory and refetches when a `kid` misses,
    which is what makes Google's key rotation a non-event rather than an outage.
    """
    global _client
    if _client is None:
        _client = PyJWKClient(JWKS_URL, cache_keys=True)
    return _client.get_signing_key_from_jwt(token).key


def verify_id_token(token: str) -> str:
    """Returns the verified uid, or raises 401.

    Every rejection is one status with no detail about which check failed:
    telling a caller that the signature was fine but the audience was wrong
    helps nobody who is allowed to be here.
    """
    project_id = config.FIREBASE_PROJECT_ID
    if not project_id:
        raise HTTPException(status_code=503, detail="auth not configured")

    try:
        claims = jwt.decode(
            token,
            signing_key_for(token),
            algorithms=["RS256"],
            audience=project_id,
            issuer=f"https://securetoken.google.com/{project_id}",
        )
    except jwt.PyJWTError:
        raise HTTPException(status_code=401, detail="invalid token")
    # A malformed token can fail inside the key lookup rather than the decode.
    except ValueError:
        raise HTTPException(status_code=401, detail="invalid token")

    uid = claims.get("sub")
    if not isinstance(uid, str) or not uid.strip():
        raise HTTPException(status_code=401, detail="invalid token")
    return uid


async def verify_caller(
    authorization: str | None = Header(None),
    x_user_id: str | None = Header(None),
) -> str:
    """FastAPI dependency guarding every `/api/` route. Returns the caller's uid.

    Both headers are required. `X-User-Id` is nginx's rate-limit key and is
    always set in production; requiring it here means a caller who reaches the
    service directly gets no further than one arriving through the proxy.
    """
    if not config.FIREBASE_PROJECT_ID:
        # Checked before the headers so a misconfigured deploy reports itself as
        # misconfigured (503) rather than as rejecting everyone (401).
        raise HTTPException(status_code=503, detail="auth not configured")

    if not authorization:
        raise HTTPException(status_code=401, detail="missing bearer token")
    scheme, _, token = authorization.partition(" ")
    if scheme.lower() != "bearer" or not token.strip():
        raise HTTPException(status_code=401, detail="missing bearer token")

    uid = verify_id_token(token.strip())

    if not x_user_id or x_user_id != uid:
        raise HTTPException(status_code=401, detail="user id mismatch")
    return uid
