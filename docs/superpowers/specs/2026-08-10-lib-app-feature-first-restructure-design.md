# Restructure `lib/app/` feature-first

**Date:** 2026-08-10
**Status:** Approved

## Problem

`lib/app/` is a flat catch-all mixing the app shell (`app.dart`, `routes.dart`)
with feature logic — auth, profile, and health providers/repositories/services.
The rest of the repo groups code by feature (`lib/screens/{auth,dashboard,
settings,...}`), so the flat `lib/app/` is inconsistent and obscures which files
belong together.

## Target structure

```
lib/
  app/                          # app shell only
    app.dart
    routes.dart
  features/
    auth/
      auth_provider.dart
      session_provider.dart
      link_verification_service.dart
    profile/
      profile_repository.dart
    health/
      health_repository.dart
      health_providers.dart
      health_background_service.dart
      health_observer_service.dart
  screens/  models/  widgets/  theme/   # unchanged
```

## Moves

| From | To |
|------|----|
| `lib/app/auth_provider.dart` | `lib/features/auth/auth_provider.dart` |
| `lib/app/session_provider.dart` | `lib/features/auth/session_provider.dart` |
| `lib/app/link_verification_service.dart` | `lib/features/auth/link_verification_service.dart` |
| `lib/app/profile_repository.dart` | `lib/features/profile/profile_repository.dart` |
| `lib/app/health_repository.dart` | `lib/features/health/health_repository.dart` |
| `lib/app/health_providers.dart` | `lib/features/health/health_providers.dart` |
| `lib/app/health_background_service.dart` | `lib/features/health/health_background_service.dart` |
| `lib/app/health_observer_service.dart` | `lib/features/health/health_observer_service.dart` |

`app.dart` and `routes.dart` stay in `lib/app/`.

## Import fixes

**Within moved files** (relative paths that now cross folders):
- `../models/...` → `../../models/...` in `session_provider`, `profile_repository`,
  `health_repository`, `health_providers`.
- `auth_provider.dart`: `health_providers.dart` → `../health/health_providers.dart`.
- `session_provider.dart`: `profile_repository.dart` → `../profile/profile_repository.dart`.
- Same-folder imports (auth↔auth, health↔health) unchanged.

**Shell file that stays** (`app.dart`):
- `link_verification_service.dart` → `../features/auth/link_verification_service.dart`
- `health_providers.dart` → `../features/health/health_providers.dart`
- `routes.dart` and `../theme/...` unchanged.

**Screen importers** (10 files under `lib/screens/*/`): rewrite
`../../app/<file>.dart` → `../../features/<feature>/<file>.dart` for
`auth_provider`, `session_provider`, `profile_repository`, `health_providers`.

**`lib/main.dart`**: `app/health_background_service.dart` →
`features/health/health_background_service.dart` (`app/app.dart` unchanged).

**Tests** (absolute package imports): rewrite
`package:void_factor/app/<file>.dart` → `package:void_factor/features/<feature>/<file>.dart`
for `auth_provider`, `health_providers`, `health_repository`,
`health_observer_service` (`app/app.dart` unchanged).

## Non-goals

- No barrel/`index.dart` files.
- No changes beyond moves + import fixes.

## Verification

`flutter analyze` passes with zero unresolved-import errors.

## Model note

All work done on the current model (Opus 4.8), no delegation.
