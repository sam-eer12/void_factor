"""Capacity sweep: how much this service can take, and what that means in users.

Run from the microservice directory:

    .venv/bin/python -m loadtest.run_capacity

Three groups of phases, each answering a different question:

  floor      /health, no auth and no body — the framework's own ceiling, the
             number every other number has to fit under.
  cpu        /api/v1/gemini with the provider answering instantly — what one
             analysis costs *us* in CPU, with nothing waiting on Google.
  realistic  the same route with the provider taking as long as it really does —
             where concurrency, not CPU, decides what the service can hold.

CPU per request is the number that survives a change of hardware: it is measured
here and applied to the deployment target's core count in the summary.
"""
import argparse
import multiprocessing as mp
import os
import resource
import subprocess
import sys
import time

import httpx

from loadtest.driver import run_phase

HOST = "127.0.0.1"


def _pids(root: int) -> list[int]:
    out = subprocess.run(
        ["pgrep", "-P", str(root)], capture_output=True, text=True
    ).stdout.split()
    return [root] + [int(p) for p in out]


def _parse_cputime(value: str) -> float:
    # macOS ps renders cpu time as [[hh:]mm:]ss.ss
    parts = value.strip().split(":")
    seconds = float(parts[-1])
    if len(parts) > 1:
        seconds += int(parts[-2]) * 60
    if len(parts) > 2:
        seconds += int(parts[-3]) * 3600
    return seconds


def server_cpu_and_rss(root: int) -> tuple[float, float]:
    """(cpu seconds consumed so far, resident MB) across the whole worker tree."""
    pids = _pids(root)
    out = subprocess.run(
        ["ps", "-o", "time=,rss=", "-p", ",".join(str(p) for p in pids)],
        capture_output=True,
        text=True,
    ).stdout
    cpu = rss = 0.0
    for line in out.strip().splitlines():
        fields = line.split()
        if len(fields) < 2:
            continue
        cpu += _parse_cputime(fields[0])
        rss += int(fields[1]) / 1024
    return cpu, rss


def _children_cpu() -> float:
    """CPU burned by the generator's own shard processes.

    Reported next to the server's so a phase where the generator is the thing
    running out of road is visible rather than silently reported as the
    service's ceiling.
    """
    r = resource.getrusage(resource.RUSAGE_CHILDREN)
    return r.ru_utime + r.ru_stime


