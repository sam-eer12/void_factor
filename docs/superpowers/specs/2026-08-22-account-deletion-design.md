# Account Deletion

**Date:** 2026-08-22
**Status:** Approved design, ready for implementation planning

## Problem

`settings_screen.dart:280` renders a DANGER ZONE `DELETE ACCOUNT` button whose
`onPressed` is `() {}`. There is no deletion path anywhere in the app: no way
to remove the Firebase Auth user, no way to remove the `users/{uid}` Firestore
document, and no teardown of the on-device data belonging to that user.

The user's instruction draws the line between the two destructive actions:

> delete account deletes it from the firebase and logout just deletes the
> session

So this design covers deletion, and states precisely what logout does and does
not do, because the two are easy to conflate and the difference is now
load-bearing: food logs live on the device
(`2026-08-22-food-logging-design.md`), so "what survives logout" is a real
question with a real answer.

## Scope

**In scope:** the confirmation UI, reauthentication, deletion of the Firebase
Auth user and the `users/{uid}` document, teardown of that uid's on-device
data, background-task cancellation, and navigation back to login.

**Explicitly out of scope:**

- A data export before deletion. The PRIVACY tile
  (`settings_screen.dart:211-216`) is still `() {}`; export belongs there.
- A grace period or soft-delete. Deletion is immediate and unrecoverable.
- Server-side deletion (a Cloud Function on `onDelete`). Nothing in this repo
  deploys functions, and the client can reach everything that needs removing.
