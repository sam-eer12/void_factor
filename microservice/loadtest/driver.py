"""A closed-loop load generator: N virtual users, each looping as fast as the
service answers, for a fixed duration.

Closed loop rather than a fixed arrival rate because the question is where the
service stops keeping up, and an open-loop generator answers that by queueing
without bound instead of by reporting a knee.

Speaks HTTP/1.1 over raw asyncio sockets rather than through a client library,
and shards across processes. That is not premature: measured against httpx this
harness first reported the *client's* ceiling — throughput fell as concurrency
rose while the service sat at three percent of one core. A generator has to cost
much less per request than the thing it is measuring, or it measures itself.

Every virtual user carries its own Firebase-shaped token and its own
`X-User-Id`, because production traffic is many users rather than one, and
because nginx's rate limit keys on the uid that token verifies as.
"""
import asyncio
import multiprocessing as mp
import os
import random
import statistics
import time
from dataclasses import dataclass, field

import jwt

from loadtest.keys import ISSUER, PROJECT_ID, private_key

BOUNDARY = "voidfactorloadtest"


def mint(uid: str) -> str:
    now = int(time.time())
    return jwt.encode(
        {
            "sub": uid,
            "aud": PROJECT_ID,
            "iss": ISSUER,
            "iat": now,
            "exp": now + 3600,
        },
        private_key(),
        algorithm="RS256",
    )


def jpeg_of(size_bytes: int) -> bytes:
    """Bytes that start like a JPEG and are the size a client really uploads.

    Nothing decodes the image — the provider is stubbed — so only the length
    matters, and the length is what multipart parsing and base64 encoding cost.
    """
    head = b"\xff\xd8\xff\xe0\x00\x10JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00"
    return head + os.urandom(max(0, size_bytes - len(head) - 2)) + b"\xff\xd9"


def multipart_body(image: bytes) -> bytes:
    """The exact body the Flutter client sends: one `image` file part."""
    return (
        f"--{BOUNDARY}\r\n"
        'Content-Disposition: form-data; name="image"; filename="meal.jpg"\r\n'
        "Content-Type: image/jpeg\r\n\r\n"
    ).encode() + image + f"\r\n--{BOUNDARY}--\r\n".encode()


def build_head(method, host, port, path, uid, body_len) -> bytes:
    """The request line and headers for one identity.

    Head and body are kept apart and written as two calls rather than
    concatenated, so a pool of a thousand users costs a thousand header blocks
    and *one* image rather than a thousand copies of a 150KB body.
    """
    lines = [
        f"{method} {path} HTTP/1.1",
        f"Host: {host}:{port}",
        "Connection: keep-alive",
        "Accept: */*",
    ]
    if uid:
        lines += [
            f"X-User-Id: {uid}",
            f"Authorization: Bearer {mint(uid)}",
            "X-Gemini-Key: loadtest-key",
        ]
    if body_len:
        lines += [
            f"Content-Type: multipart/form-data; boundary={BOUNDARY}",
            f"Content-Length: {body_len}",
        ]
    return ("\r\n".join(lines) + "\r\n\r\n").encode()


async def _read_response(reader) -> int:
    head = await reader.readuntil(b"\r\n\r\n")
    lines = head.split(b"\r\n")
    status = int(lines[0].split()[1])
    length = None
    chunked = False
    for line in lines[1:]:
        lower = line.lower()
        if lower.startswith(b"content-length:"):
            length = int(line.split(b":", 1)[1])
        elif lower.startswith(b"transfer-encoding:") and b"chunked" in lower:
            chunked = True
    if chunked:
        while True:
            size = int((await reader.readuntil(b"\r\n")).strip(), 16)
            await reader.readexactly(size + 2)
            if size == 0:
                break
    elif length:
        await reader.readexactly(length)
    return status


async def _connection(host, port, heads, body, stop_at, samples, statuses, errors,
                      timeout, events, epoch, stagger):
    """One virtual client: a persistent connection, one request in flight at a
    time, rotating through `heads` so a phase can outrun a per-user rate limit
    the way a crowd of real users does."""
    reader = writer = None
    turn = 0
    # Without this every connection issues its first request at the same
    # instant and stays in step with the rest for the whole run, so a 2.5s
    # workload lands in bursts every 2.5s and a per-second timeline reads as
    # alternating full and empty seconds. Real clients are not synchronised.
    if stagger:
        await asyncio.sleep(random.uniform(0, stagger))
    try:
        while time.monotonic() < stop_at:
            started = time.monotonic()
            head = heads[turn % len(heads)]
            turn += 1
            try:
                if writer is None:
                    reader, writer = await asyncio.wait_for(
                        asyncio.open_connection(host, port), timeout
                    )
                writer.write(head)
                if body:
                    writer.write(body)
                await writer.drain()
                status = await asyncio.wait_for(_read_response(reader), timeout)
            except Exception as exc:
                name = type(exc).__name__
                errors[name] = errors.get(name, 0) + 1
                events.append((int(time.monotonic() - epoch), 0))
                if writer is not None:
                    writer.close()
                    writer = None
                # A refused connection under load would otherwise spin this loop
                # hot and distort every other connection's share of the CPU.
                await asyncio.sleep(0.05)
                continue
            finished = time.monotonic()
            samples.append(finished - started)
            statuses[status] = statuses.get(status, 0) + 1
            # Bucketed by completion, not by start: throughput is answers per
            # second, and a request that began before a fault but returned after
            # it belongs to the second it was actually served in.
            events.append((int(finished - epoch), status))
    finally:
        if writer is not None:
            writer.close()


