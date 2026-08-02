# Health Integration (Health Connect / HealthKit) — Design

**Date:** 2026-08-02
**Status:** Approved (design), pending implementation plan

## Summary

Integrate Google Health Connect (Android) and Apple HealthKit (iOS) into the app
to display three **read-only** daily metrics — Steps, Water, and Workout minutes —
on the home (dashboard) screen. Values are read on every app open, on resume, on a
4-minute foreground timer, and refreshed in the background: on iOS via
`HKObserverQuery` + `enableBackgroundDelivery`, on Android via a `workmanager`
periodic task (OS-capped at ~15 min). The user opts in from a new
**Settings → Health Connect** screen; until they do, the cards are dormant.

The dashboard already ships hardcoded Steps / Water / Workout stat cards
(`dashboard_screen.dart:120-165`) and a no-op "HEALTH CONNECT" settings tile
(`settings_screen.dart:204-209`). This feature wires those existing slots to real
data plus the native plumbing.

## Approach (chosen: A)

Use the mature `health` package (carp-dk, v13) for **reads** on both platforms
(permissions, type mapping, unit conversion, aggregation). Layer the real-time
requirements on top natively:

- **iOS:** a thin Swift layer registers `HKObserverQuery` + `enableBackgroundDelivery`
  for the three types and pushes a lightweight "changed" ping to Dart over an
  `EventChannel`. The native layer only *signals*; the actual read stays in Dart.
- **Android:** foreground read on open/resume + a `workmanager` periodic task for
  background refresh.

Rejected alternatives: fully custom native channels on both platforms
(reimplements permissions/mapping/aggregation — weeks of work for three read-only
metrics); `health`-only with no native observer (cannot do iOS background
delivery, which is a stated requirement).

## Goals

- Read-only Steps / Water / Workout on the home page, sourced from Health Connect
  / HealthKit.
- Refresh on **every app open** and on resume to foreground.
- Refresh on a **4-minute foreground timer** (both platforms).
- **iOS:** `HKObserverQuery` + background delivery for push-style updates.
- **Android:** background periodic refresh via `workmanager` (~15 min OS floor).
- User enables/manages sync from **Settings → Health Connect**; disabled by
  default. No health data is read until the user opts in there.
- Cache last-read values for instant display on launch (offline / cold start).

## Non-goals

- **Writing** any data to Health Connect / HealthKit (read-only feature).
- Syncing health metrics to Firestore (device-local only; cache in secure storage).
- Changing the Protein card (`dashboard_screen.dart:156-163`) — it is
  nutrition-sourced, not health-store data.
- Google Fit support (deprecated by Google; the `health` package dropped it in
  v11).
- True <15-minute Android *background* polling — forbidden by the OS (see
  Tradeoffs).

## Units & computation (locked)

All three metrics are **today's totals**, from local midnight to now, reset at
local midnight:

- **Steps** — integer, total step count since midnight.
- **Water** — total hydration logged today, converted to **fl oz** (matches the
  existing `64oz` card). HealthKit/Health Connect report volume in litres/ml;
  convert on read (`1 fl oz = 29.5735 ml`).
- **Workout** — total exercise **minutes** today, summed across all workout
  sessions.

## Storage decisions (locked)

Two new `flutter_secure_storage` keys (following the `profile_json` precedent):

- `health_enabled` — `"true"` once the user enables sync in Settings.
- `health_metrics_json` — cached `HealthMetrics` JSON blob for instant launch
  display.

Both are cleared on logout in `SessionService.clearSession()`, alongside the
existing keys. Health metrics are **never** written to Firestore.

## Section 1 — Data model

New file: `lib/models/health_metrics.dart`.

Immutable `HealthMetrics` value type (the health analog of `UserProfile`):

| Field | Type | Notes |
|---|---|---|
| `steps` | `int` | today's total step count, default `0` |
| `waterOz` | `double` | today's total hydration in fl oz, default `0` |
| `workoutMinutes` | `int` | today's total exercise minutes, default `0` |
| `lastSynced` | `DateTime?` | when last read from the health store; `null` if never |