- Changing what logout destroys. See [Logout is unchanged](#logout-is-unchanged).

## What exists to delete

Established by reading, not assumed:

**Firebase — `users/{uid}` is the only Firestore path in the entire app.**
`grep` for `collection(` finds four call sites (`session_provider.dart:80,127,166`,
`profile_repository.dart:32`) and all four resolve to
`_db.collection('users').doc(uid)`. There are **no subcollections** — the
`food_logs` subcollection an earlier draft of the food-logging design proposed
was replaced by on-device storage, so it never gets created. One document
delete is therefore complete.

`firebase_storage` is a declared dependency but is never used in `lib/`, and
log entries are text-only by design, so there are no stored files.

**On device:**

| Item | Owner | Cleared by |
|---|---|---|
| `session_id`, `last_activity_time`, `profile_completed` | `SessionService` | `clearSession()` |
| `api_key`, `api_provider` | onboarding / API key screen | `clearSession()` |
| `health_metrics_json`, `health_enabled` | `HealthRepository` | `clearSession()` |
| `profile_json` | `ProfileRepository` | `clearSession()` → `clearLocal()` |
| `email_for_signin`, `name_for_signin` | `AuthController` | **nothing** — see below |
| `food_logs_<uid>.json` | `FoodLogStore` | **nothing** — new work |
| WorkManager `health-refresh-periodic` | `health_background_service.dart` | `cancelHealthRefresh()`, never called on logout |

`clearSession()` covers most of it. Deletion adds the last three rows.

`email_for_signin` / `name_for_signin` are written in `sendPasswordlessLink`
(`auth_provider.dart:86-88`) and deleted in `signInWithLink` on success
(`auth_provider.dart:142-143`), so they linger only when a link was requested
and never completed. Small, but they are an email address left on a device
after the account is gone, so deletion removes them.

## Decisions

| Question | Decision |
|---|---|
| Confirmation | **Typed `DELETE`** in a dialog that lists what is destroyed. |
| Reauthentication | **Unconditional, before anything is destroyed.** |
| Google users | Reauthenticate **in place** via a fresh `GoogleSignIn` credential. |
| Email-link users | **Cannot** reauthenticate in place; told to sign out and back in, then retry. |
| Order | Firestore document **before** the Auth user. |
| Other users' local data | **Untouched.** Only `food_logs_<deletedUid>.json`. |
| Failure handling | Abort on any failure before the Auth delete; report and stay on Settings. |

## Order of operations

The order is the design. Two constraints fix it, and getting either wrong
produces damage that the client cannot repair afterwards.

1. **Confirm** — dialog, typed `DELETE`.
2. **Capture `uid`** into a local variable.
3. **Reauthenticate.**
4. **Delete `users/{uid}`** from Firestore.
5. **`user.delete()`** — the point of no return.
6. **Local teardown** — `clearSession()`, delete `food_logs_<uid>.json`,
   delete the two `*_for_signin` keys, `cancelHealthRefresh()`.
7. **Invalidate** `profileProvider`, `healthMetricsProvider`,
   `healthStatusProvider`, `recentFoodLogProvider`.
8. **Navigate** to `/login` with a cleared stack.

### Why the Firestore delete precedes the Auth delete

Firestore rules for a per-user document require `request.auth.uid == uid`.
Once `user.delete()` succeeds the client holds no credential for that uid ever
again, so a `users/{uid}` document left behind at that moment is **orphaned
permanently** — unreachable by this client and by the user, removable only by
an admin. Reversing steps 4 and 5 converts a recoverable error into a
permanent one.

**Caveat on this reasoning:** there is no `firestore.rules` in the repository
(the only matches are inside `build/` vendor copies), so the rules are managed
in the Firebase console and I could not verify them. If the rules turn out to
permit the delete unauthenticated, this ordering is still correct — merely no
longer load-bearing. If they are as expected, it is essential. Ordering this
way costs nothing either way, which is why it is not worth resolving first.

### Why `uid` is captured before step 5

`user.delete()` clears `FirebaseAuth.instance.currentUser`. The log filename is
`food_logs_<uid>.json`, so a teardown that reads the uid from
`currentUser?.uid` after the delete reads `null` and silently deletes nothing —
leaving the deleted account's meals on disk. The uid must be held in a local
from step 2.

### Why reauthentication is unconditional

Firebase requires a recent login for `delete()` and throws
`requires-recent-login` otherwise, based on session age. Two orders are
possible and only one is safe:

- **Reauth first (chosen).** One code path, and no partial state is reachable:
  every destructive step happens after the step that can fail on the user's
  behalf. Cost: a user who signed in thirty seconds ago still taps through the
  Google account picker.
- **Attempt, catch `requires-recent-login`, reauth, retry.** Avoids the extra
  tap, but the Firestore document is already deleted by then (it has to be, per
  above). A user who cancels the reauth prompt is left with a live account and
  no profile document. That state is survivable — `manageSessionAndFlow()`
  returns `'onboarding'` for a missing document
  (`session_provider.dart:90-92`), so they would be walked through onboarding
  again — but silently discarding a profile because someone changed their mind
  mid-deletion is worse than one extra tap.

For an irreversible operation, predictability wins over tap count.

### Why email-link users are asked to re-login

Reauthenticating an email-link user needs
`EmailAuthProvider.credentialWithLink(email:, emailLink:)`, and that link must
be freshly sent and clicked — the user leaves the app, opens mail, returns
through `app_links`, and the app has meanwhile been relaunched with the
deletion dialog gone. Carrying "was mid-deletion" across that round trip means
persisting deletion intent and resuming from a deep link, which is a
disproportionate amount of new state for this feature.

Provider is read from `user.providerData`: a `google.com` entry means reauth in
place. Otherwise (email-link surfaces as the `password` provider) the dialog
explains that the account must be re-verified and to sign out and sign back in
first. Blunt, but honest and correct, and it does not strand anyone — the path
still exists, it just takes two steps.

## Components

Three files: one new, two rewired.

### `lib/features/auth/account_deletion.dart`

The whole operation, as a small service constructed with injectable
`FirebaseAuth` / `FirebaseFirestore` (matching `ProfileRepository`) plus a
`FoodLogStore` factory and the `SessionService`.

```dart
enum DeletionOutcome { deleted, needsRelogin, reauthCancelled, failed }

class AccountDeletionService {
  Future<DeletionOutcome> deleteAccount();
}
```

Returning an enum rather than throwing keeps the four outcomes explicit at the
call site; only `failed` carries a message. Steps 2-7 above live here, in that
order. It goes in `features/auth/` rather than a new slice because every step
is auth or session teardown, and it needs `SessionService.clearSession()`.

`FoodLogStore` gains a `delete()` method for the log file. It belongs there
next to `readAll`/`writeAll` rather than in the deletion service, which should
not know the filename format.

### `lib/screens/settings/delete_account_dialog.dart`

An `AlertDialog`: what will be destroyed (Firebase account, profile, and *food
logs on this device*, named explicitly since they are the data the user has put
the most work into), a text field, and a DELETE ACCOUNT action enabled only on
an exact `DELETE` match. Styled with `MonolithTheme.error` to match the
existing DANGER ZONE frame.

### Rewires

- `lib/screens/settings/settings_screen.dart` — line 280's `onPressed: () {}`
  opens the dialog, and on `deleted` navigates to `/login` with a cleared
  stack. `needsRelogin` and `failed` surface as a `SnackBar`;
  `reauthCancelled` is a silent no-op, like a cancelled picker.
- `lib/features/auth/auth_provider.dart` — add
  `accountDeletionServiceProvider`. Navigation mirrors `performLogout`
  (`auth_provider.dart:229-233`), whose doc comment records why every teardown
  entry point must clear the stack: screens that only navigated to `/login`
  while leaving state intact "silently re-logged the user back in."

## Logout is unchanged

Reading *"logout just deletes the session"* as **logout must not destroy food
logs** — not as an instruction to strip out logout's existing cache clearing.

Logout today deletes the session keys and the local mirrors of Firebase-backed
data (`health_metrics_json`, `health_enabled`, `profile_json`) specifically so
*"the next user can't read stale data"* (`session_provider.dart:42-47`). That
clearing is correct and stays. Removing it would reintroduce exactly the leak
the code goes out of its way to prevent, and nothing in the instruction asks
for that.

Food logs are outside that set: they are keyed per-uid
(`food_logs_<uid>.json`), so leaving them in place on logout does not expose
them to the next user, and the original user gets their history back on
re-login. Logout needs no change at all to achieve this, since nothing in
`clearSession()` touches those files.

| | Logout | Delete account |
|---|---|---|
| Firebase Auth user | kept | **deleted** |
| `users/{uid}` document | kept | **deleted** |
| Session keys | cleared | cleared |
| API key / provider | cleared | cleared |
| Cached health + profile mirrors | cleared | cleared |
| `food_logs_<uid>.json` | **kept** | **deleted** |
| Other uids' log files | kept | kept |

### One adjacent fix

`cancelHealthRefresh()` documents itself as *"Called on disable / logout"*
(`health_background_service.dart:51`) but logout never calls it — only
`HealthStatusNotifier.disable()` does (`health_providers.dart:46`).
Invalidating the health providers on logout tears down the in-memory `Timer`
and HealthKit observer via `onDispose`, but not the registered WorkManager
periodic task, which survives in the OS scheduler across app restarts.

**It is a hygiene problem, not a leak.** The task's first action is
`if (!await repo.isEnabled()) return true`
(`health_background_service.dart:23`), and `clearSession()` deletes
`health_enabled`, so after logout it wakes every fifteen minutes and no-ops.
No health data is read and nothing is exposed.

Deletion must call it regardless, since the account is gone. Adding the same
one-line call to `signOut()` would make the function match its own
documentation — flagged as an adjacent fix, not folded into this design's
required work.

## Error handling

| Condition | Outcome | Surfaced as |
|---|---|---|
| Typed text is not exactly `DELETE` | — | Action stays disabled |
| Not a `google.com` provider | `needsRelogin` | "SIGN OUT AND SIGN IN AGAIN, THEN RETRY" |
| User dismisses the Google picker | `reauthCancelled` | Silent no-op |
| Reauth returns a different Google account (`user-mismatch`) | `failed` | "THAT'S A DIFFERENT ACCOUNT" |
| Reauth fails otherwise | `failed` | "COULDN'T VERIFY IT'S YOU — TRY AGAIN" |
| Firestore delete fails (offline) | `failed` | "COULDN'T REACH THE SERVER — TRY AGAIN" |
| `user.delete()` throws `requires-recent-login` | `failed` | "VERIFICATION EXPIRED — TRY AGAIN" |
| Local teardown throws after a successful `user.delete()` | `deleted` | Proceed; see below |

**Anything failing before step 5 aborts and leaves the account intact.** The
user stays on Settings with a message and can retry. Since reauth precedes both
deletes, the common failure (stale session) costs nothing.

**A local-teardown failure after step 5 does not fail the deletion.** The
account is already gone; there is nothing to retry and nothing the user can act
on. Reporting failure would imply the account survived. Each teardown step is
attempted independently so one failure cannot skip the others, and the flow
continues to `/login`. The residue is stale bytes belonging to an
authentication that no longer exists.

**`requires-recent-login` at step 5 is reachable despite step 3**, if reauth
succeeded but the account is deleted much later in a paused app. The Firestore
document is already gone at that point, so the outcome is the survivable
onboarding state described above — which is the reason `manageSessionAndFlow()`
handling a missing document (`session_provider.dart:90-92`) is worth knowing
about rather than treating as an edge case.

## Testing

Following the existing hand-written-fake style (`test/health_repository_test.dart`),
against `test/account_deletion_test.dart`.

Firestore and `FirebaseAuth` cannot be faked without either a new dev
dependency or an abstraction wider than the code it wraps — the same reason
noted for other SDK-adjacent code. So the service is built over two narrow
seams it owns rather than over the SDKs directly: a `remoteDelete` callback and
an `authDelete` callback, both injected. This is not ceremony; the **order** is
the thing this design gets right and it is the one thing worth pinning in a
test:

- `remoteDelete` is called **before** `authDelete` — asserted by both fakes
  appending to a shared ordered list. This is the test that matters.
- The uid handed to the log-file delete is the pre-deletion uid, asserted with
  an `authDelete` fake that nulls the current user when it runs.
- `remoteDelete` throwing ⇒ `authDelete` is **never** called, and the outcome
  is `failed`.
- Reauth returning cancelled ⇒ neither delete is called.
- A non-`google.com` provider ⇒ `needsRelogin`, and nothing is called.
- A throwing log-file delete still yields `deleted`, and the remaining teardown
  steps still run.

**`test/food_log_store_test.dart`** (from the food-logging design) gains one
case: `delete()` removes only the calling uid's file and leaves another uid's
file present. That is the per-uid guarantee stated in the table above, and it
is cheap to assert with real temp-directory IO.

The dialog gets no test — an enabled/disabled button driven by an exact string
match is not where this feature's risk lives.

**Acceptance check:** create a throwaway Google account, onboard, log food,
delete the account, then confirm in the Firebase console that both the Auth
user and the `users/{uid}` document are gone; confirm the app is at `/login`;
sign in as a *different* user and confirm no leftover logs are visible. Then
sign in as a *second* throwaway, log food, log out, log back in, and confirm
the logs are still there — the logout half of the table. Plus `flutter analyze`
and `flutter test` clean.

## Known gaps

- **Deleting a Firestore document does not delete its subcollections.** There
  are none today, which is what makes a single `.delete()` complete. If one is
  ever added under `users/{uid}`, this design silently becomes incomplete and
  starts orphaning data — the failure is invisible from the client. A server-side
  `onDelete` function is the durable answer if that day comes.
- **Email-link users need two steps** (sign out, sign in, delete) where Google
  users need one. Closing that gap means persisting deletion intent across a
  deep-link round trip.
- **No export before deletion**, so deletion is the only way out and it takes
  everything with it. The PRIVACY tile is the natural home.
- **A local-teardown failure leaves residue** with no retry, as described in
  [Error handling](#error-handling). Bounded and inert — orphaned bytes tied to
  an authentication that no longer exists.
- **The Firestore rules were not verifiable from this repository**, so the
  ordering rationale rests on the conventional per-user rule rather than on a
  file I read.
