# Void Factor

A Flutter nutrition tracker: photograph a meal and have it read, or log it by
hand; see today's intake against your steps and workouts; get a weight
trajectory and three recommendations worded by a model running on the phone.

Food analysis runs through a FastAPI microservice that fronts three providers
with **the user's own API key** — the server never holds one — so the marginal
cost per user is zero. The recommendations use on-device Gemma, so those cost
nothing either.

---

## Status

Pre-release. Everything below is implemented and tested, but the backend is not
yet deployed and the Firestore rules are not yet pushed. See **Before you
ship**.

| Suite | Command |
| --- | --- |
| Flutter (660 tests) | `flutter test` |
| Microservice (26 tests) | `cd microservice && pytest` |
| Firestore rules (9 tests) | see `test_rules/README.md` |

---

## Layout

```
lib/
├── main.dart
├── app/                     # MaterialApp + named routes
├── features/                # Logic, one directory per domain
│   ├── auth/                # Email-link + Google sign-in, session, deletion
│   ├── data_transfer/       # Export / import bundle
│   ├── food_log/            # Analysis client, per-uid log store, providers
│   ├── health/              # Health Connect / HealthKit, background refresh
│   ├── profile/             # Firestore-backed profile + local mirror
│   ├── projection/          # Trajectory engine, Gemma model, narration
│   ├── reminders/           # Daily meal reminder
│   ├── support/             # UPI / Buy Me a Coffee destinations
│   └── weight_log/          # Per-uid weigh-in series
├── models/                  # FoodEntry, UserProfile, Projection, …
├── screens/                 # UI, grouped by feature
├── theme/                   # monolith_theme.dart — the whole design system
└── widgets/                 # Shared components

microservice/                # FastAPI: auth + three provider routes
├── app/auth.py              # Firebase ID token verification
├── app/providers/           # gemini, openrouter, nvidia
└── tests/

deploy/                      # Production compose, TLS, systemd, runbook
nginx/                       # Shared location rules + the dev server
test_rules/                  # Firestore security rules tests
firestore.rules              # The rules themselves
```

Logic lives in `features/`, UI in `screens/`. A screen reads providers and
renders; it does not talk to Firestore, the filesystem, or the network.

---

## Running it

### Prerequisites

Flutter `>=3.11.5`, Python 3.10+, and a container engine for the backend.

### The app

```sh
flutter pub get
flutter run
```

Sign in, complete onboarding, and add a provider API key in **Settings → API
key** (Gemini, OpenRouter, or NVIDIA NIM). Without one, scanning reports
"NO API KEY — SET ONE IN SETTINGS"; manual logging works regardless.

### The backend, locally

```sh
cp microservice/.env.example microservice/.env   # set FIREBASE_PROJECT_ID
docker-compose up --build                        # nginx on :8080
```

The app defaults to `http://10.0.2.2:8080` on Android and
`http://localhost:8080` elsewhere. A physical device needs your LAN address:

```sh
flutter run --dart-define=FOOD_API_BASE_URL=http://192.168.1.20:8080
```

> On this machine containers run under **Podman** with the standalone
> `docker-compose` binary — invoke it as `docker-compose`, not `docker compose`.

### Tests

```sh
flutter analyze --fatal-infos && flutter test
cd microservice && pytest
```

---

## How the pieces fit

**Authentication.** Firebase email-link and Google sign-in. Every analysis
request carries an ID token that the microservice verifies against Google's
public keys, plus an `X-User-Id` header that nginx rate-limits on (10 req/min
per user). A forged uid can change which rate-limit bucket it lands in; it
cannot reach a provider.

**Provider keys never leave the device.** They live in secure storage and travel
per request as a header. The server's own keys are a local-testing convenience
and are left blank in production.

**Food and weight logs are per-device JSON**, one file per uid, never synced.
That is a deliberate trade — no cross-device sync, no server-side food data —
and **Settings → Privacy** is the mitigation: export produces one file holding
profile, meals and weigh-ins; import merges by entry id, so running it twice
changes nothing and an old file cannot delete newer entries.

**The profile is the one thing in Firestore** (`users/{uid}`), readable and
writable only by that user. It carries the physical metrics, goal and allergies,
mirrored locally for offline reads.

**Projections are pure Dart**; recommendations are ranked in Dart and then
worded either by on-device Gemma (once downloaded in Settings → On-device model)
or by built-in templates. The model only changes the wording, never which
recommendations were chosen.

---

## Before you ship

Four things stand between this repo and users:

1. **Deploy the backend.** `deploy/README.md` — OCI Ampere A1, TLS via Let's
   Encrypt, systemd. Note the iptables step; it is the one that catches people.
2. **Push the Firestore rules.**
   `firebase deploy --only firestore:rules --project signinpractice-bfade`.
   Passing tests locally does not make them live.
3. **Build against the deployed host.**
   `flutter build apk --release --dart-define=FOOD_API_BASE_URL=https://<host>`.
   Without the flag every scan fails with "CAN'T REACH ANALYSIS SERVICE".
4. **Create an upload keystore.** `android/key.properties.example`. Until it
   exists, release builds fall back to debug signing and cannot be published.

Optional: set `SUPPORT_UPI_VPA` and `SUPPORT_BMC_USERNAME` at build time to
activate the support screen. Until then it says support is not set up, which is
the truth.

---

## Known limits

- **No cross-device sync.** Export is a recovery path, not sync.
- **The rate-limit bucket is forgeable** — nginx decides before FastAPI
  verifies. Authorization is not forgeable.
- **A saved provider key is never verified**, so a typo surfaces on the next
  scan rather than at save time.
- **A bad Gemini key is indistinguishable from a Gemini outage**, because the
  provider module collapses every failure into one message. OpenRouter and
  NVIDIA report their upstream status.
- **The log file grows without bound.** Roughly 700 KB per year at ten meals a
  day, read whole at launch. Fine for years, not forever.

---

## License

Private. Not published to pub.dev.
