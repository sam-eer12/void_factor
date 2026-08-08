# nginx per-user rate limiting + multi-provider routing — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move rate limiting out of FastAPI (per-IP) into nginx (per Firebase UID), have the app send its own provider key, route to Gemini / OpenRouter / NVIDIA NIM, and return a standardized `{name, nutrients}` JSON — all containerized via docker-compose with nginx as the only published entry point.

**Architecture:** nginx reverse-proxies to a slim FastAPI service on a private compose network. nginx enforces `limit_req` keyed on the `X-User-Id` header (~10/min per user, burst 5). FastAPI drops `slowapi`, does no image processing, and exposes three sibling endpoints that call each provider with the caller's key and normalize every provider's raw JSON into one response shape.

**Tech Stack:** Python 3.11, FastAPI, `google-generativeai`, `httpx` (async, for OpenRouter + NVIDIA), nginx (`nginx:alpine`), Docker + docker-compose. Tests: `pytest`, `respx` (httpx mocking), FastAPI `TestClient`, `monkeypatch`.

## Global Constraints

- The microservice does **no image processing** — it reads the uploaded bytes and forwards them (raw to Gemini, base64 data-URI to OpenRouter/NVIDIA). App handles capture/resize/compression.
- **Never modify or commit `microservice/.env`.** It is gitignored, local-testing only. Compose references it via `env_file` with `required: false`.
- Every endpoint returns exactly: `{"name": <str>, "nutrients": {"calories", "protein_g", "carbs_g", "fats_g"}}`.
- Provider key headers: `X-Gemini-Key`, `X-OpenRouter-Key`, `X-Nvidia-Key`. Each may fall back to a matching env var for dev; production app always sends its own.
- NVIDIA model is fixed: `nvidia/nemotron-3-nano-omni-30b-a3b-reasoning`, non-streaming, `max_tokens: 65536`, `reasoning_budget: 16384`, `temperature: 0.6`, `top_p: 0.95`.
- nginx keys the limit on `$http_x_user_id`; requests to `/api/` with an empty `X-User-Id` are rejected with `400`; over-limit returns `429`; both with JSON bodies.
- Run all Python/pytest commands from the `microservice/` directory so `import app` resolves.

## File Structure

| File | Responsibility |
|---|---|
| `microservice/app.py` | FastAPI app: 3 endpoints + shared prompt, JSON parser, response normalizer, OpenAI-compatible caller. No limiter, no image processing. |
| `microservice/requirements.txt` | Production deps. Remove `slowapi`, `limits`. |
| `microservice/requirements-dev.txt` | **Create.** Test-only deps: `pytest`, `respx`. |
| `microservice/tests/test_app.py` | **Create.** Endpoint tests (TestClient + respx + monkeypatch). |
| `nginx/nginx.conf` | **Fill (currently empty).** Per-user `limit_req`, upstream, proxy headers, 400/429 JSON. |
| `docker-compose.yml` | **Fill (currently empty).** `microservice` (build, internal only, healthcheck) + `nginx` (published `8080:80`, mounts conf) on a private network. |
| `microservice/Dockerfile` | Unchanged. |

---

### Task 1: Slim FastAPI + Gemini endpoint on the new contract

Remove `slowapi`, add shared helpers (`PROMPT`, `_parse_model_json`, `_normalize`), refactor the Gemini endpoint to return `{name, nutrients}`, and stand up the test harness.

**Files:**
- Modify: `microservice/app.py`
- Modify: `microservice/requirements.txt` (remove `slowapi`, `limits`)
- Create: `microservice/requirements-dev.txt`
- Create: `microservice/tests/test_app.py`

**Interfaces:**
- Produces: `PROMPT: str`; `_strip_json_fences(text: str) -> str`; `_parse_model_json(raw_text: str) -> dict` (raises `HTTPException(502)` on bad JSON); `_normalize(data: dict) -> dict` (returns `{"name", "nutrients": {...}}`, accepts flat or nested input); FastAPI `app`; endpoint `POST /api/v1/gemini`.

