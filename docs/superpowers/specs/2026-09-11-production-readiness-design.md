# Production readiness

**Goal:** take the app from "runs against a laptop" to "a stranger can install
it and use it." Four workstreams on one branch, merged once.

The audit that produced this list found no defects: `flutter analyze` is clean,
576 Flutter tests and 12 microservice tests pass. Everything below is work that
was never started, not work that broke.

---

## A. Backend to production

The microservice currently exists only as a local compose stack.
`FoodAnalysisClient.defaultBaseUrl()` resolves to `http://10.0.2.2:8080` or
`http://localhost:8080`, so AI food scanning works on the developer's machine
and nowhere else. Three things stand between that and a deployed service: an
authenticated API, TLS, and a host that survives a reboot.

### Token verification without a service-account file

Firebase ID tokens are RS256 JWTs signed by Google. The service verifies them
with `PyJWT` against Google's published x509 certs
(`https://www.googleapis.com/robot/v1/metadata/x509/securetoken@system.gserviceaccount.com`),
cached in-process and refetched when a `kid` misses, checking:

| Claim | Expected |
|---|---|
| `aud` | the Firebase project id |
| `iss` | `https://securetoken.google.com/<project-id>` |
| `exp` | not expired (PyJWT enforces) |
| `sub` | non-empty; this is the uid |

**Rejected: `firebase-admin`.** It does the same verification, but requires a
service-account JSON on the server — a real credential to provision, rotate and
leak, for no security gain. The public-cert path needs only the project id,
which is not a secret (it already ships inside the Flutter binary).

`FIREBASE_PROJECT_ID` is the one required environment variable. When it is
unset the service **fails closed**: every `/api/` route returns 503 rather than
silently accepting unverified callers. A misconfigured deploy must not look
like a working one.

### Where the rate limit keys, and what that does not buy

nginx cannot verify a JWT, so it keeps limiting on `X-User-Id` exactly as
today. FastAPI then verifies the bearer token and **401s when the verified uid
does not match the header**.

This closes the hole that mattered: a forged `X-User-Id` can no longer reach a
provider. It does not close the bucket: a forger can still mint fresh
rate-limit buckets by varying the header, because nginx decides before FastAPI
ever sees the request. That residue is accepted. Moving the limiter into
FastAPI would fix it, at the cost of losing nginx's limiter and adding
per-process state that is wrong the moment there are two workers.

The client sends both headers on every call. `X-User-Id` stays because nginx
needs a cheap key; the bearer token is what actually authorizes.

### TLS

`nginx.conf` grows two server blocks: `:80` serves the ACME challenge and
redirects everything else to HTTPS, `:443` terminates TLS and carries the
rate-limited API. Certificates come from Let's Encrypt via a certbot container
renewing through the shared webroot volume.

**No domain is required to start.** `<public-ip-with-dashes>.sslip.io` resolves
to the instance and Let's Encrypt issues for it, at zero cost. Pointing a real
domain at the box later is a one-variable change (`APP_HOSTNAME`), because
nothing in the config hardcodes a name.

### Host

`deploy/` holds the production compose file, a systemd unit so the stack comes
back after a reboot, and a runbook. The runbook exists mostly for one trap:
**Oracle Linux and Ubuntu images on OCI ship restrictive iptables rules**, so
opening 80/443 in the VCN security list is necessary and not sufficient. A
deploy that fails only at this step looks exactly like a DNS problem.

### Gemini SDK

`google.generativeai` prints `FutureWarning: All support ... has ended`.
`google-genai==1.74.0` is already in `requirements.txt` — the migration is an
import and call-shape swap, and the deprecated package gets removed.

---

## B. Data safety

### Firestore rules

There are none. `users/{uid}` is the only document the app owns, and nothing
currently stops one authenticated user reading another's profile. The rules
deny by default and allow `read, write` only when `request.auth.uid == uid`.
They are verified against the Firestore emulator, not merely written — an
unverified security rule is a guess.

### Export and import

The food log and weight log live in per-uid JSON files on one device, with no
sync and no recovery: reinstalling, switching phones, or clearing app data
destroys the history permanently. The food-logging spec accepted this
deliberately and named the mitigation.

