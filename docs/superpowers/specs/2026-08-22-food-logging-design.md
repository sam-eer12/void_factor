# Food Logging: Vision Capture + Manual Entry

**Date:** 2026-08-22
**Status:** Approved design, ready for implementation planning

## Problem

`lib/screens/vision/ai_vision_screen.dart` and
`lib/screens/food_log/manual_food_log_screen.dart` exist but are pure UI
mockups: hardcoded strings (`'Grilled Chicken Salad', '450 kcal'`), `onTap:
() {}` on both CAPTURE and GALLERY, and a dead `Icons.add` button in the
history header. There is no food-log model, no repository, no Firestore
collection, and no HTTP client anywhere in `lib/` — the app has never called
the microservice, despite the microservice being complete and deployed behind
nginx.

Users need to log food two ways:

1. **Vision** — capture a photo or pick one from the gallery, have the
   microservice identify it and estimate nutrients, then log it.
2. **Manual** — fill in a form directly.

Every logged item carries a quantity the user can increment and decrement.

## Scope

**In scope:** the two logging flows end to end, a shared entry form, the
quantity stepper, Firestore persistence, 72h history rendering on both
screens, and the platform configuration required for either flow to run.

**Explicitly out of scope** (agreed, natural follow-ups):

- Editing or deleting existing log entries.
- Wiring today's calorie/macro totals onto the dashboard, which currently
  shows only Health Connect metrics.