- [ ] **Step 1: Add dev requirements file**

Create `microservice/requirements-dev.txt`:
```text
pytest==8.3.4
respx==0.22.0
```

- [ ] **Step 2: Install test deps**

Run (from `microservice/`, venv active):
```bash
pip install -r requirements-dev.txt
```
Expected: `pytest` and `respx` install successfully.

- [ ] **Step 3: Write the failing Gemini test**

Create `microservice/tests/test_app.py`:
```python
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
```

- [ ] **Step 4: Run the tests to verify they fail**

Run (from `microservice/`):
```bash
python -m pytest tests/test_app.py -v
```
Expected: FAIL — current `app.py` still imports `slowapi` (and returns the flat `food_name` shape). Import error or assertion failures are both acceptable "red" states.

- [ ] **Step 5: Rewrite `app.py` (remove slowapi, add helpers + Gemini)**

Replace the entire contents of `microservice/app.py` with:
```python
from fastapi import FastAPI, Header, UploadFile, File, HTTPException
import google.generativeai as genai
import json
import os
from dotenv import load_dotenv

load_dotenv()

app = FastAPI()

DEV_GEMINI_KEY = os.getenv("x_gemini_key")
DEV_OPENROUTER_KEY = os.getenv("x_openrouter_key")
DEV_NVIDIA_KEY = os.getenv("NVIDIA_API_KEY")

GEMINI_MODEL = "gemini-3.1-flash-lite-preview"

PROMPT = (
    "Analyze the food in this image. Respond with ONLY a JSON object, no markdown, "
    "in exactly this shape: "
    '{"name": <food name string>, "nutrients": {"calories": <number>, '
    '"protein_g": <number>, "carbs_g": <number>, "fats_g": <number>}}'
)


def _strip_json_fences(text: str) -> str:
    return text.replace("```json", "").replace("```", "").strip()


def _parse_model_json(raw_text: str) -> dict:
    try:
        return json.loads(_strip_json_fences(raw_text))
    except (json.JSONDecodeError, TypeError, AttributeError):
        raise HTTPException(status_code=502, detail="invalid response from model")


def _normalize(data: dict) -> dict:
    """Coerce a provider's parsed JSON into {name, nutrients:{...}}.

    Accepts either the nested target shape or a flat {food_name, calories, ...}.
    """
    nutrients = data.get("nutrients")
    if not isinstance(nutrients, dict):
        nutrients = data
    return {
        "name": data.get("name") or data.get("food_name") or "",
        "nutrients": {
            "calories": nutrients.get("calories"),
            "protein_g": nutrients.get("protein_g"),
            "carbs_g": nutrients.get("carbs_g"),
            "fats_g": nutrients.get("fats_g"),
        },
    }


@app.post("/api/v1/gemini")
async def analyze_with_gemini(
    image: UploadFile = File(...),
    x_gemini_key: str = Header(None),
):
    api_key = x_gemini_key or DEV_GEMINI_KEY
    if not api_key:
        raise HTTPException(status_code=401, detail="Gemini API Key missing")

    genai.configure(api_key=api_key)
    model = genai.GenerativeModel(GEMINI_MODEL)
    image_data = await image.read()
    try:
        response = model.generate_content(
            [PROMPT, {"mime_type": "image/jpeg", "data": image_data}]
        )
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"provider request failed: {e}")
    return _normalize(_parse_model_json(response.text))


@app.get("/")
async def root():
    return {"message": "Welcome to the Void Factor Microservice"}


@app.get("/health")
async def health_check():
    return {"status": "healthy"}


if __name__ == "__main__":
    import uvicorn

    uvicorn.run("app:app", host="0.0.0.0", port=8000, reload=True)
```

- [ ] **Step 6: Remove slowapi/limits from requirements**

