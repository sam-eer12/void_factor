# Addendum: nginx setup on Podman (completing the 2026-08-08 plan)

**Date:** 2026-08-10
**Status:** Approved
**Parent spec:** [2026-08-08-nginx-userid-ratelimit-routing-design.md](./2026-08-08-nginx-userid-ratelimit-routing-design.md)
**Parent plan:** [../plans/2026-08-08-nginx-userid-ratelimit-routing.md](../plans/2026-08-08-nginx-userid-ratelimit-routing.md)

## Why this addendum

Tasks 1–3 of the parent plan are **done and committed**: the FastAPI microservice is
split into modules (`app/main.py`, `routes.py`, `config.py`, `parsing.py`,
`providers/{gemini,openrouter,nvidia,openai_compatible}.py`), slowapi is removed, and
all three endpoints return the standardized `{name, nutrients}` shape with passing tests.

What remains is **Task 4 (`nginx/nginx.conf`)** and **Task 5 (`docker-compose.yml`
+ end-to-end verification)** — both files are still empty — plus a **Dockerfile
hardening fix** (`.dockerignore`) discovered during this session.

The parent plan assumed a **Docker daemon** (`docker run`, `docker compose up`). This
machine has **no Docker daemon**; it runs **Podman 6.0.2** (machine
`podman-machine-default`, libkrun/krunkit) plus a Podman-wired **`docker compose`
v5.4.0** (`/usr/local/bin/docker-compose`). The config-file *contents* are unchanged
from the parent plan; only the **build/verify commands** change.

## Locked decisions (unchanged from parent)

| Decision | Choice |
|---|---|
| Rate-limit key | Firebase UID via `X-User-Id` header |
| Rate-limit value | `rate=10r/m`, `burst=5 nodelay` |
| Missing `X-User-Id` on `/api/` | `400` JSON |
| Over limit | `429` JSON |
| Published entry point | nginx only, host `8080` → container `80` |
| FastAPI port | `expose 8000`, **not** published |
| `.env` | untouched, `env_file` `required: false`, and now also excluded from the image |

## New / changed for this addendum

### A. Dockerfile hardening — add `microservice/.dockerignore`

The Dockerfile does `COPY . .` with no `.dockerignore`, so a build would copy the
348 MB macOS `.venv`, the `.env` secret (baking the Gemini key into an image layer),
and `__pycache__`/`.pytest_cache`/`.DS_Store` into the image. The Dockerfile
*instructions* are otherwise correct (`CMD ["uvicorn", "app.main:app", …]` matches the
module layout; `EXPOSE 8000`), so **no Dockerfile edit** — only a new `.dockerignore`:

```
.venv/
.env
__pycache__/
*.pyc
.pytest_cache/
.DS_Store
tests/
Dockerfile
.dockerignore
requirements-dev.txt
```

`.env` is excluded from the image on purpose: compose injects it at **runtime** via
`env_file`, so it must never be baked into a layer. Result: smaller image, no secret
leak, faster builds.

### B. Toolchain: Docker → Podman

| Item | Docker (parent plan) | Podman (this machine) |
|---|---|---|
| Engine | Docker daemon | Podman 6.0.2 (`/opt/podman/bin/podman`) |
| Orchestration | `docker compose` | `docker compose` (Podman-wired) — fall back to `podman compose` if needed |
| nginx `-t` check | `docker run ... nginx:alpine nginx -t` | `podman run --rm -v .../nginx.conf:/etc/nginx/nginx.conf:ro nginx:alpine nginx -t` |
| Bring-up | `docker compose up -d --build` | same command, resolved against Podman |

### C. Prerequisite: Podman socket must be reachable

At planning time `podman ps` / `podman compose` failed:
`unable to connect to Podman socket: … dial tcp 127.0.0.1:50998: connect: connection
refused`. The machine shows "Currently running" (krunkit process alive), but the CLI's
SSH-forward port is not listening. **Remedy before Task 5 bring-up:**
`podman machine stop && podman machine start` to re-establish the gvproxy port forward,
then confirm with `podman ps`. (Podman Desktop is open; the machine restart is
coordinated with the user first.)

## Compatibility note

The compose `env_file: [{ path:, required: false }]` object form is Compose Spec
v2.24+. `docker compose` v5.4.0 supports it. If `podman compose` resolves to a
different provider that rejects it, downgrade to the string form and rely on the file
existing (it does: `microservice/.env`).

## Verification (through nginx on :8080)

1. `GET /health` → **200**
2. `POST /api/v1/openrouter` with no `X-User-Id` → **400**
3. `POST /api/v1/openrouter` with `X-User-Id` but no key → **401** (proves routing reaches FastAPI)
4. 15 rapid `POST`s with a fixed `X-User-Id` → first ~6 are `401`, remainder `429`
5. Full `200` per provider needs real keys — manual, out of automated scope.

## Out of scope (unchanged)

Image processing (app-side), per-day quotas, auth/token verification, Flutter changes,
and — confirmed this session — **no Claude/Opus provider endpoint** ("only use opus 4.8"
refers to the assistant model, not a new microservice provider).
