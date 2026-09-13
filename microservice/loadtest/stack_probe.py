"""End-to-end probe of the shipped stack: nginx in front of the service.

Runs inside the compose network, so what it measures is the proxy and the
application rather than the container engine's port forwarding.

Two things the native sweep cannot answer:

  * what nginx costs per request, proxying a 150KB body rather than a bare GET;
  * whether the per-user rate limit behaves as configured — 10r/m with a burst
    of 5 — because that limit, not the service's CPU, is what a single user
    actually meets.

The throughput phases rotate through a pool of user identities, sized so the
whole run stays inside every user's allowance. A phase that hammered one uid
would measure the rate limiter and report it as the service's ceiling.
"""
import json
import os
import time

import httpx

from loadtest.driver import BOUNDARY, Result, jpeg_of, mint, multipart_body, run_phase

NGINX = "nginx"
PORT = 80
BASE = f"http://{NGINX}:{PORT}"


def wait_for_stack(timeout: float = 90) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            if httpx.get(f"{BASE}/health", timeout=3).status_code == 200:
                return
        except httpx.HTTPError:
            pass
        time.sleep(0.5)
    raise RuntimeError("stack never became healthy")


def functional_checks() -> dict:
    """What the configuration claims, asserted against the running stack."""
    print("\n[gate] nginx request gating")
    image = jpeg_of(20_000)
    body = multipart_body(image)
    ctype = {"Content-Type": f"multipart/form-data; boundary={BOUNDARY}"}

    gate = {}
    r = httpx.post(f"{BASE}/api/v1/gemini", content=body, headers=ctype, timeout=30)
    print(f"  no X-User-Id            -> {r.status_code} (expect 400)")
    gate["no_user_id"] = r.status_code

    uid = f"gateuser{int(time.time())}"
    headers = {
        **ctype,
        "X-User-Id": uid,
        "Authorization": f"Bearer {mint(uid)}",
        "X-Gemini-Key": "loadtest-key",
    }
    r = httpx.post(f"{BASE}/api/v1/gemini", content=body, headers=headers, timeout=90)
    print(f"  authenticated           -> {r.status_code} (expect 200)")
    gate["authenticated"] = r.status_code

    bad = {**headers, "Authorization": "Bearer not-a-token"}
    r = httpx.post(f"{BASE}/api/v1/gemini", content=body, headers=bad, timeout=30)
    print(f"  forged token            -> {r.status_code} (expect 401)")
    gate["forged_token"] = r.status_code

    if os.getenv("PROBE_OVERSIZE") == "1":
        # nginx caps the body at 12m so a huge upload is refused at the proxy,
        # before a worker has spent anything reading it.
        huge = multipart_body(jpeg_of(13_000_000))
        r = httpx.post(f"{BASE}/api/v1/gemini", content=huge, headers=headers,
                       timeout=60)
        print(f"  13MB upload             -> {r.status_code} (expect 413)")
        gate["oversized_13mb"] = r.status_code

    r = httpx.post(f"{BASE}/api/v1/gemini",
                   content=b"not multipart at all", headers=headers, timeout=30)
    print(f"  malformed body          -> {r.status_code} (expect 4xx, not 5xx)")
    gate["malformed_body"] = r.status_code

    # 10r/m with burst=5 nodelay: a handful land immediately, the rest are shed.
    burst_uid = f"burstuser{int(time.time())}"
    burst_headers = {
        **ctype,
        "X-User-Id": burst_uid,
        "Authorization": f"Bearer {mint(burst_uid)}",
        "X-Gemini-Key": "loadtest-key",
    }
    codes = []
    started = time.monotonic()
    with httpx.Client(timeout=90) as client:
        for _ in range(12):
            codes.append(
                client.post(
                    f"{BASE}/api/v1/gemini", content=body, headers=burst_headers
                ).status_code
            )
    accepted = sum(1 for c in codes if c == 200)
    limited = sum(1 for c in codes if c == 429)
    # The bucket refills while the run is in flight: a request that waits on the
    # provider for 2.5s hands back roughly half a token before the next one is
    # sent, so sequential requests see more than the bare burst of 5.
    elapsed = time.monotonic() - started
    allowance = 5 + int(elapsed * 10 / 60)
    print(f"  12 rapid from one user  -> {accepted} x 200, {limited} x 429 "
          f"over {elapsed:.1f}s (burst 5 + refill = {allowance} allowed)")
    gate.update({"burst_accepted": accepted, "burst_limited": limited,
                 "burst_elapsed_s": elapsed})
    return gate


def phase(label, path, *, concurrency, duration, method="POST", uids_per_conn=1,
          image_bytes=150_000, shards=2, stagger=0.0) -> Result:
    result = run_phase(
        NGINX, PORT, path, label=label, concurrency=concurrency, duration=duration,
        method=method, image_bytes=image_bytes, shards=shards,
        uids_per_conn=uids_per_conn, stagger=stagger,
    )
    bad = {k: v for k, v in result.statuses.items() if k != 200}
    print(
        f"  {label:<26} c={concurrency:<4} rps={result.rps:8.1f}  "
        f"p50={result.pct(50):7.1f}ms  p95={result.pct(95):8.1f}ms"
        + (f"  NON-200={bad}" if bad else "")
        + (f"  ERR={result.errors}" if result.errors else "")
    )
    return result


def _summary(r: Result) -> dict:
    return {
        "concurrency": r.concurrency,
        "duration_s": r.duration,
        "ok": r.ok,
        "rps": r.rps,
        "p50_ms": r.pct(50),
        "p95_ms": r.pct(95),
        "p99_ms": r.pct(99),
        "statuses": {str(k): v for k, v in r.statuses.items()},
        "errors": r.errors,
        "timeline": r.timeline() if os.getenv("PROBE_TIMELINE") == "1" else [],
    }


def main() -> None:
    phases = os.getenv("PROBE_PHASES", "gate,health,analysis").split(",")
    conc = int(os.getenv("PROBE_CONC", "48"))
    duration = float(os.getenv("PROBE_DURATION", "20"))
    uids_per_conn = int(os.getenv("PROBE_UIDS_PER_CONN", "16"))
    shards = int(os.getenv("PROBE_SHARDS", "2"))
    image_bytes = int(os.getenv("PROBE_IMAGE_BYTES", "150000"))
    stagger = float(os.getenv("PROBE_STAGGER", "0"))

    wait_for_stack()
    out = {}

    if "gate" in phases:
        out["gate"] = functional_checks()

    if "health" in phases or "analysis" in phases:
        print("\n[through nginx] throughput on the shipped configuration")
    if "health" in phases:
        # /health carries no rate limit and no body: nginx's floor.
        r = phase("health via nginx", "/health", concurrency=conc,
                  duration=duration, method="GET", shards=shards)
        out["health"] = _summary(r)
    if "analysis" in phases:
        # A pool of identities big enough that no user exceeds burst 5 + 10r/m.
        r = phase("analysis via nginx", "/api/v1/gemini", concurrency=conc,
                  duration=duration, uids_per_conn=uids_per_conn, shards=shards,
                  image_bytes=image_bytes, stagger=stagger)
        out["analysis"] = _summary(r)

    target = os.getenv("PROBE_OUT")
    if target:
        with open(target, "w") as fh:
            json.dump(out, fh, indent=2)


if __name__ == "__main__":
    main()