Edit `microservice/requirements.txt`: delete the lines `slowapi==0.1.9` and `limits==5.8.0`.

- [ ] **Step 7: Run the tests to verify they pass**

Run (from `microservice/`):
```bash
python -m pytest tests/test_app.py -v
```
Expected: 3 passed.

- [ ] **Step 8: Commit**

```bash
git add microservice/app.py microservice/requirements.txt \
        microservice/requirements-dev.txt microservice/tests/test_app.py
git commit -m "refactor(microservice): drop slowapi, standardize Gemini response to {name,nutrients}"
```

---

### Task 2: OpenRouter endpoint (real call via httpx)

Add the OpenAI-compatible vision caller and the `/api/v1/openrouter` endpoint.

**Files:**
- Modify: `microservice/app.py`
- Modify: `microservice/tests/test_app.py`

**Interfaces:**
- Consumes: `PROMPT`, `_parse_model_json`, `_normalize` (Task 1).
- Produces: `_build_vision_messages(image_bytes: bytes) -> list`; `async _call_openai_compatible(url: str, api_key: str, model: str, image_bytes: bytes, extra_payload: dict | None = None) -> dict`; `OPENROUTER_MODEL: str`; endpoint `POST /api/v1/openrouter`.

- [ ] **Step 1: Write the failing OpenRouter tests**

Append to `microservice/tests/test_app.py`:
```python
import respx
from httpx import Response

OPENROUTER_URL = "https://openrouter.ai/api/v1/chat/completions"


def _chat_completion(content):
    return {"choices": [{"message": {"content": content}}]}


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
    monkeypatch.setattr("app.DEV_OPENROUTER_KEY", None)
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
```

- [ ] **Step 2: Run the new tests to verify they fail**

Run (from `microservice/`):
```bash
python -m pytest tests/test_app.py -k openrouter -v
```
Expected: FAIL — no `/api/v1/openrouter` route yet (404), so assertions fail.

- [ ] **Step 3: Add the httpx import and OpenRouter code to `app.py`**

At the top of `microservice/app.py`, add `import httpx` and `import base64` next to the existing imports.

Add the model constant next to `GEMINI_MODEL`:
```python
OPENROUTER_MODEL = os.getenv("OPENROUTER_MODEL", "google/gemini-2.0-flash-001")
```

Add these helpers after `_normalize`:
```python
def _build_vision_messages(image_bytes: bytes) -> list:
    b64 = base64.b64encode(image_bytes).decode("utf-8")
    data_uri = f"data:image/jpeg;base64,{b64}"
    return [
        {
            "role": "user",
            "content": [
                {"type": "text", "text": PROMPT},
                {"type": "image_url", "image_url": {"url": data_uri}},
            ],
        }
    ]


async def _call_openai_compatible(
    url: str,
    api_key: str,
    model: str,
    image_bytes: bytes,
    extra_payload: dict | None = None,
) -> dict:
    payload = {"model": model, "messages": _build_vision_messages(image_bytes)}
    if extra_payload:
        payload.update(extra_payload)
    headers = {"Authorization": f"Bearer {api_key}"}
    try:
        async with httpx.AsyncClient(timeout=60) as http_client:
            resp = await http_client.post(url, headers=headers, json=payload)
    except httpx.HTTPError as e:
        raise HTTPException(status_code=502, detail=f"provider request failed: {e}")
    if resp.status_code != 200:
        raise HTTPException(
            status_code=502, detail=f"provider error: {resp.status_code}"
        )
    body = resp.json()
    try:
        content = body["choices"][0]["message"]["content"]
    except (KeyError, IndexError, TypeError):
        raise HTTPException(status_code=502, detail="invalid response from model")
    return _normalize(_parse_model_json(content))
```

