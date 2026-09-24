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
| Flutter (809 tests) | `flutter test` |
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

android/gemma_engine/        # On-demand Play module: the on-device inference engine

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

### Store builds

Play takes an app bundle, and only an arm64 one is worth building:

```sh
flutter build appbundle --release --target-platform android-arm64 \
  --dart-define=FOOD_API_BASE_URL=https://<host>
```

The on-device inference engine is not in the base of that bundle. It is the
on-demand module in `android/gemma_engine`, which Play installs when the user
downloads the model — see **The size problem** below. To exercise that install
without Play, use bundletool's local testing against a device or emulator:

```sh
bundletool build-apks --local-testing \
  --bundle build/app/outputs/bundle/release/app-release.aab --output app.apks
bundletool install-apks --apks app.apks
```

`flutter run` and `flutter build apk` produce APKs, which have no module to
install from, so those keep the engine in the base exactly as before.

`flutter build appbundle` ends by checking the bundle's native libraries were
stripped, using `apkanalyzer` from the Android SDK **command-line tools**. Without
them it reports "failed to strip debug symbols" and exits non-zero even though
the bundle is fine — install *Android SDK Command-line Tools* from Android
Studio's SDK Manager.

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
public keys. nginx has the service verify that token *before* it counts the
request, and rate-limits on the verified uid (10 req/min per user), so a forged
or borrowed uid never touches anyone's bucket. A per-address limit in front of
that bounds what unauthenticated callers can ask of the verifier. See
`nginx/api_http.conf` for why that takes two hops.

**Uploads are checked by their bytes.** The service sniffs JPEG, PNG, WebP and
HEIC from the file's magic number, refuses anything else before a provider is
called, and tells the provider the real type. Responses are a typed contract
(`microservice/app/schemas.py`): four non-negative numbers, never `null`.

**Provider keys never leave the device.** They live in secure storage and travel
per request as a header. The server's own keys are a local-testing convenience
and are left blank in production.

**Food and weight logs are per-device JSON**, one file per uid, never synced.
The food log is a snapshot plus a journal: logging, editing or deleting one meal
appends one line instead of rewriting the whole log, and every 256 lines the
journal is folded into a new snapshot. A log large enough to matter is parsed
off the UI isolate.
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
recommendations were chosen. It runs on the GPU with a CPU fallback, stays
loaded between generations, and is unloaded when the app leaves the screen or
the system reports memory pressure.

**The app resumes where it was left.** Android kills backgrounded apps — the
camera alone can take enough memory to do it — so the app is built to come back
as it was:

- Flutter state restoration brings back the tab, the screens pushed over it,
  what is typed into the entry, profile and goals forms, and scroll positions.
  API keys and the HuggingFace token are deliberately *not* restored.
- A scan's photo is held on disk (`pending_scan.dart`) from capture until the
  analysis answers. A photo the camera delivered to a killed app is recovered
  from the picker. Either way the next launch returns to the vision tab and
  finishes the scan into the same confirm form.
- A scan the user switched away from, which Android froze mid-request, is
  retried when they come back rather than reported as a network failure.
- A model download that outlived the app is re-attached to on relaunch.
- Resuming while offline no longer signs the user out; only an account that is
  actually gone (deleted, disabled, revoked) does.

---

## Before you ship

Five things stand between this repo and users:

1. **Deploy the backend.** `deploy/README.md` — OCI Ampere A1, TLS via Let's
   Encrypt, systemd. Note the iptables step; it is the one that catches people.
2. **Push the Firestore rules.**
   `firebase deploy --only firestore:rules --project signinpractice-bfade`.
   Passing tests locally does not make them live.
3. **Build against the deployed host.**
   `flutter build appbundle --release --target-platform android-arm64 --dart-define=FOOD_API_BASE_URL=https://<host>`.
   Without the flag every scan fails with "CAN'T REACH ANALYSIS SERVICE".