class Server:
    """uvicorn running the stubbed app, configured like the production image."""

    def __init__(self, port: int, workers: int, provider_ms: int):
        self.port = port
        self.workers = workers
        self.provider_ms = provider_ms
        self.proc = None

    def __enter__(self):
        env = dict(os.environ, LOADTEST_PROVIDER_MS=str(self.provider_ms))
        self.proc = subprocess.Popen(
            [
                sys.executable, "-m", "uvicorn", "loadtest.stub_app:app",
                "--host", HOST, "--port", str(self.port),
                "--workers", str(self.workers), "--log-level", "warning",
            ],
            env=env,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            try:
                if httpx.get(f"http://{HOST}:{self.port}/health", timeout=2).status_code == 200:
                    # Workers are up; let the pool settle before it is measured.
                    time.sleep(1.0)
                    return self
            except httpx.HTTPError:
                time.sleep(0.3)
        raise RuntimeError("server never became healthy")

    def __exit__(self, *exc):
        self.proc.terminate()
        try:
            self.proc.wait(timeout=15)
        except subprocess.TimeoutExpired:
            self.proc.kill()


ROWS = []


def measure(server, label, *, path, concurrency, duration, method="POST",
            image_bytes=150_000, provider_ms=0, warmup=3.0, shards=4):
    common = dict(method=method, image_bytes=image_bytes, shards=shards)
    if warmup:
        run_phase(HOST, server.port, path, label="warmup",
                  concurrency=min(concurrency, 32), duration=warmup, **common)

    cpu_before, _ = server_cpu_and_rss(server.proc.pid)
    gen_before = _children_cpu()
    result = run_phase(HOST, server.port, path, label=label,
                       concurrency=concurrency, duration=duration, **common)
    cpu_after, rss = server_cpu_and_rss(server.proc.pid)
    gen_after = _children_cpu()

    server_cpu = cpu_after - cpu_before
    row = {
        "group": label,
        "conc": concurrency,
        "provider_ms": provider_ms,
        "rps": result.rps,
        "p50": result.pct(50),
        "p95": result.pct(95),
        "p99": result.pct(99),
        "ok": result.ok,
        "statuses": result.statuses,
        "errors": result.errors,
        "cpu_ms_per_req": (server_cpu * 1000 / result.ok) if result.ok else 0.0,
        "server_cpu_cores": server_cpu / result.duration if result.duration else 0,
        "gen_cpu_cores": (gen_after - gen_before) / result.duration if result.duration else 0,
        "rss_mb": rss,
    }
    ROWS.append(row)
    bad = {k: v for k, v in result.statuses.items() if k != 200}
    print(
        f"  c={concurrency:<4} rps={row['rps']:8.1f}  p50={row['p50']:7.1f}ms  "
        f"p95={row['p95']:8.1f}ms  p99={row['p99']:8.1f}ms  "
        f"cpu/req={row['cpu_ms_per_req']:6.2f}ms  srv={row['server_cpu_cores']:4.2f}core  "
        f"gen={row['gen_cpu_cores']:4.2f}core  rss={row['rss_mb']:6.0f}MB"
        + (f"  NON-200={bad}" if bad else "")
        + (f"  ERR={result.errors}" if result.errors else "")
    )
    return row


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--workers", type=int, default=3, help="uvicorn workers, as in the Dockerfile")
    ap.add_argument("--duration", type=float, default=20.0)
    ap.add_argument("--port", type=int, default=8111)
    ap.add_argument("--image-bytes", type=int, default=150_000,
                    help="client compresses to 1024px/q80; ~150KB is typical")
    ap.add_argument("--provider-ms", type=int, default=2500,
                    help="simulated provider round trip for the realistic group")
    ap.add_argument("--cpu-conc", default="8,16,32,64,128",
                    help="concurrency levels for the cpu group")
    ap.add_argument("--realistic-conc", default="25,50,100,200,400,800",
                    help="concurrency levels for the realistic group")
    ap.add_argument("--shards", type=int, default=4,
                    help="generator processes; raise until gen cores stop rising")
    ap.add_argument("--skip", default="", help="comma-separated groups to skip")
    args = ap.parse_args()
    skip = {s for s in args.skip.split(",") if s}

    print(f"\nworkers={args.workers}  duration={args.duration}s  "
          f"image={args.image_bytes/1000:.0f}KB  host cores={os.cpu_count()}\n")

    if "floor" not in skip:
        print("[floor] /health — framework ceiling, no auth, no body")
        with Server(args.port, args.workers, 0) as s:
            for c in (16, 64, 128):
                measure(s, "floor", path="/health", concurrency=c,
                        duration=args.duration / 2, method="GET",
                        shards=args.shards)

    if "cpu" not in skip:
        print("\n[cpu] /api/v1/gemini — provider instant: our own cost per analysis")
        with Server(args.port, args.workers, 0) as s:
            for c in [int(c) for c in args.cpu_conc.split(",")]:
                measure(s, "cpu", path="/api/v1/gemini", concurrency=c,
                        duration=args.duration, image_bytes=args.image_bytes,
                        shards=args.shards)

    if "realistic" not in skip:
        print(f"\n[realistic] /api/v1/gemini — provider {args.provider_ms}ms")
        with Server(args.port, args.workers, args.provider_ms) as s:
            for c in [int(c) for c in args.realistic_conc.split(",")]:
                measure(s, "realistic", path="/api/v1/gemini", concurrency=c,
                        duration=args.duration, image_bytes=args.image_bytes,
                        provider_ms=args.provider_ms, shards=args.shards)

    import json
    # Under loadtest/results/ rather than the working directory: the working
    # directory is the build context, and a stray results file there ends up
    # copied into the production image.
    results = os.path.join(os.path.dirname(__file__), "results")
    os.makedirs(results, exist_ok=True)
    out = os.getenv("LOADTEST_JSON", os.path.join(results, "native.json"))
    with open(out, "w") as fh:
        json.dump(ROWS, fh, indent=2, default=str)
    print(f"\nwrote {out}")


if __name__ == "__main__":
    mp.set_start_method("fork")
    main()