Add the endpoint (place it after the Gemini endpoint):
```python
@app.post("/api/v1/openrouter")
async def analyze_with_openrouter(
    image: UploadFile = File(...),
    x_openrouter_key: str = Header(None),
):
    api_key = x_openrouter_key or DEV_OPENROUTER_KEY
    if not api_key:
        raise HTTPException(status_code=401, detail="OpenRouter API Key missing")
    image_data = await image.read()
    return await _call_openai_compatible(
        "https://openrouter.ai/api/v1/chat/completions",
        api_key,
        OPENROUTER_MODEL,
        image_data,
    )
```

- [ ] **Step 4: Run the tests to verify they pass**

Run (from `microservice/`):
```bash
python -m pytest tests/test_app.py -v
```
Expected: all pass (Task 1 tests + 3 OpenRouter tests).

- [ ] **Step 5: Commit**

```bash
git add microservice/app.py microservice/tests/test_app.py
git commit -m "feat(microservice): implement OpenRouter endpoint with shared vision caller"
```

---

### Task 3: NVIDIA NIM endpoint

Reuse the OpenAI-compatible caller for NVIDIA with its fixed model and extra params.

**Files:**
- Modify: `microservice/app.py`
- Modify: `microservice/tests/test_app.py`

**Interfaces:**
- Consumes: `_call_openai_compatible`, `_build_vision_messages` (Task 2), `_normalize` (Task 1).
- Produces: `NVIDIA_MODEL: str`; endpoint `POST /api/v1/nvidia`.

- [ ] **Step 1: Write the failing NVIDIA tests**

Append to `microservice/tests/test_app.py`:
```python
NVIDIA_URL = "https://integrate.api.nvidia.com/v1/chat/completions"


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
    monkeypatch.setattr("app.DEV_NVIDIA_KEY", None)
    resp = client.post(
        "/api/v1/nvidia",
        headers={"X-User-Id": "u1"},
        files={"image": ("food.jpg", b"x", "image/jpeg")},
    )
    assert resp.status_code == 401
```
(`json` is already imported at the top of the test module via `app`; add `import json` at the top of `test_app.py` if not already present.)

- [ ] **Step 2: Run the new tests to verify they fail**

Run (from `microservice/`):
```bash
python -m pytest tests/test_app.py -k nvidia -v
```
Expected: FAIL — no `/api/v1/nvidia` route yet (404).

- [ ] **Step 3: Add the NVIDIA model constant and endpoint to `app.py`**

Add next to the other model constants:
```python
NVIDIA_MODEL = "nvidia/nemotron-3-nano-omni-30b-a3b-reasoning"
```

Add the endpoint after the OpenRouter endpoint:
```python
@app.post("/api/v1/nvidia")
async def analyze_with_nvidia(
    image: UploadFile = File(...),
    x_nvidia_key: str = Header(None),
):
    api_key = x_nvidia_key or DEV_NVIDIA_KEY
    if not api_key:
        raise HTTPException(status_code=401, detail="NVIDIA API Key missing")
    image_data = await image.read()
    return await _call_openai_compatible(
        "https://integrate.api.nvidia.com/v1/chat/completions",
        api_key,
        NVIDIA_MODEL,
        image_data,
        extra_payload={
            "max_tokens": 65536,
            "reasoning_budget": 16384,
            "temperature": 0.6,
            "top_p": 0.95,
            "stream": False,
        },
    )
```

- [ ] **Step 4: Ensure `import json` at top of test file**

Add `import json` to the top of `microservice/tests/test_app.py` if it is not already there (the NVIDIA test parses the outgoing request body).

- [ ] **Step 5: Run the full test suite to verify it passes**

Run (from `microservice/`):
```bash
python -m pytest tests/test_app.py -v
```
Expected: all pass (Task 1 + 2 + 3 tests).

- [ ] **Step 6: Commit**

```bash
git add microservice/app.py microservice/tests/test_app.py
git commit -m "feat(microservice): add NVIDIA NIM endpoint"
```

---

### Task 4: nginx per-user rate limiting config

