# Edit Profile & Goals/Diet — Design

**Date:** 2026-08-02
**Status:** Approved (design), pending implementation plan

## Summary

Add the ability for a signed-in user to view and edit their profile from Settings.
Introduce a new, richer profile schema (goal, target weight, weekly rate, allergies)
on top of the existing physical metrics. Persist the profile to two sinks: the
on-device store (encrypted `flutter_secure_storage`, as a single JSON blob) and
Cloud Firestore (source of truth). Existing users who lack the new fields are
upgraded in place (per-user backfill) without data loss.

The new fields are presented on a **separate settings screen** from the existing
metrics, so each screen is focused and each save is scoped to its own section.

## Goals

- A typed, versioned `UserProfile` model replacing the current stringly-typed
  `Map<String, String>` profile.
- A single persistence path (`ProfileRepository`) used by onboarding, session
  sync, and the new edit screens — no duplicated read/write logic.
- Two Monolith-styled settings screens: edit existing metrics, and edit new
  goal/diet fields.
- Edits write through to Firestore via **`.set(map, SetOptions(merge: true))`**
  (never a full `.set()` overwrite), preserving `sessionId` / `createdAt`.
- Existing users transparently upgraded to the new schema.

## Non-goals

- Editing identity fields (email is the auth identity; display name stays
  read-only in these screens).
- Moving API key / provider into these screens — they keep their existing
  "Rotate API Key" card and their own secure-storage keys.
- A server-side / Admin SDK migration. This is a client-only app; backfill is
  per-user (see Migration).
- Adding a local database dependency (Hive/sqflite). Storage stays in
  `flutter_secure_storage` as JSON.

## Storage decisions (locked)

- **On-device:** whole profile as one JSON blob under a single secure-storage key
  (`profile_json`). No new dependency; keeps encryption-at-rest.
- **Firestore:** remains the source of truth. Document: `users/{uid}`.
- **Schema shape:** typed `UserProfile` Dart model with `schemaVersion`.

## Section 1 — Schema & Model

New file: `lib/models/user_profile.dart`.

Immutable `UserProfile` with `fromMap` / `toMap` / `copyWith`, and a `WeightGoal`
enum.

| Field | Type | Notes / default |
|---|---|---|
| `height` | `double` | cm — existing |
| `weight` | `double` | kg — existing (current weight) |
| `age` | `int` | existing |
| `gender` | `String` | `MALE` / `FEMALE` / `OTHER` — existing, default `MALE` |
| `goal` | `WeightGoal` | `lose` / `maintain` / `gain` — **new**, default `maintain` |
| `targetWeight` | `double` | kg — **new**, default = current `weight` |
| `weeklyRate` | `double` | kg/week — **new**, default `0.5` (options `0.25` / `0.5` / `0.75`) |
| `allergies` | `List<String>` | **new**, default `[]` |

Allergy preset set (multi-select chips):
`Peanuts, Tree nuts, Dairy, Eggs, Gluten, Soy, Shellfish, Fish`.

Serialization:

- `goal` ↔ string (`"lose"` / `"maintain"` / `"gain"`). Parsing is defensive:
  unknown or null → `maintain`.
- `allergies` stored as a native list in Firestore, JSON array in the local blob.
  Values are constrained to the preset set.
- `fromMap` tolerates missing keys and mixed numeric encodings — Firestore may
  return `num`; the legacy local store wrote everything as `String`. So it reads
  both old (v1 loose fields) and new (v2) documents without throwing. This is
  what makes the backfill safe.
- `toMap` includes `schemaVersion: 2` so a future migration can distinguish v1
  from v2.
- `targetWeight` default resolves to current `weight` when the field is absent.

Not in the model (managed elsewhere, preserved via merge writes):
`sessionId`, `createdAt`, `apiKey`, `apiProvider`.

## Section 2 — Persistence layer

New file: `lib/app/profile_repository.dart`. Single source of truth for profile
reads/writes.

- `Future<UserProfile> load()` — read Firestore `users/{uid}`; on failure/offline
  fall back to the local JSON blob; return a `UserProfile` (missing new fields
  filled by defaults via `fromMap`).
