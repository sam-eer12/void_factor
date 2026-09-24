#!/bin/sh
# Checks a deployed stack from the outside, as a phone would reach it. Run after
# every deploy, from anywhere with curl:
#
#   sh deploy/verify-live.sh 203-0-113-7.sslip.io
#
# Needs no credentials and spends nothing: every /api/ request here is one the
# edge must refuse before a provider is called. What it proves is the part CI
# cannot — that this host's DNS, firewall, certificate and container engine are
# serving the configuration the repository describes.
set -u

HOST="${1:?usage: verify-live.sh <hostname>}"
BASE="https://$HOST"
FAILED=0

pass() { printf '  ok    %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; FAILED=1; }

# Status code and body of one request, split on the last line.
request() {
    curl -sS --max-time 20 -w '\n%{http_code}' "$@" 2>/dev/null || printf '\n000'
}
status_of() { printf '%s' "$1" | tail -n 1; }
body_of() { printf '%s' "$1" | sed '$d'; }

echo "Checking $BASE"

# TLS: curl verifies the chain and the name by default, so a staging or
# expired certificate fails here rather than in the app.
r="$(request "$BASE/health")"
if [ "$(status_of "$r")" = 200 ] && body_of "$r" | grep -q healthy; then
    pass "/health over trusted TLS"
else
    fail "/health over trusted TLS (got $(status_of "$r"))"
fi

hsts="$(curl -sS -o /dev/null -D - --max-time 20 "$BASE/health" 2>/dev/null \
    | tr -d '\r' | grep -i '^strict-transport-security:')"
[ -n "$hsts" ] && pass "HSTS header present" || fail "HSTS header missing"

loc="$(curl -sS -o /dev/null -w '%{http_code} %{redirect_url}' --max-time 20 \
    "http://$HOST/health" 2>/dev/null)"
case "$loc" in
    "301 https://$HOST/health") pass "plain HTTP redirects to HTTPS" ;;
    *) fail "plain HTTP redirects to HTTPS (got: $loc)" ;;
esac

# The edge refuses an unauthenticated scan itself, as JSON the app routes on.
r="$(request -X POST "$BASE/api/v1/gemini")"
if [ "$(status_of "$r")" = 401 ] && body_of "$r" | grep -q '"auth:'; then
    pass "unauthenticated /api/ refused with auth: JSON"
elif [ "$(status_of "$r")" = 503 ] && body_of "$r" | grep -q '"auth:'; then
    fail "the verifier is not answering (503) — is FIREBASE_PROJECT_ID set?"
else
    fail "unauthenticated /api/ (got $(status_of "$r"): $(body_of "$r"))"
fi

# The header the limiter keys on, supplied by the caller, must buy nothing.
r="$(request -X POST -H 'Authorization: Bearer forged' \
    -H 'X-User-Id: someone' -H 'X-Verified-Uid: someone' "$BASE/api/v1/gemini")"
if [ "$(status_of "$r")" = 401 ]; then
    pass "a forged token with a spoofed X-Verified-Uid is refused"
else
    fail "forged token with spoofed X-Verified-Uid (got $(status_of "$r"))"
fi

# The internal verifier is not routed from outside.
r="$(request "$BASE/internal/verify")"
case "$(status_of "$r")" in
    404) pass "/internal/verify not exposed" ;;
    *) fail "/internal/verify answered $(status_of "$r") from outside" ;;
esac

if [ "$FAILED" -ne 0 ]; then
    echo "Some checks failed."
    exit 1
fi
echo "All checks passed."