def _shard(args):
    host, port, method, path, body, uid_groups, duration, timeout, stagger = args
    samples, statuses, errors, events = [], {}, {}, []
    body_len = len(body) if body else 0

    async def go():
        # Minting is RS256 signing — about a millisecond each — so every head is
        # built before the clock starts rather than inside the measured loop.
        conns = [
            [build_head(method, host, port, path, uid, body_len) for uid in group]
            for group in uid_groups
        ]
        epoch = time.monotonic()
        stop_at = epoch + duration
        await asyncio.gather(
            *(
                _connection(host, port, heads, body, stop_at, samples, statuses,
                            errors, timeout, events, epoch, stagger)
                for heads in conns
            )
        )

    started = time.monotonic()
    asyncio.run(go())
    return samples, statuses, errors, time.monotonic() - started, events


@dataclass
class Result:
    label: str
    concurrency: int
    duration: float = 0.0
    latencies: list = field(default_factory=list)
    statuses: dict = field(default_factory=dict)
    errors: dict = field(default_factory=dict)
    events: list = field(default_factory=list)

    def timeline(self) -> list:
        """Per-second [ok, non-200, transport errors], for reading a failure
        as it happened rather than as a total."""
        if not self.events:
            return []
        buckets = {}
        for second, status in self.events:
            row = buckets.setdefault(second, [0, 0, 0])
            row[0 if status == 200 else (2 if status == 0 else 1)] += 1
        return [[s] + buckets[s] for s in sorted(buckets)]

    @property
    def count(self) -> int:
        return len(self.latencies)

    @property
    def ok(self) -> int:
        return self.statuses.get(200, 0)

    @property
    def rps(self) -> float:
        return self.ok / self.duration if self.duration else 0.0

    def pct(self, p: float) -> float:
        if not self.latencies:
            return 0.0
        ordered = sorted(self.latencies)
        i = min(len(ordered) - 1, int(round(p / 100 * (len(ordered) - 1))))
        return ordered[i] * 1000

    @property
    def mean_ms(self) -> float:
        return statistics.fmean(self.latencies) * 1000 if self.latencies else 0.0


def run_phase(
    host: str,
    port: int,
    path: str,
    *,
    label: str,
    concurrency: int,
    duration: float,
    method: str = "POST",
    image_bytes: int = 150_000,
    shards: int = 4,
    timeout: float = 120.0,
    uids_per_conn: int = 1,
    stagger: float = 0.0,
    pool=None,
) -> Result:
    """`uids_per_conn` > 1 gives each connection a rotating pool of identities.

    One identity per connection is right when nothing is rate limiting by user.
    Through nginx it is not: at 10r/m plus a burst of 5, a connection hammering
    one uid measures the rate limiter after its first five requests. Sizing the
    pool so the whole phase stays inside every user's allowance is what makes
    the run measure the service instead.
    """
    body = multipart_body(jpeg_of(image_bytes)) if method == "POST" else b""
    shards = max(1, min(shards, concurrency))
    per_shard = [concurrency // shards + (1 if i < concurrency % shards else 0)
                 for i in range(shards)]

    jobs, offset = [], 0
    for n in per_shard:
        groups = []
        for _ in range(n):
            groups.append([f"loaduser{u:06d}" for u in range(offset, offset + uids_per_conn)])
            offset += uids_per_conn
        jobs.append((host, port, method, path, body, groups, duration, timeout,
                     stagger))

    result = Result(label=label, concurrency=concurrency)
    owned = pool is None
    pool = pool or mp.Pool(shards)
    try:
        for samples, statuses, errors, elapsed, events in pool.map(_shard, jobs):
            result.latencies.extend(samples)
            result.events.extend(events)
            for k, v in statuses.items():
                result.statuses[k] = result.statuses.get(k, 0) + v
            for k, v in errors.items():
                result.errors[k] = result.errors.get(k, 0) + v
            result.duration = max(result.duration, elapsed)
    finally:
        if owned:
            pool.close()
            pool.join()
    return result
