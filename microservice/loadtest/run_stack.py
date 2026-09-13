"""Runs the containerised stack and charges its CPU to the requests it served.

    python microservice/loadtest/run_stack.py          # from the repo root

The native sweep (`run_capacity.py`) measures this service alone, on this
machine. This one measures what actually ships — the same Linux image, behind
the same nginx, with the same rate limit — and reports CPU per request for the
proxy and the application separately.

CPU per request rather than throughput, because throughput here would be a
number about the developer's container VM. CPU per request survives contention:
sharing cores with the generator makes a run take longer, not cost more. Divide
a target host's cores by it and the result is that host's ceiling.
"""
import json
import os
import pathlib
import subprocess
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parents[2]
OVERLAY = "microservice/loadtest/compose.loadtest.yml"
RESULTS = ROOT / "microservice/loadtest/results/stack.json"

COMPOSE = ["podman", "compose", "-f", "docker-compose.yml", "-f", OVERLAY]
APP = "void_factor-microservice-1"
PROXY = "void_factor-nginx-1"


def compose(*args, env=None, capture=False):
    return subprocess.run(
        COMPOSE + list(args), cwd=ROOT, env={**os.environ, **(env or {})},
        capture_output=capture, text=True, check=False,
    )


def cgroup_cpu_seconds(container: str) -> float:
    """CPU the container has used since it started, from cgroup v2 accounting.

    The kernel's own number for the whole container — every uvicorn worker and
    every nginx worker inside it — rather than a sampled percentage.
    """
    out = subprocess.run(
        ["podman", "exec", container, "cat", "/sys/fs/cgroup/cpu.stat"],
        capture_output=True, text=True,
    ).stdout
    for line in out.splitlines():
        if line.startswith("usage_usec"):
            return int(line.split()[1]) / 1_000_000
    raise RuntimeError(f"no cpu accounting for {container}")


def run_group(label: str, *, provider_ms: int, phases: str, conc: int,
              duration: int, uids_per_conn: int = 16, shards: int = 2) -> dict:
    env = {
        "LOADTEST_PROVIDER_MS": str(provider_ms),
        "PROBE_PHASES": phases,
        "PROBE_CONC": str(conc),
        "PROBE_DURATION": str(duration),
        "PROBE_UIDS_PER_CONN": str(uids_per_conn),
        "PROBE_SHARDS": str(shards),
    }
    print(f"\n=== {label}: provider {provider_ms}ms, c={conc}, {duration}s ===")
    compose("up", "-d", "--wait", env=env)

    before = {APP: cgroup_cpu_seconds(APP), PROXY: cgroup_cpu_seconds(PROXY)}
    compose("run", "--rm", "generator", env=env)
    after = {APP: cgroup_cpu_seconds(APP), PROXY: cgroup_cpu_seconds(PROXY)}

    probe = json.loads(RESULTS.read_text()) if RESULTS.exists() else {}
    served = sum(p["ok"] for p in probe.values() if isinstance(p, dict) and "ok" in p)
    row = {
        "label": label,
        "provider_ms": provider_ms,
        "served": served,
        "app_cpu_s": after[APP] - before[APP],
        "proxy_cpu_s": after[PROXY] - before[PROXY],
        "probe": probe,
    }
    if served:
        row["app_cpu_ms_per_req"] = row["app_cpu_s"] * 1000 / served
        row["proxy_cpu_ms_per_req"] = row["proxy_cpu_s"] * 1000 / served
        print(f"  served={served}  app={row['app_cpu_ms_per_req']:.2f} ms/req  "
              f"nginx={row['proxy_cpu_ms_per_req']:.2f} ms/req")
    compose("down")
    return row


def idle_control(seconds: int = 30) -> dict:
    """What the containers cost with no traffic at all.

    The compose healthcheck starts a Python interpreter every 10 seconds. That
    is background CPU, and on a run with few requests it would otherwise be
    charged to them — which is exactly how a latency-bound phase comes to look
    like an expensive one.
    """
    compose("up", "-d", "--wait", env={"LOADTEST_PROVIDER_MS": "0"})
    time.sleep(2)
    a0, p0 = cgroup_cpu_seconds(APP), cgroup_cpu_seconds(PROXY)
    time.sleep(seconds)
    row = {
        "label": "idle",
        "app_cpu_per_s": (cgroup_cpu_seconds(APP) - a0) / seconds,
        "proxy_cpu_per_s": (cgroup_cpu_seconds(PROXY) - p0) / seconds,
    }
    print(f"\n[idle] app={row['app_cpu_per_s']*1000:.1f} ms CPU/s   "
          f"nginx={row['proxy_cpu_per_s']*1000:.1f} ms CPU/s")
    compose("down")
    return row


def main() -> None:
    rows = [
        idle_control(),
        # One route per group: a group mixing /health with /api/v1/gemini would
        # average a cheap GET into the cost of an analysis and report neither.
        run_group("health-only", provider_ms=0, phases="health",
                  conc=48, duration=20),
        run_group("analysis-only", provider_ms=0, phases="analysis",
                  conc=48, duration=20, uids_per_conn=64),
        # Latency-bound, plus the gating checks: confirms cost per request does
        # not change when requests spend their time waiting.
        run_group("realistic", provider_ms=2500, phases="gate,analysis",
                  conc=48, duration=20, uids_per_conn=16),
    ]
    out = ROOT / "microservice/loadtest/results/stack_summary.json"
    out.write_text(json.dumps(rows, indent=2))
    print(f"\nwrote {out}")


if __name__ == "__main__":
    sys.exit(main())
