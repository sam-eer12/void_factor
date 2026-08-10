# nginx setup on Podman + Dockerfile hardening — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Complete the food-analysis microservice deployment by hardening the Docker build, filling the empty `nginx/nginx.conf` and `docker-compose.yml`, and bringing the two-container stack up on **Podman** with end-to-end verification.

**Architecture:** nginx (`nginx:alpine`) is the only published entry point (host `8080` → container `80`) and reverse-proxies to a FastAPI microservice (`expose 8000`, unpublished) over a private compose network. nginx enforces `limit_req` keyed on the `X-User-Id` (Firebase UID) header (~10/min, burst 5); missing UID → 400, over-limit → 429. FastAPI (already built) routes to Gemini/OpenRouter/NVIDIA and returns `{name, nutrients}`.

**Tech Stack:** nginx (`nginx:alpine`), FastAPI (existing), **Podman 6.0.2** (`/opt/podman/bin/podman`, machine `podman-machine-default`), **`docker compose` v5.4.0** wired to Podman. No Docker daemon on this machine.

## Global Constraints

- **No Docker daemon.** Use `podman` for the engine and `docker compose` (Podman-wired) for orchestration; fall back to `podman compose` if `docker compose` fails to resolve. For one-off container runs use `podman run`.
- **Never modify or commit `microservice/.env`.** It is gitignored, local-testing only. Compose references it via `env_file` with `required: false`. It must also be excluded from the image (`.dockerignore`) so the Gemini key is never baked into a layer.
- nginx keys the limit on `$http_x_user_id`; `/api/` with an empty `X-User-Id` → `400` JSON; over-limit → `429` JSON; both `/health` and `/` unlimited.
- nginx is the **only** published port (`8080:80`). FastAPI uses `expose: 8000` and is **not** published, so the app cannot bypass nginx.
- The microservice does **no image processing** (unchanged — already built).
- **No new provider endpoint.** "Only use opus 4.8" refers to the assistant model, not a microservice provider.
- Run `podman`/compose commands from the **repo root**; run any `pytest` from `microservice/`.

## File Structure

| File | Responsibility |
|---|---|
| `microservice/.dockerignore` | **Create.** Exclude `.venv`, `.env`, caches, tests, Dockerfile from the build context. |
| `nginx/nginx.conf` | **Fill (empty).** Per-user `limit_req`, upstream to `microservice:8000`, proxy headers, 400/429 JSON. |
| `docker-compose.yml` | **Fill (empty).** `microservice` (build, `expose 8000`, healthcheck) + `nginx` (published `8080:80`, mounts conf) on a private network. |
| `microservice/Dockerfile` | **Unchanged** — instructions are correct; only the build context needed hardening (the `.dockerignore`). |

---

### Task 1: Harden the Docker build context (`.dockerignore`)

Prevent the 348 MB macOS `.venv`, the `.env` secret, and caches from entering the image. No Dockerfile edit — the `COPY . .` stays, but the context shrinks.

**Files:**
- Create: `microservice/.dockerignore`

**Interfaces:**
- Produces: a build context that excludes `.venv/`, `.env`, `__pycache__/`, `*.pyc`, `.pytest_cache/`, `.DS_Store`, `tests/`, `Dockerfile`, `.dockerignore`, `requirements-dev.txt`. Consumed by Task 3's `podman build` (via compose).

- [ ] **Step 1: Create `microservice/.dockerignore`**

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

- [ ] **Step 2: Commit**

```bash
git add microservice/.dockerignore
git commit -m "build(microservice): add .dockerignore to keep .venv/.env/caches out of the image"
```

(The build-context effect is verified in Task 3 Step 4, where the image builds without the 348 MB venv.)

---

### Task 2: nginx per-user rate-limiting config + syntax check on Podman

Fill the empty `nginx/nginx.conf`; validate it with a throwaway `nginx:alpine` container via `podman run` (no daemon, no running stack needed).

**Files:**
- Modify: `nginx/nginx.conf` (currently empty)

**Interfaces:**
- Consumes: FastAPI service reachable at `microservice:8000` (name set by compose in Task 3).
- Produces: nginx server on port 80, zone `peruser`; `/api/` empty `X-User-Id` → 400 JSON, over-limit → 429 JSON, `/health` and `/` unlimited.

- [ ] **Step 1: Write `nginx/nginx.conf`**

