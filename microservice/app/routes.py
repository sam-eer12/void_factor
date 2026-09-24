from fastapi import APIRouter, Depends, File, Header, Response, UploadFile

from app.auth import verify_caller
from app.images import read_image
from app.providers.gemini import call_gemini
from app.providers.openrouter import call_openrouter
from app.providers.nvidia import call_nvidia
from app.schemas import ErrorBody, FoodAnalysis

router = APIRouter()

# Every provider route depends on a verified caller. The uid is not used by the
# handlers — nginx keys the rate limit on the uid /internal/verify hands it — so
# the dependency is declared for its side effect of rejecting unauthenticated
# callers. It still runs here although nginx has already checked the token: the
# service does not assume it is only ever reached through the proxy.
authenticated = [Depends(verify_caller)]

# Published in the OpenAPI schema so the failure shapes are part of the contract
# rather than something a client learns by hitting them.
_errors = {
    status: {"model": ErrorBody}
    for status in (400, 401, 413, 415, 502, 503)
}

_provider_route = dict(
    dependencies=authenticated,
    response_model=FoodAnalysis,
    responses=_errors,
)


@router.post("/api/v1/gemini", **_provider_route)
async def analyze_with_gemini(
    image: UploadFile = File(...),
    x_gemini_key: str = Header(None),
):
    image_data, mime_type = await read_image(image)
    return await call_gemini(x_gemini_key, image_data, mime_type)


@router.post("/api/v1/openrouter", **_provider_route)
async def analyze_with_openrouter(
    image: UploadFile = File(...),
    x_openrouter_key: str = Header(None),
):
    image_data, mime_type = await read_image(image)
    return await call_openrouter(x_openrouter_key, image_data, mime_type)


@router.post("/api/v1/nvidia", **_provider_route)
async def analyze_with_nvidia(
    image: UploadFile = File(...),
    x_nvidia_key: str = Header(None),
):
    image_data, mime_type = await read_image(image)
    return await call_nvidia(x_nvidia_key, image_data, mime_type)


@router.get(
    "/internal/verify",
    status_code=204,
    include_in_schema=False,
    responses={401: {"model": ErrorBody}, 503: {"model": ErrorBody}},
)
async def verify_for_proxy(uid: str = Depends(verify_caller)):
    """nginx's auth_request target: 204 plus the verified uid, or 401.

    This is what lets the per-user rate limit key on an identity nginx did not
    have to take the caller's word for. nginx cannot check an RS256 signature
    itself, so it asks here before the request goes anywhere, and counts the
    request against the uid returned in `X-Verified-Uid`. A caller who forges
    `X-User-Id` is turned away before any bucket is touched — theirs or the
    user's whose id they borrowed.

    Never routed to from outside: nginx only exposes /health, / and /api/, and
    reaches this through an `internal` location.
    """
    return Response(status_code=204, headers={"X-Verified-Uid": uid})


@router.get("/")
async def root():
    return {"message": "Welcome to the Void Factor Microservice"}


@router.get("/health")
async def health_check():
    return {"status": "healthy"}