- `HealthMetrics.empty()` — all zero, `lastSynced: null`.
- `fromMap` / `toMap` — for the secure-storage cache. `fromMap` is defensive like
  `UserProfile.fromMap`: tolerates missing keys and mixed numeric encodings, never
  throws. `lastSynced` serialized as ISO-8601 string.
- `copyWith`.

New enum `HealthConnectionStatus`:

- `disabled` — default; user has not opted in.
- `enabled` — opted in, permissions granted.
- `unavailable` — Health Connect app not installed (Android) / HealthKit not
  present (iOS).

**Why a separate model from `UserProfile`:** health metrics are read-only,
device-sourced, timer-refreshed, and never persisted to Firestore — a wholly
different lifecycle from the user-authored profile. Separate keeps each unit
single-purpose.

## Section 2 — Repository & platform services

### `lib/app/health_repository.dart` — `HealthRepository`

Dart-facing single source of truth, analogous to `ProfileRepository`. Wraps the
`health` package's `Health()` instance. All store access uses the same 15s-timeout
+ try/catch discipline as `ProfileRepository`.

- `Future<HealthConnectionStatus> requestEnable()` — call
  `health.requestAuthorization` for read types `STEPS`, `WATER`, `WORKOUT`; on
  success write `health_enabled = "true"`, return `enabled`; if the platform store
  is absent return `unavailable`.
- `Future<bool> isEnabled()` — read the `health_enabled` flag.
- `Future<void> disable()` — clear `health_enabled` and the cached metrics blob.
- `Future<HealthMetrics> read()` — read today's totals (midnight→now): sum steps,
  sum hydration (→ oz), sum workout durations (→ minutes); stamp
  `lastSynced = now`; write the cache blob; return it. On failure, return the last
  cached blob (or `empty()`).
- `Future<HealthMetrics> loadCached()` — read the cached blob for instant launch
  display; `empty()` if none.

Exposed as `healthRepositoryProvider = Provider<HealthRepository>(...)`.

### iOS observer — `HealthObserverService` (Dart) + Swift

- **Swift** (`ios/Runner/HealthObserver.swift`, wired in `AppDelegate`): for each
  of the three `HKSampleType`s, register an `HKObserverQuery` and call
  `healthStore.enableBackgroundDelivery(for:frequency:.immediate)`. Each observer
  callback emits a "changed" event on an `EventChannel`
  (`app/health_observer`) — it does **not** send data. Call the observer
  completion handler so HealthKit knows delivery succeeded.
- **Dart** `HealthObserverService` exposes `Stream<void> get changes` from the
  `EventChannel`. The controller (Section 3) listens and triggers a
  `HealthRepository.read()` per ping. Registration is invoked only after the user
  enables sync.

### Android background — `workmanager`

- On enable, register one periodic task (~15 min, the OS floor) whose callback
  runs `HealthRepository.read()` so the cache blob stays fresh for the next open.
- On disable, cancel the task.
- The WorkManager callback runs in a background isolate; it constructs its own
  `HealthRepository` (no Riverpod container) and only refreshes the cache.

## Section 3 — Providers, controller & refresh triggers

Providers follow the `profileProvider` / `sessionServiceProvider` precedent:

- `healthRepositoryProvider` — `Provider<HealthRepository>`.
- `healthStatusProvider` — `NotifierProvider<HealthStatusNotifier,
  HealthConnectionStatus>`; reads the persisted flag on build; updated by the
  Settings screen on enable/disable.
- `healthMetricsProvider` — `NotifierProvider<HealthMetricsController,
  HealthMetrics>`; watched by the dashboard cards.

### `HealthMetricsController` (orchestrator)

- `build()` — seed state from `HealthRepository.loadCached()` (instant last-known
  numbers), then kick off a fresh `refresh()` if sync is enabled.
