# Capacity

What this service can take, measured rather than guessed, and what that means
in daily active users.

The short version: **CPU is not the constraint.** An analysis costs this stack
under a millisecond of CPU and then spends two and a half seconds waiting for
Google. What ran out first was nginx's connection pool, at around 2,000 requests
in flight. Raising `worker_connections` from 1024 to 4096 moved the measured
ceiling from **820 to ~1,340 analyses/second** and turned a collapse into a
clean saturation curve. The next wall after that is ephemeral ports, not CPU.

## Running it

Two harnesses, because they answer different questions.

```sh
# This service alone, on this machine: where its own ceiling is.
cd microservice && .venv/bin/python -m loadtest.run_capacity

# The shipped stack — same image, real nginx, real rate limit — and what a
# request costs in CPU. Run from the repository root.
microservice/.venv/bin/python microservice/loadtest/run_stack.py

# What it does when things break: a replica dies, the provider fails, the load
# goes past the ceiling. Production topology, two replicas.
microservice/.venv/bin/python microservice/loadtest/robustness.py
```

`run_capacity.py` takes `--workers`, `--duration`, `--image-bytes`,
`--provider-ms`, `--cpu-conc`, `--realistic-conc` and `--shards`.

## What is real and what is stubbed

Two seams are replaced, and nothing else:

- **Google's public keys** (`app.auth.signing_key_for`) — the same seam the unit
  tests use. The RS256 signature check itself still runs, against a 2048-bit key,
  because that check is real per-request CPU.
- **`genai.Client`**, one level *below* the provider function. Replacing
  `call_gemini` wholesale would have been easier and would have measured a route
  that cannot fail, which is no use for asking what happens when the provider
  does fail. Stubbing the client instead leaves the real `call_gemini` on the
  measured path — its key check, its `except Exception`, its 502 conversion — so
  a fault injected with `LOADTEST_FAIL_PCT` travels the same route a real
  outage would. The fake still base64-encodes the image, because the body a
  provider is sent is base64 of the upload and that encoding is our CPU.

Only the Gemini provider is faked; the OpenRouter and NVIDIA routes keep their
real implementations and answer 401 without a key, so a typo in a path cannot
reach a real provider.

Everything else is production: the multipart parse of a real 150KB body, route
dispatch, the JSON parse and normalise of the model's answer, nginx's rate
limit, its 12MB body cap and its timeouts.

`loadtest/` is in `.dockerignore`. The stub reaches the container by bind-mount
and only under an overlay compose file, so no production image can contain it —
verified by listing `/app` in a built image, which holds `app/` and
`requirements.txt` and nothing else.

The generator speaks HTTP/1.1 over raw asyncio sockets and shards across
processes. That is not premature: the first version used httpx and reported
*its own* ceiling — throughput fell as concurrency rose while the service sat at
three percent of one core. Every phase prints server cores next to generator
cores, so a run that measures the generator is visible rather than believed.

## Measured

Native, three uvicorn workers as in the Dockerfile, Apple Silicon, 150KB image:

| phase | concurrency | rps | p95 | CPU/req | server cores |
|---|---|---|---|---|---|
| `/health` | 64 | 29,977 | 2.8 ms | 0.10 ms | 2.93 of 3 |
| analysis, provider instant | 32 | 6,304 | 9.8 ms | 0.46 ms | 2.89 of 3 |
| analysis, provider 2.5s | 800 | 315 | 2,575 ms | — | 0.19 |
| analysis, provider 2.5s | 3,200 | 1,186 | 2,852 ms | — | 0.72 |
| analysis, provider 2.5s | 6,400 | 2,153 | 3,238 ms | — | 1.27 |

At 6,400 in flight the run breaks: 135 connection resets, 228 timeouts, p99 at
6.7 s. Resident memory tracks concurrency at **0.27 MB per request in flight**
over a ~380 MB floor — 1.06 GB at 3,200.

Containerised, the shipped image behind the real nginx, cgroup accounting:

