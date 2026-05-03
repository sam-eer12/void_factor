from fastapi import FastAPI, Header, UploadFile, File, HTTPException, Request
from slowapi import Limiter, _rate_limit_exceeded_handler
from slowapi.util import get_remote_address
from slowapi.errors import RateLimitExceeded
import google as genai
import json
import uvicorn
from dotenv import load_dotenv
import os
load_dotenv()

app = FastAPI()

DEV_KEY1= os.getenv('x_gemini_key')
DEV_KEY2 = os.getenv('x_openrouter_key')

limiter = Limiter(key_func=get_remote_address)
app.state.limiter = limiter
app.add_exception_handler(RateLimitExceeded, _rate_limit_exceeded_handler)

@app.post("/api/v1/gemini")
@limiter.limit("2/minute")
async def analyze_with_gemini(
    request: Request,
    image: UploadFile = File(...),
    x_gemini_key: str = Header(None)
):
    api_key = x_gemini_key or DEV_KEY1
    
    if not api_key:
        raise HTTPException(status_code=401, detail="Gemini API Key missing")

    genai.configure(api_key=api_key)
    model = genai.GenerativeModel('gemini-1.5-flash')
    
    image_data = await image.read()
    prompt = "Analyze food image. Return JSON: {food_name, calories, protein_g, carbs_g, fats_g}"
    
    response = model.generate_content([prompt, {"mime_type": "image/jpeg", "data": image_data}])
    return json.loads(response.text.replace("```json", "").replace("```", "").strip())

@app.post("/api/v1/openrouter")
@limiter.limit("2/minute")
async def analyze_with_openrouter(
    request: Request,
    image: UploadFile = File(...),
    x_openrouter_key: str = Header(None)
):
    
    if not x_openrouter_key:
        raise HTTPException(status_code=401, detail="OpenRouter API Key missing")
    
    return {"status": "success", "provider": "openrouter"}

@app.get("/")
async def root():
    return {"message": "Welcome to the Void Factor Microservice"}

@app.get("/health")
async def health_check():
    return {"status": "healthy"}

if __name__ == "__main__":
    uvicorn.run(
        "app:app", 
        host="0.0.0.0", 
        port=8000, 
        reload=True
    )