- Adding a Settings field to change `api_key` after onboarding (see
  [Known gaps](#known-gaps)).
- Any change to the Python microservice or nginx.

## Decisions

| Question | Decision |
|---|---|
| What the stepper changes | **Serving multiplier** (`0.5x`, `1.0x`, `2.0x`). Nutrients are stored per-serving; totals are computed as per-serving x quantity. |
| Items per photo | **One.** `parsing.py:normalize()` already returns a single `{name, nutrients}`; no backend change. |
| Base URL resolution | **Compile-time `--dart-define`** with a platform default. |
| Image retention | **Discarded** after analysis. Log entries are text-only; `firebase_storage` stays unused. |
| Vision vs manual form | **One shared editable form.** Vision pre-fills it; every field stays editable so a bad AI reading can be corrected before saving. |
| Layering | Feature slice with a repository + API client + Riverpod providers, mirroring `features/health/` and `features/profile/`. |

### Rejected alternatives

- **Multi-item detection per photo.** Would require reshaping
  `normalize()` to `{items: [...]}`, updating all three provider prompts, and
  new Python tests. Deferred to keep this change Flutter-only.
- **Wiring HTTP and Firestore directly into the two screens.** Fastest to a
  demo, but duplicates credential-reading, provider-routing, and
  error-handling across two screens and is untestable without a device.
- **Layers without Riverpod** (`FutureBuilder`/`StreamBuilder`). `MonolithShell`
  keeps all four tabs alive in a `PageView`, so a locally-held `Future` in the
  vision tab would refetch on rebuild and could not be invalidated when the
  form saves. Fights the existing architecture, which is Riverpod-wide
  (`authStateProvider`, `healthMetricsProvider`, `profileProvider`).
- **A secure-storage mirror for logs**, as `ProfileRepository` does for the
  profile. A profile is one bounded document; a log is append-only and
  unbounded, so a JSON blob mirror is the wrong shape. Firestore's built-in
  offline persistence covers the same need.

## Data model

`lib/models/food_entry.dart`, following `UserProfile`'s tolerant-parsing style
(every field defaults rather than throwing on missing or mistyped data).

### `Nutrients`

Four doubles — `calories`, `proteinG`, `carbsG`, `fatsG` — always meaning
**per one serving**. Two distinct constructors, and the split is deliberate:

- **`Nutrients.fromApi(Map)`** reads the microservice's snake_case
  (`protein_g`, `carbs_g`, `fats_g`). `parsing.py:normalize()` uses
  `nutrients.get(...)`, which emits `null` for anything the model omitted, so
  `fromApi` coerces `null` to `0`. The user sees the zero in the editable form
  and corrects it before saving.
- **`Nutrients.fromMap` / `toMap`** use camelCase (`proteinG`) for Firestore,
  matching `UserProfile`'s convention.

Keeping the wire format separate from the storage format means a provider
prompt change cannot silently reshape stored documents.

### `FoodEntry`

| Field | Type | Notes |
|---|---|---|
| `id` | `String` | Firestore document id |
| `name` | `String` | Required non-empty at save time |
| `nutrients` | `Nutrients` | Per **one** serving |
| `quantity` | `double` | Serving multiplier |
| `source` | `FoodSource` | `vision` \| `manual`; enum with `wireValue`/`fromWire` like `WeightGoal` |
| `loggedAt` | `DateTime` | Client-side, see below |
| `schemaVersion` | `int` | Starts at `1` |

Quantity is stored **separately from the nutrients and never multiplied in**.
Totals come from getters: `totalCalories => nutrients.calories * quantity`.
This means changing quantity later never destroys the per-serving basis, and
the AI's original reading is preserved verbatim.

Stepper bounds: minimum `0.5`, step `0.5`, cap `20`.

### Firestore

Path: `users/{uid}/food_logs/{autoId}` — a subcollection, so it inherits
per-user isolation from the existing `users/{uid}` document and cannot bloat
the profile document the way an array field would.

Two decisions worth recording:

- **`loggedAt` is a client-side `DateTime`, not `serverTimestamp()`.** The
  history UI groups by local calendar day (`TODAY` / `YESTERDAY`).
  `serverTimestamp()` reads back as `null` locally until the server
  acknowledges, which would drop a just-saved entry out of its group —
  visibly broken on a slow connection.
- **The window is three local calendar days, not a rolling 72 hours.** The
  existing screens label it `LAST 72H` and bucket into
  `TODAY` / `YESTERDAY` / `2 DAYS AGO` — exactly three buckets. A rolling
  `now - 72h` does not align with those: at 09:00 today it reaches back to
  09:00 three days ago, so it would return entries belonging to a fourth
  bucket that has nowhere to render. The query lower bound is therefore
  **local midnight of (today - 2 days)**. The `LAST 72H` label is kept as
  existing copy; the boundary is the calendar one.
- **The query needs no composite index.**
  `where(loggedAt >= cutoff).orderBy(loggedAt, descending)` ranges and
  orders on a single field, so Firestore's automatic single-field index covers
  it. Day-grouping is computed client-side from local dates.

## Components

Nine files: seven new (the model above, plus the six below) and two rewired
screens.

### `lib/features/food_log/food_analysis_client.dart`

Reads `api_provider` and `api_key` from `FlutterSecureStorage` (written at
onboarding, `session_provider.dart:190`) plus the Firebase `uid`, then routes:

| stored `api_provider` | endpoint | key header |
|---|---|---|
| `GEMINI` | `POST {base}/api/v1/gemini` | `X-Gemini-Key` |
| `OPENROUTER` | `POST {base}/api/v1/openrouter` | `X-Openrouter-Key` |
| `NVIDIA NIM` | `POST {base}/api/v1/nvidia` | `X-Nvidia-Key` |

Every request also carries **`X-User-Id: <uid>`**. nginx returns `400` when it
is empty and keys its 10 req/min (burst 5) limit on it. The multipart field is
named `image`, matching `image: UploadFile = File(...)` in `routes.py`.

`'NVIDIA NIM'` must be normalized to the `nvidia` path segment. That mapping
is a pure function and gets its own test.

Base URL:

```dart
const _configured = String.fromEnvironment('FOOD_API_BASE_URL');

String get baseUrl => _configured.isNotEmpty
    ? _configured
    : (Platform.isAndroid
        ? 'http://10.0.2.2:8080'   // emulator loopback to the host
        : 'http://localhost:8080');
```

`String.fromEnvironment` returns `''` when the define is absent, which is what
selects the platform default.

Dependencies are injected through narrow seams (an `http.Client`, a
credential-store interface, and a uid accessor) so the client is testable
without a device — the same approach `HealthRepository` takes with
`HealthGateway` and `HealthKeyValueStore`.

### `lib/features/food_log/food_log_repository.dart`

Firestore writes and reads on `users/{uid}/food_logs`, with injectable
`FirebaseAuth` / `FirebaseFirestore` exactly like `ProfileRepository`.

### `lib/features/food_log/food_log_grouping.dart`

A single pure function:

```dart
List<DayGroup> groupByDay(List<FoodEntry> entries, {required DateTime now});
```

`DayGroup` carries a label (`TODAY` / `YESTERDAY` / `2 DAYS AGO`) and its
entries. Kept out of `food_entry.dart` because bucketing into UI day-labels is
presentation logic, not model logic, and kept out of
`food_log_providers.dart` because a top-level pure function taking an injected
`now` is testable without a `ProviderContainer` or a clock fake.

### `lib/features/food_log/food_log_providers.dart`

- `foodAnalysisClientProvider`
- `foodLogRepositoryProvider`
- `visionAnalysisProvider` — holds in-flight and error state for the analysis
  call
- **`recentFoodLogProvider`** — a `StreamProvider` over the three-calendar-day
  query. This is what keeps the two screens in agreement: saving from the form
  emits a new snapshot and both history lists redraw with no manual
  invalidation.

### `lib/widgets/food_quantity_stepper.dart`

`[-] 1.0x [+]`, styled with `MonolithTheme.containerDecoration` to match the
existing widgets.

### `lib/screens/food_log/food_entry_form_screen.dart`

The shared form: `NAME`, `KCAL`, `PROTEIN`, `CARBS`, `FATS` (all per serving,
all editable), the quantity stepper, and a live computed total.

Pushed as a plain `MaterialPageRoute` rather than a named route, because it
takes typed arguments (`initialName`, `initialNutrients`, `source`).
`lib/app/routes.dart` needs no change.

Validation at save time: `name` non-empty, `calories > 0`. Macros may be zero.

### Rewires

- `lib/screens/vision/ai_vision_screen.dart` — CAPTURE and GALLERY become
  live; the 280px panel becomes a framing placeholder plus loading/result
  area; `RECENT LOGS` reads `recentFoodLogProvider`.
- `lib/screens/food_log/manual_food_log_screen.dart` — the `Icons.add` button
  (`manual_food_log_screen.dart:76`) opens the blank form; `HISTORY` reads
  `recentFoodLogProvider`, grouped by day.

Both screens read the same provider and differ only in rendering: the vision
tab shows a short recent list, the history screen shows the full 72h grouped
by day.

## Data flow

**Vision:**

1. CAPTURE or GALLERY → `ImagePicker().pickImage(source: camera | gallery)`
2. `FlutterImageCompress` (1024px, quality 80) — keeps the upload small for
   the 10 req/min budget and shortens the provider round-trip
3. `FoodAnalysisClient.analyze(bytes)` → multipart POST through nginx →
   `{name, nutrients}` → `(String, Nutrients)`
4. Push the form, pre-filled, `source: vision`
5. SAVE → `FoodLogRepository.add(entry)` → the stream updates both history
   lists
6. Temp compressed file is discarded

**Manual:** `Icons.add` → the same form, blank, `source: manual` → SAVE.

`image_picker` is used for **both** capture and gallery; the `camera` package
stays unused. One API covers both sources with the OS camera UI, there is no
`CameraController` lifecycle to manage across `MonolithShell`'s always-alive
`PageView`, and on Android it needs no `CAMERA` permission because it
delegates by intent. The tradeoff is no in-app live preview.

## Error handling

**A rejected API key does not surface as 401.** `401` happens only when the
key is entirely absent *and* the server has no `DEV_GEMINI_KEY` fallback
(`gemini.py:10`). A *wrong* key becomes a **502**: Gemini's SDK throws inside
`generate_content`, which is caught and re-raised as
`502 "provider request failed"` (`gemini.py:20`), while OpenRouter and NVIDIA
receive a non-200 from upstream and produce
`502 "provider error: 401"` (`openai_compatible.py:39`).

So the client parses the `detail` string opportunistically:
`provider error: 401|403` becomes "API KEY REJECTED". **On the Gemini path a
bad key is indistinguishable from a provider outage**; that case gets the
generic provider message rather than a guess.

Each condition maps to one `FoodAnalysisException` kind:

| Condition | Surfaced as |
|---|---|
| No `api_key` / `api_provider` in secure storage | "NO API KEY — COMPLETE ONBOARDING" |
| No signed-in `uid` | Guarded client-side, never sent (nginx would 400) |
| nginx `429` | "RATE LIMIT — 10 SCANS/MIN, WAIT A MOMENT" |
| `502 provider error: 401/403` | "API KEY REJECTED" |
| `502` otherwise | "PROVIDER FAILED — RETRY OR ENTER MANUALLY" |
| `502 invalid response from model` | "COULDN'T READ THAT PHOTO — ENTER MANUALLY" |
| `SocketException` / timeout | "CAN'T REACH ANALYSIS SERVICE" |
| Picker returns `null` (user cancelled) | Silent no-op |
| `PlatformException` from picker | "PERMISSION DENIED — ENABLE IN SETTINGS" |

Every failure path offers **manual entry as the fallback**, which is the
payoff of the shared form: a failed scan is one tap from a working log rather
than a dead end.

**Client timeout is 75s, not 15s.** `openai_compatible.py:35` uses
`httpx.AsyncClient(timeout=60)`, so the 15s value `ProfileRepository` uses
would abandon requests the backend is still successfully serving.

**The Firestore write gets no `.timeout()`,** deliberately diverging from
`ProfileRepository.save()`. The SDK queues writes offline and fires the local
snapshot immediately, so an entry appears in history at once and syncs later;
a timeout would throw on a write that is going to succeed.

## Platform prerequisites

Without these, neither flow can run.

**iOS** (`ios/Runner/Info.plist` — currently has `NSHealthShareUsageDescription`
but none of these):

- `NSCameraUsageDescription` — `image_picker` hard-crashes without it
- `NSPhotoLibraryUsageDescription` — same
- `NSAppTransportSecurity` → `NSAllowsLocalNetworking` for
  `http://localhost:8080`

**Android** (`android/app/src/main/AndroidManifest.xml` currently declares only
the three Health Connect permissions):

- `android:usesCleartextTraffic="true"` in a **new
  `android/app/src/debug/AndroidManifest.xml` overlay**, not the main
  manifest. The cleartext URL is a development default, so release builds
  should keep cleartext blocked.

No `CAMERA` permission is needed, because `image_picker` delegates to the
camera app by intent.

## Testing

Existing tests use hand-written in-memory fakes against narrow seams
(`HealthKeyValueStore`, `HealthGateway`) with no mockito. This follows that.

**`test/food_analysis_client_test.dart`** — the highest-value file. Uses
`MockClient` from `package:http/testing.dart` (already available; `http` is a
dependency, so no new dev dep) plus a `FakeCredentialStore` shaped like
`FakeStore`. Pins the routing contract:

- `GEMINI` → `/api/v1/gemini` with `X-Gemini-Key`
- `OPENROUTER` → `/api/v1/openrouter` with `X-Openrouter-Key`
- `'NVIDIA NIM'` → `/api/v1/nvidia` — the space-and-case normalization is the
  single most likely thing to break silently, so it gets its own test
- `X-User-Id` equals the uid on all three
- The multipart field is named `image`
- `429` → rate-limit error; `502 provider error: 401` → key-rejected;
  `502 invalid response from model` → unreadable-photo; `SocketException` →
  unreachable
- A missing key throws **before any HTTP call**, asserted by the `MockClient`
  never being invoked

**`test/food_entry_test.dart`** — pure, mirroring `user_profile_test.dart`:
`Nutrients.fromApi` coercing `null` to `0` (the real `normalize()` output when
a model omits a macro), snake_case-in / camelCase-out round-trip,
`FoodSource.fromWire` defaulting on garbage, quantity scaling getters.

**`test/food_log_grouping_test.dart`** — `groupByDay` with an injected `now`:
the calendar cutoff (an entry at 23:59 three days ago is excluded, one at
00:01 two days ago is included), correct bucketing across a local-midnight
boundary, and stable ordering within a bucket. Pure logic, and the most likely
thing to be subtly wrong.

**`test/food_quantity_stepper_test.dart`** — clamps at `0.5`, steps by `0.5`,
caps at `20`, and the displayed total recomputes.

**`FoodLogRepository` gets no test, deliberately.** Faking the Firestore SDK
would need either a new dev dependency or an abstraction wider than the code
it wraps. Instead the repository stays a humble object — thin SDK calls with
no logic beyond the map conversion, which `food_entry_test.dart` already
covers. This is a named gap, not claimed coverage.

**Acceptance check:** `podman compose up` with a key in `microservice/.env`,
then `flutter run --dart-define=FOOD_API_BASE_URL=http://10.0.2.2:8080`, scan
a photo, confirm the entry lands in history and survives a restart. Plus
`flutter analyze` and `flutter test` clean.

## Known gaps

- **`api_key` cannot be changed after onboarding.** It is only ever written at
  `profile_init_screen.dart:348`; no Settings screen edits it. So
  "API KEY REJECTED" is currently un-actionable without a reinstall. Adding a
  Settings field is the obvious follow-up.
- **A bad Gemini key is indistinguishable from a Gemini outage**, because both
  become `502 "provider request failed"`. Distinguishing them would require a
  microservice change.
- **`FoodLogRepository` is untested**, as described above.
