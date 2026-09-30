"""Signed capabilities for an immutable, locally hosted Gemma artifact.

The capability is reusable: every HEAD, retry and range request goes through
nginx's signature check and the same user's download limits. Expiry is checked
when a request starts, so an already streaming response can finish afterwards.
"""
import hashlib
import hmac
import json
import time
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import parse_qsl, urlencode, urlsplit

from fastapi import APIRouter, Depends, Header, HTTPException, Response
from pydantic import BaseModel, ConfigDict, Field, ValidationError

from app import config
from app.auth import verify_caller

router = APIRouter()
LINK_TTL_SECONDS = 24 * 60 * 60
DEFAULT_MANIFEST = Path(__file__).resolve().parents[2] / "assets/models/gemma3_1b_q4.json"


class ModelArtifact(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)
    version: str = Field(pattern=r"^[a-z0-9][a-z0-9-]{0,127}$")
    filename: str = Field(pattern=r"^[A-Za-z0-9_.-]+\.litertlm$")
    source_repository: str = Field(min_length=1, max_length=256)
    source_revision: str = Field(pattern=r"^[a-f0-9]{40}$")
    size_bytes: int = Field(gt=0)
    sha256: str = Field(pattern=r"^[a-f0-9]{64}$")
    terms_version: str = Field(pattern=r"^\d{4}-\d{2}-\d{2}$")

    @property
    def download_path(self) -> str:
        return f"/models/{self.sha256}/{self.filename}"


class LinkRequest(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)
    accepted_terms_version: str = Field(min_length=1, max_length=64)


def load_artifact() -> ModelArtifact:
    try:
        path = Path(config.MODEL_MANIFEST_PATH) if config.MODEL_MANIFEST_PATH else DEFAULT_MANIFEST
        return ModelArtifact.model_validate_json(path.read_bytes())
    except (OSError, ValidationError, ValueError):
        # Configuration paths and bad metadata never appear in a client error.
        raise HTTPException(503, "model: unavailable") from None


def signing_configuration() -> tuple[bytes, str]:
    secret = config.MODEL_SIGNING_SECRET or ""
    origin = config.MODEL_PUBLIC_ORIGIN or ""
    try:
        parsed = urlsplit(origin)
        local_http = parsed.scheme == "http" and parsed.hostname in {"localhost", "127.0.0.1", "::1", "10.0.2.2"}
        valid = (parsed.scheme == "https" or local_http) and parsed.hostname and parsed.port != 0
        valid = valid and not (parsed.username or parsed.password or parsed.query or parsed.fragment)
        valid = valid and parsed.path in {"", "/"}
    except ValueError:
        valid = False
    if len(secret.encode()) < 32 or not valid:
        raise HTTPException(503, "model: unavailable")
    return secret.encode(), origin.rstrip("/")


def safe_uid(uid: str) -> bool:
    # Firebase subjects are at most 128 characters. This value also crosses an
    # HTTP response header, so reject control characters and non-ASCII bytes.
    return 1 <= len(uid) <= 128 and all(32 <= ord(c) < 127 for c in uid)


def signature(secret: bytes, version: str, path: str, uid: str, expires: int) -> str:
    payload = json.dumps([version, path, uid, expires], separators=(",", ":"), ensure_ascii=True)
    return hmac.new(secret, payload.encode(), hashlib.sha256).hexdigest()


@router.post("/api/v1/models/gemma/download-link")
async def download_link(body: LinkRequest, response: Response, uid: str = Depends(verify_caller)):
    secret, origin = signing_configuration()
    artifact = load_artifact()
    if not safe_uid(uid):
        raise HTTPException(401, "auth: invalid token")
    if body.accepted_terms_version != artifact.terms_version:
        raise HTTPException(409, "model: accept the current terms")
    expires = int(time.time()) + LINK_TTL_SECONDS
    query = urlencode({
        "version": artifact.version, "uid": uid, "expires": expires,
        "signature": signature(secret, artifact.version, artifact.download_path, uid, expires),
    })
    response.headers["Cache-Control"] = "no-store"
    return {
        "url": f"{origin}{artifact.download_path}?{query}",
        "expires_at": datetime.fromtimestamp(expires, timezone.utc).isoformat(),
        "model": artifact.model_dump(),
    }


def verify_download(original_uri: str, original_method: str, *, now: int | None = None) -> str:
    secret, _ = signing_configuration()
    artifact = load_artifact()
    try:
        parsed = urlsplit(original_uri)
        pairs = parse_qsl(parsed.query, strict_parsing=True, max_num_fields=4)
        values = dict(pairs)
        if (original_method not in {"GET", "HEAD"} or parsed.scheme or parsed.netloc
                or parsed.fragment or parsed.path != artifact.download_path
                or len(pairs) != 4 or set(values) != {"version", "uid", "expires", "signature"}):
            raise ValueError
        uid = values["uid"]
        expiry_text = values["expires"]
        if not safe_uid(uid) or not expiry_text.isascii() or not expiry_text.isdecimal() or len(expiry_text) > 12:
            raise ValueError
        expires = int(expiry_text)
        if (int(time.time()) if now is None else now) >= expires or values["version"] != artifact.version:
            raise ValueError
        expected = signature(secret, artifact.version, parsed.path, uid, expires)
        if not hmac.compare_digest(expected, values["signature"]):
            raise ValueError
        return uid
    except (ValueError, TypeError):
        raise HTTPException(403, "model: invalid or expired link") from None


@router.get("/internal/models/verify", status_code=204)
async def verify_model(
    x_original_uri: str = Header(""), x_original_method: str = Header(""),
):
    uid = verify_download(x_original_uri, x_original_method)
    return Response(status_code=204, headers={"X-Verified-Uid": uid, "Cache-Control": "no-store"})
