from fastapi import APIRouter, Depends, File, Header, UploadFile

from app.auth import verify_caller
from app.providers.gemini import call_gemini
from app.providers.openrouter import call_openrouter
from app.providers.nvidia import call_nvidia

router = APIRouter()

# Every provider route depends on a verified caller. The uid is not used by the
# handlers — nginx already keys the rate limit on the header — so the dependency
# is declared for its side effect of rejecting unauthenticated callers.
authenticated = [Depends(verify_caller)]


@router.post("/api/v1/gemini", dependencies=authenticated)
async def analyze_with_gemini(
    image: UploadFile = File(...),
    x_gemini_key: str = Header(None),
):
    image_data = await image.read()
    return await call_gemini(x_gemini_key, image_data)


@router.post("/api/v1/openrouter", dependencies=authenticated)
async def analyze_with_openrouter(
    image: UploadFile = File(...),
    x_openrouter_key: str = Header(None),
):
    image_data = await image.read()
    return await call_openrouter(x_openrouter_key, image_data)


@router.post("/api/v1/nvidia", dependencies=authenticated)
async def analyze_with_nvidia(
    image: UploadFile = File(...),
    x_nvidia_key: str = Header(None),
):
    image_data = await image.read()
    return await call_nvidia(x_nvidia_key, image_data)


@router.get("/")
async def root():
    return {"message": "Welcome to the Void Factor Microservice"}


@router.get("/health")
async def health_check():
    return {"status": "healthy"}