4. **Create an upload keystore.** `android/key.properties.example`. Until it
   exists, release builds fall back to debug signing and cannot be published;
   a bundle build says so in its output.
   When you make one, its SHA-256 has to be added in two places or email links
   stop opening the app for every release build — see **Email links and App
   Links** below.
5. **Publish the privacy policy.** Play requires it at a public URL, separate
   from the copy in the app. Hosting is deployed, so
   `https://void-factor.web.app/privacy` is live and ready to paste into the
   Play Console listing. After editing the policy, regenerate and redeploy:
   `firebase deploy --only hosting --project signinpractice-bfade` from
   `firebase_hosting/`.

### Two hosting sites, one project

`firebase_hosting/firebase.json` declares `hosting` as an array of two sites,
both serving the same `public/` directory:

- **`void-factor.web.app`** — the name to hand to people. It is what Play reads
  for the privacy policy and where `kAuthContinueUrl` lands the laptop half of a
  cross-device verification.
- **`signinpractice-bfade.web.app`** — the project's default site, kept because
  the project ID is baked into `google-services.json` and
  `GoogleService-Info.plist`.

Because each entry names its `site` directly, no deploy targets and no
`.firebaserc` are needed: one `firebase deploy --only hosting` publishes both.

Renaming the hosting site did **not** rename the project. The emailed link's
host comes from Auth's action URL, still
`https://signinpractice-bfade.firebaseapp.com/__/auth/action`, which is why
that is the only host the App Links filter and the iOS entitlement claim. Point
those at `void-factor` only if you change the action URL to match, or links
stop opening the app.

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

**Solved: Play's install-time download is 14.3 MB on arm64**, down from a
216.6 MB APK that was over Play's 200 MB limit. It was all `flutter_gemma`'s
native stack — never the model, whose weights are downloaded at runtime — and it
came apart into three piles:

| | What | Where it went |
| --- | --- | --- |
| ~136 MB | MediaPipe's `.task` LLM runtime, image generation, the qdrant vector store, the Qualcomm NPU stack | Excluded. This app runs a `.litertlm` model through LiteRT-LM over FFI and never loads them. The NPU would need a model compiled for one specific SoC. |
| ~52 MB (20.5 MB download) | LiteRT-LM and its GPU accelerators and samplers | `android/gemma_engine`, an on-demand module Play installs alongside the model download |
| the rest | Flutter, the app, small plugin libraries | The base |

Measured with `bundletool get-size total` on the arm64 split APKs.

The engine arrives in the same progress bar as the model. Because a module
installed while the app runs is not on the process's library path,
`gemma_engine.dart` loads each library by path, in dependency order, before
flutter_gemma opens them by name; `GemmaEngineDelivery.kt` finds the paths. The
list of libraries is declared once, in `android/app/build.gradle.kts`, and read
by the module and the Kotlin loader. **If flutter_gemma adds or renames a native
library, update that list** — a library that lands in the base unlisted costs
size, and one missing from it breaks on-demand installs.

The app is **arm64-only** (`abiFilters`). LiteRT-LM ships no other Android ABI,
so 32-bit and x86_64 devices could never run the model; they now cannot install
the app either.

---

## Known limits

- **No cross-device sync.** Export is a recovery path, not sync.
- **No per-day quota.** The per-user limit is per minute, in nginx memory; a
  daily cap would need Redis or similar.
- **A saved provider key is never verified**, so a typo surfaces on the next
  scan rather than at save time.
- **A bad Gemini key is indistinguishable from a Gemini outage**, because the
  provider module collapses every failure into one message. OpenRouter and
  NVIDIA report their upstream status.
- **The food log is still read whole at launch.** Writes are now appends, and a
  large log is parsed off the UI isolate, but nothing is ever dropped from it —
  deliberately, since export hands back every meal. Roughly 700 KB per year at
  ten meals a day.
- **The on-demand engine needs Play.** A build installed some other way from the
  split APKs cannot fetch the module; the model offer then says to install from
  Google Play. Universal APKs from bundletool, and every `flutter build apk`,
  carry the engine in the base and are unaffected.
- **arm64 only**, as above.
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
