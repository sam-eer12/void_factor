"""What happens when things go wrong, measured under load.

    microservice/.venv/bin/python microservice/loadtest/robustness.py

Capacity asks how much the service can take. This asks what it does when a
replica dies, when the provider fails, when a client sends something it should
not, and when the load stops — because a system that is fast until the moment it
is not has not actually been characterised.

Runs the production topology: two replicas behind one nginx, the shared
api_locations.conf, the same upstream stanza. Every scenario drives real traffic
while the fault is injected, and reads the per-second timeline rather than the
total, because a total averages a thirty-second outage into a rounding error.
"""
import json
import os
import pathlib
import subprocess
import time

ROOT = pathlib.Path(__file__).resolve().parents[2]
HERE = pathlib.Path(__file__).resolve().parent
COMPOSE = ["podman", "compose", "-f", "microservice/loadtest/compose.replicas.yml"]
RESULTS = HERE / "results/robustness.json"

# Matched as a substring against `podman ps`, so the compose project
# prefix does not have to be guessed.
R1, R2 = "microservice-1", "microservice-2"
FINDINGS = []


def compose(*args, env=None, background=False):
    cmd = COMPOSE + list(args)
    full = {**os.environ, **(env or {})}
    if background:
        return subprocess.Popen(cmd, cwd=ROOT, env=full,
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return subprocess.run(cmd, cwd=ROOT, env=full, capture_output=True, text=True)


def container(name: str) -> str:
    """The engine's actual container name for a compose service."""
    out = subprocess.run(
        ["podman", "ps", "-a", "--filter", f"name={name}", "--format", "{{.Names}}"],
        capture_output=True, text=True,
    ).stdout.split()
    return out[0] if out else name


def podman(*args):
    return subprocess.run(["podman", *args], capture_output=True, text=True)


def load(env: dict, background=False):
    return compose("run", "--rm", "generator", env=env, background=background)


def read_timeline() -> dict:
    data = json.loads(RESULTS.read_text())
    return data.get("analysis", data.get("health", {}))


def show(label: str, result: dict, note: str = "") -> None:
    tl = result.get("timeline", [])
    ok = sum(r[1] for r in tl)
    bad = sum(r[2] for r in tl)
    err = sum(r[3] for r in tl)
    print(f"\n  {label}: {ok} ok, {bad} non-200, {err} transport errors"
          f"  p95={result.get('p95_ms', 0):.0f}ms")
    if tl:
        print("    per second (ok/non-200/err):")
        line = "      " + "  ".join(
            f"{r[1]}/{r[2]}/{r[3]}" for r in tl[: 60]
        )
        print(line[:400])
    if note:
        print(f"    -> {note}")
    FINDINGS.append({"scenario": label, "ok": ok, "non_200": bad,
                     "transport_errors": err, "p95_ms": result.get("p95_ms"),
                     "timeline": tl, "note": note})


def scenario_replica_loss():
    """A replica is stopped mid-flight, then brought back."""
    print("\n=== replica loss: stop one of two replicas under load ===")
    env = {"PROBE_CONC": "200", "PROBE_DURATION": "60", "PROBE_UIDS_PER_CONN": "16",
           "PROBE_PHASES": "analysis", "LOADTEST_PROVIDER_MS": "2500",
           "PROBE_STAGGER": "2.5"}
    proc = load(env, background=True)
    time.sleep(20)
    c2 = container(R2)
    print(f"  t+20s stopping {c2}")
    podman("stop", "-t", "5", c2)
    time.sleep(20)
    print(f"  t+40s starting {c2}")
    podman("start", c2)
    proc.wait()
    show("replica loss", read_timeline(),
         "one replica serving the middle third; watch for a gap in column 1")


def scenario_replica_return():
    """Did nginx route to the replica that came back, without a reload?"""
    print("\n=== replica return: is the recovered replica used again? ===")
    before = {}
    for name in (R1, R2):
        c = container(name)
        before[name] = podman("exec", c, "cat", "/sys/fs/cgroup/cpu.stat").stdout
    load({"PROBE_CONC": "100", "PROBE_DURATION": "20", "PROBE_UIDS_PER_CONN": "16",
          "PROBE_PHASES": "analysis", "LOADTEST_PROVIDER_MS": "2500",
          "PROBE_STAGGER": "2.5"})
    used = {}
    for name in (R1, R2):
        c = container(name)
        after = podman("exec", c, "cat", "/sys/fs/cgroup/cpu.stat").stdout
        delta = _usage(after) - _usage(before[name])
        used[name] = delta
        print(f"  {name}: {delta*1000:.0f} ms CPU during the run")
    balanced = min(used.values()) > max(used.values()) * 0.2
    FINDINGS.append({"scenario": "replica return", "cpu_ms": {k: v * 1000 for k, v in used.items()},
                     "note": "both replicas served traffic" if balanced
                             else "the restarted replica received nothing — nginx is "
                                  "still holding the old container address"})
    print(f"    -> {FINDINGS[-1]['note']}")


def _usage(stat: str) -> float:
    for line in stat.splitlines():
        if line.startswith("usage_usec"):
            return int(line.split()[1]) / 1_000_000
    return 0.0


def scenario_provider_failure():
    """Every provider call raises. Does that stay a clean 502?"""
    print("\n=== provider failure: 100% of provider calls raise ===")
    compose("down")
    compose("up", "-d", "--wait", env={"LOADTEST_FAIL_PCT": "100",
                                       "LOADTEST_PROVIDER_MS": "250"})
    load({"PROBE_CONC": "100", "PROBE_DURATION": "20", "PROBE_UIDS_PER_CONN": "16",
          "PROBE_PHASES": "analysis", "LOADTEST_FAIL_PCT": "100",
          "LOADTEST_PROVIDER_MS": "250", "PROBE_STAGGER": "0.5"})
    r = read_timeline()
    codes = r.get("statuses", {})
    show("provider failure", r,
         f"statuses {codes} — every one should be 502, none should hang")


def scenario_overload_recovery():
    """Driven past the ceiling, then released. Does it come back?"""
    print("\n=== overload then recovery ===")
    compose("down")
    compose("up", "-d", "--wait", env={"LOADTEST_PROVIDER_MS": "2500"})
    load({"PROBE_CONC": "6000", "PROBE_DURATION": "30", "PROBE_UIDS_PER_CONN": "2",
          "PROBE_PHASES": "analysis", "PROBE_SHARDS": "3",
          "LOADTEST_PROVIDER_MS": "2500", "PROBE_STAGGER": "2.5"})
    overload = read_timeline()
    print(f"  overload: {overload.get('rps', 0):.0f} rps, "
          f"p95 {overload.get('p95_ms', 0):.0f}ms, "
          f"non-200 {[k for k in overload.get('statuses', {}) if k != '200']}")
    time.sleep(10)
    load({"PROBE_CONC": "200", "PROBE_DURATION": "20", "PROBE_UIDS_PER_CONN": "16",
          "PROBE_PHASES": "analysis", "LOADTEST_PROVIDER_MS": "2500",
          "PROBE_STAGGER": "2.5"})
    show("recovery after overload", read_timeline(),
         "p95 back near the provider round trip means no lasting damage")


def scenario_bad_input():
    """What the proxy and the app do with input they should refuse."""
    print("\n=== malformed and oversized input ===")
    load({"PROBE_PHASES": "gate", "PROBE_OVERSIZE": "1",
          "LOADTEST_PROVIDER_MS": "250"})
    gate = json.loads(RESULTS.read_text()).get("gate", {})
    for k, v in gate.items():
        print(f"  {k:<22} {v}")
    FINDINGS.append({"scenario": "bad input", **gate})


def scenario_replica_new_address():
    """A replica recreated rather than restarted comes back on a new IP.

    nginx resolves upstream names once at start and declares no `resolver`, so
    this is the case the production compose file works around with a six-hourly
    reload. Worth knowing how long a replica stays dark.
    """
    print("\n=== replica recreated on a new address ===")
    c2 = container(R2)
    before_ip = podman("inspect", "-f",
                       "{{.NetworkSettings.Networks.loadtest_internal.IPAddress}}",
                       c2).stdout.strip()
    compose("rm", "-sf", "microservice-2")
    compose("up", "-d", "--wait", "microservice-2")
    c2 = container(R2)
    after_ip = podman("inspect", "-f",
                      "{{.NetworkSettings.Networks.loadtest_internal.IPAddress}}",
                      c2).stdout.strip()
    print(f"  address {before_ip or '?'} -> {after_ip or '?'}")

    before = {n: _usage(podman("exec", container(n), "cat",
                               "/sys/fs/cgroup/cpu.stat").stdout) for n in (R1, R2)}
    load({"PROBE_CONC": "100", "PROBE_DURATION": "20", "PROBE_UIDS_PER_CONN": "16",
          "PROBE_PHASES": "analysis", "LOADTEST_PROVIDER_MS": "2500",
          "PROBE_STAGGER": "2.5"})
    used = {n: _usage(podman("exec", container(n), "cat",
                             "/sys/fs/cgroup/cpu.stat").stdout) - before[n]
            for n in (R1, R2)}
    for n, v in used.items():
        print(f"  {n}: {v*1000:.0f} ms CPU during the run")
    reached = used[R2] > used[R1] * 0.2
    note = ("nginx found the new address on its own"
            if reached else
            f"the recreated replica received nothing: nginx still holds "
            f"{before_ip}. Production recovers this on its six-hourly reload, "
            f"so a replica can stay dark for hours after a recreate")
    print(f"    -> {note}")
    FINDINGS.append({"scenario": "replica recreated", "before_ip": before_ip,
                     "after_ip": after_ip,
                     "cpu_ms": {k: v * 1000 for k, v in used.items()}, "note": note})


def main():
    compose("down")
    compose("up", "-d", "--wait", env={"LOADTEST_PROVIDER_MS": "2500"})
    scenario_replica_loss()
    scenario_replica_return()
    scenario_replica_new_address()
    scenario_bad_input()
    scenario_provider_failure()
    scenario_overload_recovery()
    compose("down")
    out = HERE / "results/robustness_summary.json"
    out.write_text(json.dumps(FINDINGS, indent=2, default=str))
    print(f"\nwrote {out}")


if __name__ == "__main__":
    main()