Fill the empty `nginx/nginx.conf` with a reverse proxy that rate-limits per `X-User-Id`.

**Files:**
- Modify: `nginx/nginx.conf` (currently empty)

**Interfaces:**
- Consumes: FastAPI service reachable at `microservice:8000` (name set by compose in Task 5), routes `/`, `/health`, `/api/v1/*`.
- Produces: nginx server on port 80 with zone `peruser`; behaviors — `/api/` empty `X-User-Id` → 400 JSON; over-limit → 429 JSON; `/health` and `/` unlimited.

- [ ] **Step 1: Write `nginx/nginx.conf`**

Replace the (empty) contents of `nginx/nginx.conf` with:
```nginx
worker_processes auto;

events {
    worker_connections 1024;
}

http {
    # ~10 requests/minute per user, keyed on the Firebase UID header.
    # nginx does not count requests whose key is empty, so /api/ separately
    # rejects empty X-User-Id below (see the 400 return).
    limit_req_zone $http_x_user_id zone=peruser:10m rate=10r/m;
    limit_req_status 429;

    upstream microservice {
        server microservice:8000;
    }

    server {
        listen 80;
        default_type application/json;

        # Unlimited, no user id required.
        location = /health {
            proxy_pass http://microservice;
        }

        location = / {
            proxy_pass http://microservice;
        }

        # Rate-limited provider endpoints.
        location /api/ {
            if ($http_x_user_id = "") {
                return 400 '{"error":"X-User-Id header required"}';
            }

            limit_req zone=peruser burst=5 nodelay;

            proxy_pass http://microservice;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-User-Id $http_x_user_id;
        }

        # JSON body for rate-limit rejections.
        error_page 429 = @ratelimited;
        location @ratelimited {
            return 429 '{"error":"rate limit exceeded"}';
        }
    }
}
```

- [ ] **Step 2: Validate the config syntax**

Run (from repo root):
```bash
docker run --rm -v "$(pwd)/nginx/nginx.conf:/etc/nginx/nginx.conf:ro" nginx:alpine nginx -t
```
Expected: `syntax is ok` / `test is successful`. (The `microservice` upstream host is only resolved at runtime; `nginx -t` does not require it to resolve.)

- [ ] **Step 3: Commit**

```bash
git add nginx/nginx.conf
git commit -m "feat(nginx): per-user (X-User-Id) rate limiting reverse proxy"
```

---

### Task 5: docker-compose wiring + end-to-end verification

Fill the empty `docker-compose.yml`, bring the stack up, and verify the four observable behaviors.

**Files:**
- Modify: `docker-compose.yml` (currently empty)

**Interfaces:**
- Consumes: `microservice/Dockerfile`, `nginx/nginx.conf` (Task 4), `microservice/.env` (optional).
- Produces: `microservice` service (built, internal port 8000, healthcheck) and `nginx` service (published `8080:80`) on network `internal`.

- [ ] **Step 1: Write `docker-compose.yml`**

Replace the (empty) contents of `docker-compose.yml` with:
```yaml
services:
  microservice:
    build: ./microservice
    env_file:
      - path: ./microservice/.env
        required: false
    expose:
      - "8000"
    networks:
      - internal
    healthcheck:
      test: ["CMD", "python", "-c", "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://localhost:8000/health').status==200 else 1)"]
      interval: 5s
      timeout: 3s
      retries: 5
    restart: unless-stopped

  nginx:
    image: nginx:alpine
    depends_on:
      microservice:
        condition: service_healthy
    ports:
      - "8080:80"
    volumes:
      - ./nginx/nginx.conf:/etc/nginx/nginx.conf:ro
    networks:
      - internal
    restart: unless-stopped

networks:
  internal:
    driver: bridge
```

- [ ] **Step 2: Validate compose config**

Run (from repo root):
```bash
docker compose config
```
Expected: prints the resolved config with no errors.

