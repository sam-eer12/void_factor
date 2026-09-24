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
    """What the configuration claims, asserted against the running stack.

    Each check records what it saw and whether that was what it expected; the
    probe exits non-zero if any expectation fails, which is what lets CI run it
    as a smoke test of the real nginx in front of the real routes.
    """
    print("\n[gate] nginx request gating")
    image = jpeg_of(20_000)
    body = multipart_body(image)
    ctype = {"Content-Type": f"multipart/form-data; boundary={BOUNDARY}"}
    url = f"{BASE}/api/v1/gemini"
    stamp = int(time.time())

    gate = {}
    failures = []

    def check(label, name, response, expected, detail_prefix=None):
        ok = response.status_code == expected
        if ok and detail_prefix is not None:
            try:
                ok = str(response.json().get("detail", "")).startswith(detail_prefix)
            except ValueError:
                ok = False
        print(f"  {label:<34} -> {response.status_code} (expect {expected}"
              + (f", detail {detail_prefix}..." if detail_prefix else "")
              + (")" if ok else ")  FAIL"))
        gate[name] = response.status_code
        if not ok:
            failures.append(name)

    def user(uid):
        return {
            **ctype,
            "X-User-Id": uid,
            "Authorization": f"Bearer {mint(uid)}",
            "X-Gemini-Key": "loadtest-key",
        }

    r = httpx.post(url, content=body, headers=ctype, timeout=30)
    check("no credentials", "no_credentials", r, 401, "auth:")

    headers = user(f"gateuser{stamp}")
    r = httpx.post(url, content=body, headers=headers, timeout=90)
    check("authenticated", "authenticated", r, 200)
    if r.status_code == 200:
        nutrients = r.json().get("nutrients", {})
        if any(not isinstance(v, (int, float)) for v in nutrients.values()):
            failures.append("contract")
            print("  response nutrients are not all numbers  FAIL")

    bad = {**headers, "Authorization": "Bearer not-a-token"}
    r = httpx.post(url, content=body, headers=bad, timeout=30)
    check("forged token", "forged_token", r, 401, "auth:")

    # The header the limiter keys on, supplied by the client. nginx must
    # overwrite it with what verification returned, so this is just a forgery.
    spoofed = {**bad, "X-Verified-Uid": f"gateuser{stamp}"}
    r = httpx.post(url, content=body, headers=spoofed, timeout=30)
    check("forged token + X-Verified-Uid", "spoofed_verified_uid", r, 401, "auth:")

    r = httpx.post(url, content=multipart_body(b"<html>not a photo</html>"),
                   headers=headers, timeout=30)
    check("non-image upload", "non_image", r, 415, "image:")

    if os.getenv("PROBE_OVERSIZE") == "1":
        # nginx caps the body at 12m so a huge upload is refused at the proxy,
        # before a worker has spent anything reading it.
        huge = multipart_body(jpeg_of(13_000_000))
        r = httpx.post(url, content=huge, headers=headers, timeout=60)
        check("13MB upload", "oversized_13mb", r, 413)

    r = httpx.post(url, content=b"not multipart at all", headers=headers, timeout=30)
    print(f"  {'malformed body':<34} -> {r.status_code} (expect 4xx)"
          + ("" if 400 <= r.status_code < 500 else "  FAIL"))
    gate["malformed_body"] = r.status_code
    if not 400 <= r.status_code < 500:
        failures.append("malformed_body")

    # The hole the verified key closes: someone else's uid in X-User-Id, with a
    # real token of the attacker's own. Every one is refused, and none of them
    # may cost the victim anything — their full burst must still be there.
    victim = f"victim{stamp}"
    borrowed = {**user(f"attacker{stamp}"), "X-User-Id": victim}
    with httpx.Client(timeout=30) as client:
        drained = [client.post(url, content=body, headers=borrowed).status_code
                   for _ in range(12)]
    print(f"  {'12 with a borrowed uid':<34} -> {sorted(set(drained))} (expect [401])"
          + ("" if set(drained) == {401} else "  FAIL"))
    gate["borrowed_uid"] = drained
    if set(drained) != {401}:
        failures.append("borrowed_uid")

    # 10r/m with burst=5 nodelay: a handful land immediately, the rest are shed.
    # Sent as the victim above, so this is also the proof their bucket is whole.
    burst_headers = user(victim)
    codes = []
    started = time.monotonic()
    with httpx.Client(timeout=90) as client:
        for _ in range(12):
            codes.append(
                client.post(url, content=body, headers=burst_headers).status_code
            )
    accepted = sum(1 for c in codes if c == 200)
    limited = sum(1 for c in codes if c == 429)
    # The bucket refills while the run is in flight: a request that waits on the
    # provider for 2.5s hands back roughly half a token before the next one is
    # sent, so sequential requests see more than the bare burst of 5.
    elapsed = time.monotonic() - started
    allowance = 5 + int(elapsed * 10 / 60)
    # burst=5 nodelay admits the request that arrives plus five more, so a
    # whole bucket shows at least six before the first 429.
    whole = accepted >= 6 and limited > 0 and accepted <= allowance + 1
    print(f"  {'12 rapid from the victim':<34} -> {accepted} x 200, {limited} x 429 "
          f"over {elapsed:.1f}s (burst 5 + refill = {allowance} allowed)"
          + ("" if whole else "  FAIL"))
    gate.update({"burst_accepted": accepted, "burst_limited": limited,
                 "burst_elapsed_s": elapsed})
    if not whole:
        failures.append("burst")

    gate["failures"] = failures
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

    failed = out.get("gate", {}).get("failures")
    if failed:
        print(f"\n[gate] FAILED: {', '.join(failed)}")
        raise SystemExit(1)


if __name__ == "__main__":
    main()
