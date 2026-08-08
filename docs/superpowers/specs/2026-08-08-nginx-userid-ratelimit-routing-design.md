# Design: nginx per-user rate limiting + multi-provider routing microservice

**Date:** 2026-08-08
**Status:** Approved (pending spec review)

## Problem

The food-analysis microservice currently rate-limits **per IP address** inside FastAPI
using `slowapi` (`get_remote_address`, 2/min per endpoint). We want to:

1. Move rate limiting **out of the app** and into **nginx**, keyed **per user**
   (Firebase UID) instead of per IP.
2. Have the Flutter app send **its own provider API key** with each request.
3. Route each request to the chosen model provider (Gemini, OpenRouter, or NVIDIA NIM)
   and return a **standardized JSON** describing the food name and its nutrients.
4. Containerize the whole thing with **Docker + docker-compose**, with nginx as the
   only publicly reachable entry point.

Image capture, resizing, and compression are handled **entirely on the app side**.
The microservice does **no** image processing — it receives already-compressed bytes
and forwards them to the provider.

## Decisions (locked)

| Decision | Choice |
|---|---|
| Rate-limit key | Firebase UID, sent as `X-User-Id` header |
| Rate-limit value | ~10 requests/minute per user, small burst |
| Endpoint shape | Three sibling endpoints: `/api/v1/gemini`, `/api/v1/openrouter`, `/api/v1/nvidia` |
| Provider selection | App picks the URL (no provider header) |
| OpenRouter model | Fixed, router-chosen multimodal model |
| NVIDIA model | Fixed: `nvidia/nemotron-3-nano-omni-30b-a3b-reasoning`, non-streaming |
| Image processing | App-side only; microservice never resizes/compresses |
| Response shape | `{ name, nutrients: { calories, protein_g, carbs_g, fats_g } }` |
| Infra | nginx reverse proxy + FastAPI, two containers, private compose network |

## Architecture

```
Flutter app
   │  POST /api/v1/{gemini|openrouter|nvidia}
   │  headers: X-User-Id: <firebase uid>
   │           X-Gemini-Key | X-OpenRouter-Key | X-Nvidia-Key
   │  body: image (multipart/form-data, already compressed by the app)
   ▼
nginx   (only published port, host :8080 → container :80)
   │  • limit_req keyed on $http_x_user_id  (~10 req/min per user, burst=5 nodelay)
   │  • rejects requests with no X-User-Id → 400
   │  • over-limit → 429 with JSON body
   │  proxy_pass →
   ▼
FastAPI  (internal port 8000, NOT published — reachable only via nginx)
   │  • no slowapi / no limiter — pure routing + provider calls
   │  • no image processing
   │  • /gemini     → google-generativeai, raw image bytes, user's key
   │  • /openrouter → httpx POST openrouter.ai, base64 data-URI, fixed model, user's key
   │  • /nvidia     → httpx POST integrate.api.nvidia.com, base64 data-URI, fixed model, user's key
   ▼
   { name, nutrients: { calories, protein_g, carbs_g, fats_g } }   (same shape from all three)
```

Both containers share a private compose network. FastAPI's port is **not** published,
so the app cannot bypass nginx to dodge the rate limit.

## Components / files

| File | Change |
|---|---|
| `nginx/nginx.conf` | Fill empty file: `limit_req_zone` on `$http_x_user_id`, upstream to microservice, proxy headers, `limit_req_status 429`, JSON 400 for missing user id, JSON 429 body. |
| `docker-compose.yml` | Fill empty file: `nginx` service (`nginx:alpine`, mounts conf, publishes `8080:80`) + `microservice` service (builds existing Dockerfile, `env_file: .env`, internal-only). |
| `microservice/app.py` | Remove slowapi/limiter; keep 3 endpoints; add real OpenRouter + NVIDIA calls via `httpx`; shared prompt + shared response normalizer. No image processing. |
| `microservice/requirements.txt` | Drop `slowapi` and `limits`; ensure `httpx` present (already is). |
| `microservice/Dockerfile` | Unchanged (already correct). |
| `microservice/.env` | **Do not touch, do not commit.** Local dev testing only; already gitignored. Compose references it via `env_file` for local runs only. |