- `refresh()` — call `HealthRepository.read()`, set state to the result. Guarded
  by a **monotonic token** (same pattern as `AuthFlowNotifier._checkToken`) so
  overlapping triggers cannot resolve out of order.
- Owns the **foreground 4-min timer** and the **iOS observer subscription**; both
  created when enabled, torn down on disable / dispose.

### Refresh triggers (full set)

| Trigger | Platform | Mechanism |
|---|---|---|
| App open (cold start) | both | controller `build()` → `refresh()` |
| App resumed to foreground | both | lifecycle listener → `refresh()` |
| Every 4 min foregrounded | both | `Timer.periodic(4 min)` → `refresh()` |
| Health data changed (bg) | iOS | `HKObserverQuery` → EventChannel ping → `refresh()` |
| Every ~15 min in bg | Android | `workmanager` periodic → `read()` updates cache |

App-resume + open uses an `AppLifecycleListener` (or `WidgetsBindingObserver`)
added to `MonolithApp` (already a `ConsumerStatefulWidget`); on `resumed` it calls
`ref.read(healthMetricsProvider.notifier).refresh()`.

## Section 4 — UI

### Dashboard cards (`dashboard_screen.dart:120-165`)

The three existing `MonolithStatCard`s become `ref.watch(healthMetricsProvider)`-
driven, gated on `healthStatusProvider`:

- **Enabled:** live values.
  - Steps → formatted int (`8,432`), subtitle `FROM HEALTH CONNECT` (iOS:
    `FROM APPLE HEALTH`).
  - Water → `64 OZ`, subtitle `AS OF <lastSynced time>`.
  - Workout → `45`, subtitle `MINUTES TODAY`.
- **Disabled (default):** dormant — value `—`, subtitle `CONNECT IN SETTINGS`.
  Tapping a dormant card jumps to Settings → Health Connect via
  `MonolithShell.setActiveTab(context, 3, '/settings')` then the route.
- **Cache-first:** `build()` seeds from cache, so a warm launch shows last numbers
  immediately, then updates in place when `refresh()` returns — no loading flash.

The Protein card stays unchanged (nutrition-sourced, out of scope).

### Settings → Health Connect screen

New file `lib/screens/settings/health_connect_screen.dart`, new route
`/health-connect`. Wire the existing no-op tile (`settings_screen.dart:204-209`)
to it. Monolith-styled (`MonolithCard`, `MonolithButton`, uppercase),
`ConsumerStatefulWidget`, matching the edit-profile screens. Contents:

- **Enable toggle** — off by default. On → `HealthRepository.requestEnable()`
  (fires OS permission prompt), registers iOS observer + Android WorkManager task,
  sets status `enabled`. Off → `disable()` (cancels observer/task, clears cache,
  cards go dormant).
