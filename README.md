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
├── loadtest/                # Capacity and robustness harness + findings
└── tests/

deploy/                      # Production compose, TLS, systemd, runbook
tool/                        # Generates firebase_hosting/public/privacy.html
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

### Capacity

```sh
cd microservice && .venv/bin/python -m loadtest.run_capacity
```

`microservice/loadtest/README.md` holds the method and the numbers. The short
version: an analysis costs the stack well under a millisecond of CPU and then
spends seconds waiting on the provider, so CPU is never the constraint. The
measured ceiling is **~1,340 analyses/second**, and the limit that actually
decides how many users fit is **egress** — roughly **415,000 DAU** at four scans
a day before OCI's free 10 TB/month runs out.

Under fault: a stopped replica costs only the requests it was holding, a total
provider outage degrades to clean 502s without cascading, and load driven past
the ceiling recovers fully once released.

Android builds and the Firestore emulator both need a JDK, and there is none on
PATH here. Android Studio's bundled runtime works for both:

```sh
export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
export PATH="$JAVA_HOME/bin:$PATH"
export ANDROID_HOME="$HOME/Library/Android/sdk"
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

Five things stand between this repo and users:

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
   When you make one, its SHA-256 has to be added in two places or email links
   stop opening the app for every release build — see **Email links and App
   Links** below.
5. **Publish the privacy policy.** Play requires it at a public URL, separate
   from the copy in the app. Hosting is deployed, so
   `https://signinpractice-bfade.firebaseapp.com/privacy` is live and ready to
   paste into the Play Console listing. After editing the policy, regenerate
   and redeploy:
   `firebase deploy --only hosting --project signinpractice-bfade` from
   `firebase_hosting/`.

### Email links and App Links

A verification link opens the app instead of a browser only if Android can
verify the app owns the domain. That takes two matching facts, and a release
keystore changes both:

- `firebase_hosting/public/.well-known/assetlinks.json` lists the signing
  certificate's SHA-256. It currently lists the **debug** certificate, which is
  what release builds are also signed with until `key.properties` exists.
- The same SHA-256 is registered on the Firebase Android app
  (`firebase apps:android:sha:create <appId> <sha256>`), which is what Google
  Sign-In checks.

Add the upload keystore's SHA-256 to the JSON array (keep the debug one so
local builds keep working), redeploy hosting, and register it with
`firebase apps:android:sha:create 1:286425881714:android:eeab1979ef36ba089cb6eb
<sha256>`. Verify with:

```sh
curl "https://digitalassetlinks.googleapis.com/v1/statements:list?\
source.web.site=https://signinpractice-bfade.firebaseapp.com&\
relation=delegate_permission/common.handle_all_urls"
```

iOS Universal Links are **not** set up: the app has no Apple Team ID, so the
`apple-app-site-association` Firebase serves is empty. On iOS the links open in
Safari and finish on the hosted page; the in-app paste field and password login
both still work.

Optional: set `SUPPORT_UPI_VPA` and `SUPPORT_BMC_USERNAME` at build time to
activate the support screen. Until then it says support is not set up, which is
the truth.

### The privacy policy is generated

The policy text lives once, in `lib/features/legal/privacy_policy.dart`. The
in-app screen reads it directly; the hosted page is generated from it:

```sh
dart run tool/privacy_policy_html.dart   # writes firebase_hosting/public/privacy.html
```

Edit the policy without regenerating and `test/privacy_policy_test.dart` fails,
because a policy that has drifted from what the app does is worse than none.

### The size problem

**The arm64 build is 216.6 MB, over Google Play's 200 MB download limit.** Every
modern phone is arm64, so this blocks a Play release as things stand.

| ABI | Download size |
| --- | --- |
| `arm64-v8a` | **216.6 MB** |
| `x86_64` | 58.5 MB |
| `armeabi-v7a` | 43.8 MB |

It is all `flutter_gemma`'s native inference stack, and none of it is the model
— those weights are already downloaded at runtime, not bundled. arm64 is four
times the others because the Qualcomm NPU backends are arm64-only:

```
libllm_inference_engine_jni.so   26.4 MB
libLiteRtLm.so                   24.7 MB
libqdrant_edge_ffi.so            19.3 MB   (vector DB — unused here)
libmediapipe_tasks_vision_jni.so 14.3 MB
…_image_generator_jni.so         14.0 MB   (image generation — unused here)
libQnnHtpV*Skel.so               ~11 MB each, several
```

Three ways out, in increasing order of effort:

1. **Ship without on-device Gemma.** `TemplateNarrator` already exists and is
   already the fallback when the model is absent, so the app degrades to
   built-in wording with no code change — only a dependency removal. Roughly
   180 MB back.
2. **Play Feature Delivery** — move the inference engine into an on-demand
   module, downloaded when the user opts into the on-device model. Keeps the
   feature, but it is real Gradle work.
3. **Wait for `flutter_gemma` to split its backends.** Nothing to do but track
   it.

This is not a regression from any recent change — it is what the dependency has
always cost. It only became visible when a release build first completed.

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
- **The app is very large on arm64** — see "The size problem" above.
- **A recreated replica can stay dark.** nginx resolves upstream names once at
  start and declares no `resolver`, so a replica that returns on a new container
  address is not used again until the six-hourly reload. A restart that keeps
  the address recovers immediately; a recreate may not.
- **Requests in flight on a replica that dies are lost, not retried.** Deliberate
  — replaying a POST could spend the caller's provider quota twice — but the
  user sees a failed scan.
- **Ephemeral ports bound a single replica** before CPU does. Past roughly 500
  new upstream connections a second the source-port range exhausts; a second
  replica doubles the range, and a larger upstream `keepalive` would reuse
  rather than recycle.

---

## License

Private. Not published to pub.dev.