## Request / response contract

**Required on every request:** `X-User-Id` (Firebase UID).

**Provider key header (per endpoint):**
- `/api/v1/gemini` → `X-Gemini-Key`
- `/api/v1/openrouter` → `X-OpenRouter-Key`
- `/api/v1/nvidia` → `X-Nvidia-Key`

For dev, each endpoint may fall back to the matching key in `.env` if the header is
absent (mirrors current Gemini behavior). Production app always sends its own key.

**Body:** `image` — `multipart/form-data`, already compressed by the app.

**Standardized response (all three endpoints):**
```json
{
  "name": "Grilled chicken salad",
  "nutrients": { "calories": 420, "protein_g": 38, "carbs_g": 12, "fats_g": 24 }
}
```
This restructures the current flat Gemini output (`food_name`, `calories`, …) into
`name` + a `nutrients` object. A shared normalizer maps each provider's raw JSON into
this shape.

## Rate limiting behavior (nginx)

- `limit_req_zone $http_x_user_id zone=peruser:10m rate=10r/m;`
- `limit_req zone=peruser burst=5 nodelay;` → ~10/min with a small burst instead of a
  hard 1-every-6-seconds.
- Missing `X-User-Id` → **400** (prevents all keyless requests collapsing into one
  shared empty-key bucket).
- Over limit → **429** with `{"error":"rate limit exceeded"}`.
- Applies uniformly to all three provider paths (shared zone).
- **Out of scope:** per-day quota — nginx `limit_req` is per-second/minute only. Future
  add-on via OpenResty/Lua + Redis if a hard daily cap is needed. The design does not
  need to change shape to add it later.

## Provider call details

**Gemini** (`google-generativeai`): configure with user key, model
`gemini-3.1-flash-lite-preview`, send raw image bytes + shared prompt, parse JSON
(stripping ` ```json ` fences), normalize.

**OpenRouter** (`httpx`): POST `https://openrouter.ai/api/v1/chat/completions`,
`Authorization: Bearer <user key>`, fixed multimodal model, OpenAI-style `content`
array (prompt text + `image_url` base64 data-URI), `response_format` JSON if supported,
parse + normalize.

**NVIDIA NIM** (`httpx`): POST `https://integrate.api.nvidia.com/v1/chat/completions`,
`Authorization: Bearer <user key>`, model
`nvidia/nemotron-3-nano-omni-30b-a3b-reasoning`, non-streaming,
`max_tokens: 65536`, `reasoning_budget: 16384`, `temperature: 0.6`, `top_p: 0.95`.
The user's snippet sends `content: ""` (text only); since this is food-image analysis
and the model is multimodal (omni), we send the image via the OpenAI-compatible
multimodal `content` array (prompt + `image_url` data-URI). **Open item:** verify
NVIDIA's expected multimodal format during implementation and adjust if their VLM
expects an inline variant.

## Error handling (FastAPI)

- Missing provider key (and no dev fallback) → **401**.
- Provider request fails / times out → **502** with a short message.
- Model returns non-JSON / unparseable text → **502** "invalid response from model"
  (not a raw 500).

## Security note

`X-User-Id` is an **unauthenticated** header. A determined caller could forge UIDs to
mint fresh rate-limit buckets. This limit is **abuse-dampening, not hard security** —
acceptable given there is no auth layer yet. If stronger guarantees are needed later,
introduce a signed token (e.g. Firebase ID token verified at nginx/Lua or FastAPI) and
key the limit on a verified claim.

## Testing / verification

With `docker compose up`:
1. `GET /health` through nginx → **200**.
2. Request with no `X-User-Id` → **400**.
3. >15 rapid requests with a fixed `X-User-Id` → some **429s**.
4. Request with a bogus provider key → **401** (proves routing reaches FastAPI).
5. Full **200** end-to-end per provider is a manual check with real keys (Gemini,
   OpenRouter, NVIDIA), since live provider calls are required.

## Out of scope

- Image resizing/compression (app-side).
- Per-day quotas (future Redis/Lua).
- Auth / token verification (future).
- Flutter client changes (the app does not yet call this service).
