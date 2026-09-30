# On-device Gemma downloads

The app, FastAPI routes and shared Nginx configuration are implemented locally.
OCI provisioning, acquiring the gated upstream weights, and live deployment are
separate release work. No real model weights or cloud credentials are included.

## Shared artifact

`assets/models/gemma3_1b_q4.json` pins the filename, source revision, exact byte
size, SHA-256 and terms version. Compose mounts that same file read-only into
each API replica. The app rejects a link response if any manifest field differs.

The source repository is gated. The listed size is published in Google's model
allowlist; the SHA-256 appears in a copy of the same LFS artifact. The real
artifact has **not** been acquired or independently hashed in this work.
The staging command streams and verifies the authorized upstream download
before publishing it; a mismatch stops staging:

```sh
cd microservice
.venv/bin/python -m tools.stage_model \
  --source /path/to/authorized/model.litertlm \
  --model-root ../local-models
```

It writes a staging file, checks size and digest, fsyncs, then atomically renames
it into `<model-root>/<sha256>/<filename>` with read-only file permissions.
Existing verified artifacts are left untouched, preserving their ETags. Nginx
mounts the model root read-only at `/srv/void-factor/models`.

## Server configuration

In `microservice/.env`, configure `MODEL_SIGNING_SECRET` (random, at least 32
bytes, identical across replicas), `MODEL_PUBLIC_ORIGIN`, and
`FIREBASE_PROJECT_ID`. Compose sets `MODEL_MANIFEST_PATH` to the shared mount.
`MODEL_PUBLIC_ORIGIN` is a configured HTTPS origin; request Host headers cannot
change it. Explicit HTTP origins for localhost, 127.0.0.1, ::1 and the Android
emulator host 10.0.2.2 are allowed for local testing. Use
`http://10.0.2.2:8080` when testing downloads in the emulator. The app only accepts
an HTTP download when the configured API uses the same local host and port.

Development Compose uses `MODEL_DIRECTORY=./local-models` by default. Production
Compose defaults to `/srv/void-factor/models`. Missing signing configuration or
unreadable/invalid manifest metadata returns 503. This does not disable food
analysis routes. A staged artifact is required for successful downloads; a
missing file returns 404 after authorization.

## Signed-link contract

`POST /api/v1/models/gemma/download-link`

Headers: `Authorization: Bearer <Firebase ID token>`, `X-User-Id: <same uid>`,
`Content-Type: application/json`.

```json
{"accepted_terms_version":"2026-04-01"}
```

Response 200:

```json
{
  "url": "https://<configured-host>/models/<sha256>/<filename>?version=...&uid=...&expires=...&signature=...",
  "expires_at": "2026-10-01T00:00:00+00:00",
  "model": {"version":"...","filename":"...","source_repository":"...","source_revision":"...","size_bytes":584417280,"sha256":"...","terms_version":"2026-04-01"}
}
```

The HMAC-SHA256 covers a canonical JSON array of version, exact download path,
uid and integer expiry. Links last 24 hours and are reusable for retries,
HEAD and byte-range requests. Every use is verified and counted against that
same user. Duplicate/extra query fields, altered values, unsupported methods,
and expired links return 403. Expiry is checked at the start of each request;
a response already streaming can finish later. Invalid Firebase sessions return
401; a terms revision mismatch returns 409. Responses containing links are
`Cache-Control: no-store`.

## Edge behavior

The public hop verifies the Firebase session for link issuance, or the signed
capability for downloads, then overwrites the identity header before forwarding
to a loopback-only limiter. Per-user limits occur **after** verification:

| Operation | Default |
| --- | --- |
| Issue links | 6 requests/minute, burst 6 |
| GET/HEAD/download/resume | 6 requests/minute, burst 6 |
| Concurrent transfers | 2 per verified user |

The existing per-address protection remains. Model requests use separate zones
from the ten food scans/minute allowance. Model limit responses are 429 with
`Retry-After: 10`. Nginx treats unexpected authorization-subrequest statuses as
500; the public model location maps that to 503. Invalid/expired links remain
403.

Static serving preserves ranges and ETags. Compression and proxy response
buffering are disabled; slow readers keep their transfer slots without Nginx
spooling models to temporary files. The capability query is stripped before
the loopback hop. Safe access logs contain time, address, method, path, status,
body bytes and duration, excluding query strings and headers. Model error logs
are suppressed because Nginx may otherwise include the full capability URL.
Uvicorn access logs are disabled. Release APKs remove native Log calls because
downloader exceptions can include URLs; debug-native logs are development-only
and should not be collected or shared with real capabilities.

Sum model-path `body_bytes_sent` across access logs to measure bandwidth.
Request and concurrency limits **do not enforce a monthly bandwidth budget**;
retaining and aggregating these logs remains operator work.

## App recovery and ownership

The fixed task ID is `gemma-<manifest version>`, independent of URL. The app
persists owner uid, full descriptor, task ID, expiry and progress in private
support storage. Callbacks subscribe before background-event replay. On
relaunch the service reconciles running tasks, completed staging files, and
paused resume data. A paused task obtains a new link before resuming under the
same ID. A streaming task needs no new link. Lost native resume data causes a
fresh transfer with visibly reset progress; preservation of all interrupted
bytes is not promised.

Downloads land in `models/<sha256>/<filename>.download`. Exact size and streamed
SHA-256 must match before a same-directory rename and registration with
`flutter_gemma.fromFile()`. Verifying has its own visible state. Ready requires
engine availability, valid local bytes and successful native model loading.
The app re-registers its verified external path after restart because
flutter_gemma 0.16.4 restores its default directory instead. Existing plugin-owned
models remain usable offline, including after an engine-only installation.
Removal serializes against inference, unloads, unregisters, and deletes owned
files and pending state. Logout stops the account-owned transfer and clears its
state; verified weights remain device-wide. Logout during link issuance cannot
enqueue a transfer for the old account.

Both Settings and Projections use `AGREE & DOWNLOAD MODEL` and the same terms
flow. Acceptance is stored per account and displayed revision. Legacy Hugging
Face tokens are erased. The agreement, Notice, and full prohibited-use policy
are bundled; the policy is incorporated in Void Factor's optional-model terms.
The generated privacy page describes authenticated OCI downloads.

## Local verification

```sh
flutter analyze --fatal-infos
flutter test
cd microservice && .venv/bin/python -m pytest tests -q
# From the repository root, with a running Podman VM:
microservice/.venv/bin/python microservice/modeltest/run.py
```

The edge harness uses the shipped Nginx configuration, real FastAPI/HMAC/Firebase
verification with a throwaway public key, and a 16 MiB fixture. It creates and
removes an isolated stack. It checks forged identities, independent budgets,
repeated/renewed links, HEAD/GET/206, ETags, two slow transfers, verifier failure
mapping, absence of proxy disk buffering, and capability-free logs. Python tests
also check expiry, each signed field, missing configuration and atomic staging.
Flutter tests cover descriptor checks, recovery, progress, verification failure,
account cleanup, migration, acceptance isolation and model states.

## Remaining release validation

1. Acquire the pinned weights with authorized upstream access; stage and verify
   the real bytes before exposing the artifact.
2. Deploy the artifact, API and Nginx; confirm authorization and byte ranges at
   the live hostname before distributing the updated app.
3. Perform one real Android download, app termination/restart, offline inference
   and removal. No Android device was connected for this local change.
4. Regenerate and publish the updated privacy policy. The repository's hosted
   HTML is updated; no hosting deployment was performed.