- **Per-type status rows** — STEPS / WATER / WORKOUT: granted / not-granted.
- **RE-SYNC NOW button** — calls `refresh()`, snackbar on completion.
- **Last-synced line** — from `lastSynced`.
- **`unavailable` state** — toggle disabled with a hint (Android: "Install Health
  Connect"; iOS: "Health data unavailable").

## Native configuration

### Android (`android/app/src/main/AndroidManifest.xml` + `build.gradle.kts`)

- Health Connect read permissions:
  `android.permission.health.READ_STEPS`,
  `android.permission.health.READ_HYDRATION`,
  `android.permission.health.READ_EXERCISE`.
- Health Connect permission-rationale intent-filter on an activity
  (`androidx.health.connect.action.SHOW_PERMISSIONS_RATIONALE`) and the
  `<queries>` entry for the Health Connect package
  (`com.google.android.apps.healthdata`).
- Confirm `minSdk` meets Health Connect's requirement (26+); the `health` package
  may require raising `minSdkVersion` — verify against the Flutter-resolved value.
- `workmanager` requires no extra manifest entries beyond its own (bundled).

### iOS (`ios/Runner/Info.plist` + `ios/Runner/Runner.entitlements`)

- `Info.plist`: `NSHealthShareUsageDescription` (read rationale string). No
  `NSHealthUpdateUsageDescription` needed (read-only).
- `Runner.entitlements`: enable **HealthKit** and **HealthKit Background
  Delivery** capabilities (`com.apple.developer.healthkit`,
  `com.apple.developer.healthkit.background-delivery`).
- Deployment target is already 16.0 — sufficient.

## Dependencies

Add to `pubspec.yaml`:

- `health` (carp-dk, v13.x) — HealthKit / Health Connect reads.
- `workmanager` (latest) — Android background periodic refresh.

## Tradeoffs & platform limits

- **"Re-read every 4 min" on Android:** the 4-min timer runs in the **foreground**
  on both platforms. True *background* polling under 15 minutes is not permitted by
  Android (`workmanager` / `WorkManager` minimum periodic interval is 15 min), so
  Android background refresh is ~15 min. iOS gets genuine push-style updates via
  `HKObserverQuery` background delivery. This is a documented OS constraint, not a
  design shortcut.
- **Background isolate reads (Android):** the WorkManager callback refreshes only
  the secure-storage cache; the in-memory provider updates on next open/resume.

## Error handling

- All store reads/writes wrapped with the 15s timeout + try/catch pattern already
  used by `ProfileRepository`; on failure `read()` returns the last cached blob (or
  `empty()`), and the Settings screen surfaces a snackbar on enable/resync failure.
- `HealthMetrics.fromMap` never throws on malformed/missing data — defaults each
  field.
- If permissions are revoked out-of-band (OS settings), the next `read()` yields
  zeros / partial data; the Settings status rows reflect not-granted on next visit.
- Logout teardown: `clearSession()` also clears `health_enabled` +
  `health_metrics_json`; controller cancels timer/observer on dispose.

## Testing

- Unit tests for `HealthMetrics`:
  - `toMap` / `fromMap` round-trip (incl. `lastSynced` null and set).
  - Missing keys → correct defaults.
  - Mixed numeric encodings (`String` vs `num`) parse correctly.
- `HealthRepository` with a mocked `Health()`:
  - `read()` aggregates steps/water/workout into today's totals; ml→oz and
    seconds/duration→minutes conversions correct.
  - `read()` failure falls back to cached blob.
  - `disable()` clears both keys.
- `HealthMetricsController`:
  - monotonic-token guard discards a stale overlapping `refresh()`.
  - dormant when disabled; live when enabled.
- Existing `MonolithApp` smoke test stays green (new providers overridable).

## Files touched

New:

- `lib/models/health_metrics.dart`
- `lib/app/health_repository.dart`
- `lib/app/health_observer_service.dart`
- `lib/app/health_providers.dart` (repository/status/metrics providers + controller)
- `lib/screens/settings/health_connect_screen.dart`
- `ios/Runner/HealthObserver.swift`
- `test/health_metrics_test.dart`
- `test/health_repository_test.dart`

Modified:

- `pubspec.yaml` (add `health`, `workmanager`)
- `lib/app/routes.dart` (add `/health-connect`)
- `lib/app/app.dart` (app-lifecycle resume listener → refresh)
- `lib/app/session_provider.dart` (`clearSession()` clears health keys)
- `lib/screens/dashboard/dashboard_screen.dart` (wire the three cards)
- `lib/screens/settings/settings_screen.dart` (wire the Health Connect tile)
- `android/app/src/main/AndroidManifest.xml` (permissions, queries, rationale)
- `android/app/build.gradle.kts` (minSdk if required)
- `ios/Runner/Info.plist` (`NSHealthShareUsageDescription`)
- `ios/Runner/Runner.entitlements` (HealthKit + background delivery)
- `ios/Runner/AppDelegate.swift` (wire the observer EventChannel)