| | app | nginx |
|---|---|---|
| `/health` | 0.24 ms/req | 0.07 ms/req |
| analysis (150KB) | **0.55 ms/req** | **0.18 ms/req** |
| idle | 21 ms CPU/s | ~0 |

The containerised app agrees with the native measurement (0.55 vs 0.51 ms), so
the number is the work and not the machine. nginx adds a third on top. The 21
ms/s idle cost is the compose healthcheck starting a Python interpreter every
ten seconds.

Gating behaves as configured: no `X-User-Id` → 400, forged token → 401, valid
pair → 200, and a single user past its allowance → 429.

## The ceiling was nginx, not the service

`worker_connections 1024` with `worker_processes auto`, on a 4-core host, is
4,096 connections — and a proxied request holds two of them, one to the client
and one to the replica. That caps in-flight requests at about **2,048**.

Driven past it:

| in flight | rps | p95 | errors |
|---|---|---|---|
| 1,500 | 553 | 3,190 ms | none |
| 1,900 | 694 | 3,152 ms | 16 resets |
| 3,000 | 707 | 3,940 ms | 162,700 resets, 203 × HTTP 500 |

nginx's log named it directly: `1024 worker_connections are not enough`, 37,500
times in one run. Throughput did not climb past the wall, it collapsed onto it.

At a 2.5 s provider round trip, 2,048 in flight is ~820 analyses/second — about
60% of what the same four cores could do.

### After raising it to 4096

`worker_connections 4096` (with `worker_rlimit_nofile` and container `nofile`
raised to match) puts the proxy's capacity at 8,192 in flight, above what the
service itself can hold. Same host, same test:

| in flight | rps | p95 | app CPU/req | nginx CPU/req | errors |
|---|---|---|---|---|---|
| 3,000 | 982 | 4,380 ms | 1.08 ms | 0.39 ms | none |
| 4,500 | **1,336** | 4,978 ms | 1.08 ms | 0.41 ms | none |
| 6,000 | 988 | 7,454 ms | 1.47 ms | 1.19 ms | 3,412 × 502 |

The c=3,000 case that previously logged 162,700 connection resets and 203 HTTP
500s now runs clean, and no `worker_connections` alert appears at any level.

Two things this run shows that the first one could not:

- **Holding sockets is not free.** CPU per request roughly doubles between 48
  and 3,000 requests in flight — 0.73 ms to 1.47 ms across the stack. The epoll
  set, the timers and the buffers are real work, and a capacity estimate that
  extrapolates from a lightly loaded box will be optimistic.
- **The next constraint is ephemeral ports.** At 6,000 in flight nginx logs
  `connect() to 10.89.0.2:8000 failed (99: Address not available)`. Every
  upstream connection is one tuple to a single IP and port, Linux offers ~28,000
  ephemeral ports, and a completed connection sits in TIME_WAIT for a minute —
  so above roughly 500/s of *new* upstream connections the range is exhausted.
  The fix is to reuse rather than recycle: size `keepalive` near the number of
  connections actually in flight (hundreds, not tens) rather than widening the
  port range. It is currently 128 per worker.

The 1,336/s figure is a floor on what the stack can do, not a ceiling: the load
generator ran on the same four cores and took about half of them. Repeat this on
the deployment target, where nothing else is competing.

## How robust is it

Capacity asks how much the service can take. This asks what it does when
something breaks. Every scenario drives real traffic while the fault is
injected, against the production topology — two replicas, one nginx, the same
upstream stanza and the same shared `api_locations.conf`.

| fault | served | failed | p95 | verdict |
|---|---|---|---|---|
| replica stopped mid-flight | 4,792 | 103 × non-200, 0 transport | 2,576 ms | survives |
| replica restarted, same address | — | 0 | — | both replicas used again |
| **provider fails 100% of calls** | 0 | 6,895 × 502, 0 transport | 298 ms | degrades cleanly |
| 6,000 in flight, two replicas | 1,344/s | **none** | 6,411 ms | slows, does not break |
| load released after overload | 1,600 | none | 2,654 ms | full recovery |