- [ ] **Step 3: Build and start the stack**

Run (from repo root):
```bash
docker compose up -d --build
```
Expected: both services start; `docker compose ps` shows `microservice` healthy and `nginx` running.

- [ ] **Step 4: Verify health passes through nginx (200)**

Run:
```bash
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8080/health
```
Expected: `200`.

- [ ] **Step 5: Verify missing X-User-Id is rejected (400)**

Run:
```bash
curl -s -o /dev/null -w "%{http_code}\n" -X POST http://localhost:8080/api/v1/openrouter \
  -F "image=@/dev/null;type=image/jpeg;filename=food.jpg"
```
Expected: `400`.

- [ ] **Step 6: Verify routing reaches FastAPI — missing key (401)**

Run (OpenRouter has no dev-key fallback in `.env`, so this proves the request reached FastAPI):
```bash
curl -s -o /dev/null -w "%{http_code}\n" -X POST http://localhost:8080/api/v1/openrouter \
  -H "X-User-Id: verify-user" \
  -F "image=@/dev/null;type=image/jpeg;filename=food.jpg"
```
Expected: `401`.

- [ ] **Step 7: Verify per-user rate limiting (429s appear)**

Run (15 rapid requests with the same user id; nginx counts them before proxying):
```bash
for i in $(seq 1 15); do
  curl -s -o /dev/null -w "%{http_code} " -X POST http://localhost:8080/api/v1/openrouter \
    -H "X-User-Id: burst-user" \
    -F "image=@/dev/null;type=image/jpeg;filename=food.jpg"
done; echo
```
Expected: the first ~6 return `401` (burst allowance, reaching FastAPI), the remainder return `429`.

- [ ] **Step 8: Tear down**

Run:
```bash
docker compose down
```
Expected: containers removed cleanly.

- [ ] **Step 9: Commit**

```bash
git add docker-compose.yml
git commit -m "feat: docker-compose for nginx + microservice with private network"
```

---

## Self-Review

**Spec coverage:**
- nginx per-user (Firebase UID) rate limiting → Task 4 (`limit_req_zone $http_x_user_id`), verified Task 5 Step 7. ✔
- Remove IP-based slowapi → Task 1 (Steps 5–6). ✔
- App sends own key; dev fallback → Tasks 1–3 (`x_* or DEV_*`). ✔
- Three endpoints (gemini/openrouter/nvidia) → Tasks 1/2/3. ✔
- Standardized `{name, nutrients}` → Task 1 `_normalize`, asserted in every endpoint test. ✔
- NVIDIA fixed model + params → Task 3, asserted in `test_nvidia_success`. ✔
- No image processing → confirmed; endpoints only `read()` + base64 for OpenAI-compatible. ✔
- Missing X-User-Id → 400; over-limit → 429 → Task 4, verified Task 5 Steps 5, 7. ✔
- Docker + compose, nginx only published port → Task 5 (`expose` vs `ports`). ✔
- `.env` untouched, `required: false` → Task 5 Step 1. ✔
- Error handling 401/502 → Tasks 1–3, asserted in tests. ✔
- Out of scope (image proc, daily quota, auth, Flutter) → not implemented, as intended. ✔

**Placeholder scan:** No TBD/TODO; all code blocks complete; no "add error handling" hand-waves. ✔

**Type consistency:** `_normalize`, `_parse_model_json`, `_build_vision_messages`, `_call_openai_compatible`, `PROMPT`, `OPENROUTER_MODEL`, `NVIDIA_MODEL`, `DEV_*` names are consistent across tasks and tests. ✔

**Open item (from spec):** NVIDIA multimodal image format. The plan sends the OpenAI-compatible `content` array with an `image_url` data-URI (`_build_vision_messages`). If live NVIDIA testing (real key, out of automated scope) shows the omni model expects a different image encoding, adjust `_build_vision_messages` for the NVIDIA path only — no other task changes.
