"""One outbound connection pool per worker process, shared by every provider.

A client per request pays a TCP and TLS handshake to the provider on every
analysis and throws the socket away afterwards. Sharing one keeps connections to
Google, OpenRouter and NVIDIA warm across callers. That is safe even though the
API key differs per request: the key travels as a request header, never as a
property of the connection.

The client is built lazily and rebuilt if it has been closed, so an app that is
started, shut down and started again in one process (as a test suite does) gets a
working pool the second time rather than "client has been closed".
"""
import httpx

# 60s to stay inside nginx's 90s read timeout, so a slow provider call is cut off
# here and answered as a 502 rather than dropped by the proxy.
TIMEOUT = httpx.Timeout(60)

# httpx's defaults (100 connections, 20 kept alive) are sized for a script, not
# for a worker holding hundreds of multi-second provider calls at once: the
# 101st would queue for a free socket and eventually fail on the pool timeout
# while the provider sat idle. The ceiling here is above what a worker can hold
# in flight (see loadtest/README.md), so the pool is never what runs out first.
LIMITS = httpx.Limits(max_connections=1000, max_keepalive_connections=100)

_client: httpx.AsyncClient | None = None


def client() -> httpx.AsyncClient:
    global _client
    if _client is None or _client.is_closed:
        _client = httpx.AsyncClient(timeout=TIMEOUT, limits=LIMITS)
    return _client


async def aclose() -> None:
    """Releases the pool. Wired to app shutdown in app/main.py."""
    global _client
    if _client is not None:
        await _client.aclose()
        _client = None