What each one shows:

**A dying replica costs the requests it was holding, and nothing more.** All 103
failures fell in the single second the container was stopped — the ones already
in flight on it. Throughput continued on the survivor with no transport errors
and no latency scar. Those in-flight requests are lost rather than retried, and
that is deliberate: nginx does not replay a POST it has already sent, because
the request may have reached the provider and spent the caller's quota. A user
sees one failed scan, not a double charge.

**Total provider failure is a clean 502, not a cascade.** With every provider
call raising, 6,895 requests each got a 502, none hung, none produced a
transport error, and p95 stayed at the provider's own round trip. The service
does not accumulate work it cannot finish — it fails at the same rate it
succeeds, which is the property that keeps an outage from becoming a restart.

**Two replicas move the port wall.** The single-replica run collapsed at 6,000
in flight with 3,412 × 502 from ephemeral port exhaustion. The same load against
two replicas produced *no* errors at 1,344/s: a second upstream address doubles
the (source port, destination) tuples available. Horizontal scale buys
connection headroom here, not just CPU.

**Overload is reversible.** Driven well past the ceiling and then released, p95
returned to 2,654 ms against a 2,500 ms provider with zero errors. Nothing
stayed broken.

### What is not proven

- **A replica recreated on a *new* address.** nginx resolves upstream names once
  at start and declares no `resolver`, which is why the production compose file
  reloads every six hours. The scenario is written
  (`scenario_replica_new_address`) but was not run, so how long a recreated
  replica stays dark is still unmeasured — the honest assumption is up to six
  hours.
- **The 12MB body cap and malformed bodies.** Checks exist in the gate phase;
  they have not been run.
- **Anything over time.** No soak. Memory was sampled during runs of tens of
  seconds, not hours, so a slow leak would not have shown up.
- **TLS and certificate renewal.** Every run here is plain HTTP.

One harness note: the replica-loss timeline was recorded before the generator
staggered its connection starts, so its per-second shape is bunched by
synchronised clients. The totals are unaffected, and the failure window is
still correctly localised to the second of the stop.

## Translating to users

```
peak rps = DAU × scans per user per day × peak-hour share ÷ 3600 × burst factor
```

Meal logging concentrates on meals, so take a peak hour holding 20% of the day's
scans and a peak minute at twice that hour's average — a factor of 0.4/3600.
At 4 scans per user per day and the measured 820/s ceiling:

At the measured 1,340/s that is **≈ 3.0 million DAU**, or 12 million analyses a
day. Do not plan against it. Two things bind long before, and neither is CPU:

- **Egress — the real number.** Each scan is ~150KB in and ~200KB back out to
  Google. OCI's free tier includes 10 TB/month, which is ~50 million scans:
  about **415,000 DAU** at 4 scans a day before egress starts costing money.
  This did not move when the connection ceiling did, and it will not move for
  any amount of tuning. It is the figure to plan against.
- **The rate-limit zone.** `peruser:10m` holds on the order of 80,000 user keys
  before nginx evicts the oldest. Past that the limit still works, but a user
  who has been quiet loses their bucket and starts fresh. It degrades quietly
  rather than failing, which is the kind of thing worth knowing in advance.

The per-user limit itself — 10 r/m with a burst of 5 — never binds a real user
at 4 scans a day. It is there for the user whose client is looping.

## What was not measured

- **The target hardware.** Everything here ran on Apple Silicon, natively or in
  a Linux VM on it. An OCI Ampere A1 core is slower than an M-series core for
  this work; the honest way to size it is to run `run_capacity.py` on the
  instance, which needs no argument to do. CPU per request is the number to
  compare — it survives a change of machine, and throughput does not.
- **Two replicas.** Production runs two of these behind nginx; every number here
  is one. The service holds no state between requests, so the CPU ceiling should
  double. The nginx connection ceiling will not: it is the proxy's, not the
  replica's.
- **Real provider latency.** 2.5 s is an assumption, and every latency-bound
  number above scales inversely with it. `--provider-ms` changes it.