```nginx
worker_processes auto;

events {
    worker_connections 1024;
}

http {
    # ~10 requests/minute per user, keyed on the Firebase UID header.
    # nginx does not count requests whose key is empty, so /api/ separately
    # rejects empty X-User-Id below (the 400 return).
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

- [ ] **Step 2: Validate the config syntax with Podman**

Run (from repo root):
```bash
podman run --rm -v "$(pwd)/nginx/nginx.conf:/etc/nginx/nginx.conf:ro" nginx:alpine nginx -t
```
Expected: `syntax is ok` / `test is successful`. (This pulls `nginx:alpine` if needed and requires the Podman machine socket to be reachable — see Task 3 Step 1 if it fails with a socket error. The `microservice` upstream host is resolved only at runtime; `nginx -t` does not require it.)

- [ ] **Step 3: Commit**

```bash
git add nginx/nginx.conf
git commit -m "feat(nginx): per-user (X-User-Id) rate limiting reverse proxy"
```

---

### Task 3: docker-compose wiring + Podman bring-up + end-to-end verification

Fill the empty `docker-compose.yml`, ensure the Podman socket is reachable, bring the stack up, and verify the four observable behaviors.

**Files:**
- Modify: `docker-compose.yml` (currently empty)

**Interfaces:**
- Consumes: `microservice/Dockerfile` + `.dockerignore` (Task 1), `nginx/nginx.conf` (Task 2), `microservice/.env` (optional).
- Produces: `microservice` service (built, `expose 8000`, healthcheck) and `nginx` service (published `8080:80`) on network `internal`.

- [ ] **Step 1: Ensure the Podman machine socket is reachable**

Run (from repo root):
```bash
podman ps
```
If it prints a (possibly empty) container table, the socket is up — skip to Step 2.
If it fails with `unable to connect to Podman socket: ... connection refused`, restart the machine to re-establish the gvproxy port forward (**confirm with the user first — Podman Desktop is open**):
```bash
podman machine stop && podman machine start
podman ps
```
Expected after restart: `podman ps` succeeds.

- [ ] **Step 2: Write `docker-compose.yml`**

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

- [ ] **Step 3: Validate compose config**

Run (from repo root):
```bash
docker compose config
```
Expected: prints the resolved config with no errors. If `docker compose` errors on the `env_file` object form, retry with `podman compose config`; if that also rejects it, downgrade the `env_file:` block to the string form `env_file: [./microservice/.env]` (the file exists) and re-run.

- [ ] **Step 4: Build and start the stack**

Run (from repo root):
```bash
docker compose up -d --build
```
Expected: image builds **without** copying the 348 MB venv (Task 1 effect); both services start. Confirm:
```bash
docker compose ps
```
Expected: `microservice` healthy, `nginx` running.

- [ ] **Step 5: Verify health passes through nginx (200)**

Run:
```bash
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8080/health
```
Expected: `200`.

- [ ] **Step 6: Verify missing X-User-Id is rejected (400)**

Run:
```bash
curl -s -o /dev/null -w "%{http_code}\n" -X POST http://localhost:8080/api/v1/openrouter \
  -F "image=@/dev/null;type=image/jpeg;filename=food.jpg"
```
Expected: `400`.

- [ ] **Step 7: Verify routing reaches FastAPI — missing key (401)**

Run (OpenRouter has no dev-key fallback in `.env`, so a 401 proves the request reached FastAPI):
```bash
curl -s -o /dev/null -w "%{http_code}\n" -X POST http://localhost:8080/api/v1/openrouter \
  -H "X-User-Id: verify-user" \
  -F "image=@/dev/null;type=image/jpeg;filename=food.jpg"
```
Expected: `401`.

- [ ] **Step 8: Verify per-user rate limiting (429s appear)**

Run (15 rapid requests, same user id; nginx counts them before proxying):
```bash
for i in $(seq 1 15); do
  curl -s -o /dev/null -w "%{http_code} " -X POST http://localhost:8080/api/v1/openrouter \
    -H "X-User-Id: burst-user" \
    -F "image=@/dev/null;type=image/jpeg;filename=food.jpg"
done; echo
```
Expected: the first ~6 return `401` (burst allowance, reaching FastAPI), the remainder return `429`.

- [ ] **Step 9: Tear down**

Run:
```bash
docker compose down
```
Expected: containers removed cleanly.

- [ ] **Step 10: Commit**

```bash
git add docker-compose.yml
git commit -m "feat: docker-compose for nginx + microservice, verified on Podman"
```

---

## Self-Review

**Spec coverage (addendum + parent):**
- Dockerfile hardening / `.dockerignore` (addendum §A) → Task 1. ✔
- nginx per-user rate limit on `$http_x_user_id`, 400/429 JSON (parent Task 4) → Task 2, verified Task 3 Steps 6, 8. ✔
- nginx only published port; FastAPI `expose` only (parent) → Task 3 Step 2. ✔
- Podman toolchain instead of Docker daemon (addendum §B) → Global Constraints + Task 2 Step 2, Task 3 Steps 1, 3, 4. ✔
- Podman socket prerequisite (addendum §C) → Task 3 Step 1. ✔
- `.env` untouched, `required: false`, excluded from image (addendum) → Task 1 + Task 3 Step 2. ✔
- No new provider endpoint (addendum out-of-scope) → Global Constraints; no such task. ✔
- Four observable behaviors (200/400/401/429) → Task 3 Steps 5–8. ✔
- `env_file` object-form compatibility note (addendum) → Task 3 Step 3 fallback. ✔

**Placeholder scan:** No TBD/TODO; every code/config block is complete; no "add error handling" hand-waves. ✔

**Type/name consistency:** service names (`microservice`, `nginx`), network (`internal`), zone (`peruser`), header (`X-User-Id`/`$http_x_user_id`), port pairs (`8080:80`, `expose 8000`), and file paths are consistent across tasks and match the existing `microservice:8000` upstream. ✔

**Note:** Tasks 1 and 2 do not require the running stack and can be done before the Podman socket is confirmed. Only Task 3 (Steps 4+) needs the machine reachable. Task 2 Step 2 (`podman run … nginx -t`) does need the socket; if it fails there, do Task 3 Step 1 first, then return.