This is that mitigation, and it is also what makes the PRIVACY settings row
honest (it currently advertises "Data management & export" and does nothing).

One bundle, one file, covering profile + food log + weight log, out through the
share sheet. Import **merges by entry id** rather than replacing, so importing
the same bundle twice is a no-op and importing an old bundle cannot delete
newer entries. Entries already carry a random 16-byte id (`FoodEntry.id`), so
there is no migration.

---

## C. Product completion

**The dashboard shows a hardcoded `'120g'` protein figure** while a real food
log sits one provider away. It is replaced by today's actual totals, and a
calories figure is added — the headline number of a nutrition app, currently
absent from its home screen.

**Food entries cannot be edited or deleted.** A mis-scanned meal is permanent.
The form already round-trips a `FoodEntry`; it gains an edit mode, and the
notifier gains `update` and `remove` alongside `add`. Both persist before
committing state, for the same reason `add` does: the file is the only copy.

**The drawer always reads "USER".** `MonolithDrawer.userName` defaults to
`'USER'` and neither call site passes it, though both hold `user.displayName`.

**Three settings rows do nothing.** They get three different fates:

- **PRIVACY** becomes real — the export above, plus the existing delete path.
- **NOTIFICATIONS** becomes a single daily reminder to log meals. The app
  already declares `POST_NOTIFICATIONS` and ships a notification-capable
  downloader, so the marginal cost is small, and a tracker that never asks you
  to track is a weak tracker.
- **APPEARANCE** is deleted. The monochrome brutalist look is a deliberate
  design position; a theme switcher would undercut the one thing the app has a
  strong opinion about. A row that will never be built should not sit in the
  menu implying otherwise.

**The donation screen is entirely decorative** — an `Icons.qr_code_2`
placeholder, a fake `donate@monolith` handle, and PAYPAL/STRIPE/CRYPTO rows
with no tap handler, because `_buildDonationOption` accepts no callback. It
becomes a real scannable QR generated from a live `upi://pay` URI plus a Buy Me
a Coffee link. The VPA and BMC username live in **one named constant** so
supplying them later is a single edit.

---

## D. Release hygiene

- **Android release builds sign with debug keys** (`build.gradle.kts:36`, the
  untouched Flutter scaffold TODO). Moves to a gitignored `key.properties`,
  falling back to debug signing when absent so a fresh clone still builds.
- **Four declared dependencies are never imported**: `camera`,
  `firebase_storage`, `permission_handler`, `riverpod_annotation` (with
  `riverpod_generator`). `camera` in particular drags platform permissions in
  for nothing.
- **`pubspec.yaml` still says "A new Flutter project."**
- **The README describes a tree that no longer exists** — the pre-restructure
  `lib/screens/` layout with no `lib/features/`, a deleted `otp_screen.dart`, a
  `microservice/app.py` that is now a package — and omits the weight log,
  projections, recommendations, on-device Gemma, health integration, account
  deletion, and the API key screen.
- **Nothing enforces the three green suites.** GitHub Actions runs
  `flutter analyze`, `flutter test`, and `pytest` on push and PR.

---

## Out of scope

- **Cross-device sync.** Export is a recovery path, not sync. Firestore-backed
  logs remain the future option the per-uid file layout leaves open.
- **Per-day quotas.** Still an nginx limitation; still a Redis/Lua add-on if
  ever needed.
- **Renaming the Firebase project.** `signinpractice-bfade` is baked into the
  auth domain. Renaming means a new project and re-authentication for every
  existing user — a migration, not a cleanup.
- **Retro-specs for the weight log and projections.** They shipped without
  design docs. Writing those after the fact documents history rather than
  guiding work.
- **iOS release signing.** Requires the Apple Developer account and is done in
  Xcode, not in this repo.

## Known gaps after this work

- The rate-limit bucket is still forgeable (see above). Authorization is not.
- A saved provider key is still never verified at save time, so a typo surfaces
  on the next scan.
- A bad Gemini key is still indistinguishable from a Gemini outage, because
  `gemini.py` collapses every failure into one message.
- Export is manual. A user who never taps it and then reinstalls still loses
  everything.