- `Future<void> save(UserProfile profile)` — write to **both** sinks:
  - Firestore via **`.set(profile.toMap(), SetOptions(merge: true))`**. Merge is
    required because this same method serves both onboarding (first write —
    `.update()` would throw `not-found` on a doc that doesn't exist yet) and the
    edit screens (later writes). Merge creates-or-updates and leaves fields not
    present in the map — `sessionId` / `createdAt` — intact. This also fixes the
    existing bug where `completeOnboarding` used a full `.set()` (no merge),
    which overwrote the whole document.
  - Local secure storage: one JSON blob under key `profile_json`.
- Backfill helper used by session sync (see Migration).

Design notes:

- Both screens `load()` the full profile, edit their own subset via `copyWith`,
  and `save()`. A partial edit on one screen never clobbers the other screen's
  fields, because save always writes the complete current `UserProfile`.
- `profileProvider` changes from `FutureProvider<Map<String,String>>` to
  `FutureProvider<UserProfile>`, backed by `ProfileRepository.load()`.
- After any save, `ref.invalidate(profileProvider)` (reusing the invalidation
  wiring already added to `AuthFlowNotifier`).

## Section 3 — The two screens

Both in `lib/screens/settings/`, both Monolith-styled (black borders, hard
shadows, uppercase, `MonolithTextField` / `MonolithButton` / `MonolithCard`),
both `ConsumerStatefulWidget`, both with a SAVE button, loading state, and a
snackbar confirmation. Both prefill from `profileProvider`.

**Screen 1 — `EditProfileScreen`** (existing metrics):
height, weight, age, gender selector. Reached from the existing `EDIT PROFILE`
settings tile (currently a no-op `() {}`).

**Screen 2 — `GoalsDietScreen`** (new fields):

- Goal: 3-way selector `LOSE / MAINTAIN / GAIN`.
- Target weight (kg): numeric `MonolithTextField`.
- Weekly rate: selector `0.25 / 0.5 / 0.75 KG/WEEK`.
- Allergies: preset toggle chips, multi-select.

Reached from a new `GOALS & DIET` settings tile.

Validation: numeric fields parsed with `double.tryParse` / `int.tryParse`;
invalid input shows a snackbar and blocks save (mirrors onboarding).

## Section 4 — Wiring & routes

- `routes.dart`: add `/edit-profile` → `EditProfileScreen`, `/goals-diet` →
  `GoalsDietScreen`.
- `settings_screen.dart`: wire `EDIT PROFILE` tile → `/edit-profile`; add a new
  `GOALS & DIET` tile → `/goals-diet`. The profile stat row keeps reading
  `profileProvider` (now a `UserProfile`; access typed fields instead of map
  lookups).
- `session_provider.dart`: `getCachedProfile()` and `completeOnboarding()`
  refactored to go through `ProfileRepository`. `manageSessionAndFlow()` calls
  the backfill helper.
- `profile_init_screen.dart` (onboarding): construct a `UserProfile` on
  completion; new fields take their defaults there (onboarding still collects
  only the original metrics + API key).

## Migration (per-user backfill)

Constraint: this is a **client-side** app. Firestore security rules let a client
write only its own `users/{uid}` doc, so there is no client path to backfill
every user up front. Instead:

- During the existing `SessionService.manageSessionAndFlow()` sync, if the
  signed-in user's doc is missing `schemaVersion` (or the new fields), the
  repository writes the upgraded full-schema doc for **that** user, with
  defaults derived from existing values (`targetWeight` = current `weight`,
  `goal` = `maintain`, `weeklyRate` = `0.5`, `allergies` = `[]`).
- Effect: the whole user base is upgraded as each person next opens the app.
  No data loss; `fromMap` already reads pre-migration docs safely, so even an
  un-upgraded doc renders correctly in the meantime.

## Error handling

- Firestore reads/writes wrapped with the existing 15s timeout pattern; on
  failure, `load()` falls back to the local blob and screens surface a snackbar
  on save failure (as onboarding does today).
- `fromMap` never throws on malformed/missing data — it defaults each field.
- Google/session teardown unaffected.

## Testing

- Unit tests for `UserProfile`:
  - `toMap` / `fromMap` round-trip.
  - Old doc missing new fields → correct defaults (incl. `targetWeight` = weight).
  - `WeightGoal` parsing incl. unknown/null → `maintain`.
  - Mixed numeric encodings (`String` vs `num`) parse correctly.
- Existing `MonolithApp` smoke test stays green (providers it overrides are
  compatible; `profileProvider` type change verified).

## Files touched

New:

- `lib/models/user_profile.dart`
- `lib/app/profile_repository.dart`
- `lib/screens/settings/edit_profile_screen.dart`
- `lib/screens/settings/goals_diet_screen.dart`
- `test/user_profile_test.dart`

Modified:

- `lib/app/routes.dart`
- `lib/app/session_provider.dart`
- `lib/screens/settings/settings_screen.dart`
- `lib/screens/onboarding/profile_init_screen.dart`
