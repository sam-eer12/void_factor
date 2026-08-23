import 'package:firebase_auth/firebase_auth.dart';

/// How a deletion attempt ended.
///
/// An enum rather than an exception so all four endings are visible at the call
/// site — one of them ([reauthCancelled]) is not an error at all, and treating a
/// user changing their mind as a thrown failure invites a message they should
/// never see.
enum DeletionOutcome {
  /// The account is gone. Irreversible.
  deleted,

  /// The account can only be deleted after a fresh sign-in — see
  /// [AccountDeletionService.needsReloginMessage].
  needsRelogin,

  /// The user dismissed the reauthentication prompt. Nothing was touched.
  reauthCancelled,

  /// Nothing was destroyed, or the account outlived a partial attempt. Carries
  /// the message to show.
  failed,
}

/// A [DeletionOutcome] plus, for [DeletionOutcome.failed], the words to show.
///
/// Only `failed` varies in what it has to say; the other three either need no
/// message or have a fixed one, so `message` is null for them.
typedef DeletionResult = ({DeletionOutcome outcome, String? message});

/// What came back from asking the user to prove who they are.
///
/// Classified by the caller that owns the sign-in SDK, so this service never has
/// to know how Google reports a dismissed picker.
enum ReauthResult { confirmed, cancelled, wrongAccount, failed }

/// Deletes the account: the Firestore document, the auth user, and every trace
/// of that uid on this device.
///
/// Built over injected callbacks rather than over `FirebaseAuth` and
/// `FirebaseFirestore` directly. Neither can be faked without a new dev
/// dependency or an abstraction wider than the code it wraps, and the thing most
/// worth testing here is the **order** — which is exactly what narrow seams make
/// testable.
///
/// Each teardown step is a separate seam for the same reason: a step that throws
/// must not take the remaining ones with it.
class AccountDeletionService {
  AccountDeletionService({
    required String? Function() currentUid,
    required List<String> Function() providerIds,
    required Future<ReauthResult> Function() reauthenticate,
    required Future<void> Function(String uid) remoteDelete,
    required Future<void> Function() authDelete,
    required Future<void> Function(String uid) deleteLogFile,
    required Future<void> Function() clearSession,
    required Future<void> Function() clearSignInHints,
    required Future<void> Function() cancelBackgroundWork,
  })  : _currentUid = currentUid,
        _providerIds = providerIds,
        _reauthenticate = reauthenticate,
        _remoteDelete = remoteDelete,
        _authDelete = authDelete,
        _deleteLogFile = deleteLogFile,
        _clearSession = clearSession,
        _clearSignInHints = clearSignInHints,
        _cancelBackgroundWork = cancelBackgroundWork;

  final String? Function() _currentUid;
  final List<String> Function() _providerIds;
  final Future<ReauthResult> Function() _reauthenticate;
  final Future<void> Function(String uid) _remoteDelete;
  final Future<void> Function() _authDelete;
  final Future<void> Function(String uid) _deleteLogFile;
  final Future<void> Function() _clearSession;
  final Future<void> Function() _clearSignInHints;
  final Future<void> Function() _cancelBackgroundWork;

  /// The only provider that can be reauthenticated without leaving the app.
  static const String reauthableProvider = 'google.com';

  /// Shown for [DeletionOutcome.needsRelogin]. Fixed, so it is a constant here
  /// rather than a message on the result.
  static const String needsReloginMessage =
      'SIGN OUT AND SIGN IN AGAIN, THEN RETRY';

  static const String errorNotSignedIn = 'NOT SIGNED IN — LOG IN AGAIN';
  static const String errorWrongAccount = "THAT'S A DIFFERENT ACCOUNT";
  static const String errorReauthFailed =
      "COULDN'T VERIFY IT'S YOU — TRY AGAIN";
  static const String errorServerUnreachable =
      "COULDN'T REACH THE SERVER — TRY AGAIN";
  static const String errorVerificationExpired = 'VERIFICATION EXPIRED — TRY AGAIN';
  static const String errorDeleteFailed =
      "COULDN'T DELETE THE ACCOUNT — TRY AGAIN";

  /// Runs the whole deletion. Safe to call again after any [DeletionOutcome]
  /// other than [DeletionOutcome.deleted].
  Future<DeletionResult> deleteAccount() async {
    // Held in a local for the rest of the method. A successful auth delete
    // clears `currentUser`, and the log file is named for the uid — read it back
    // from the SDK afterwards and the teardown silently erases nothing, leaving
    // the deleted account's meals on disk.
    final uid = _currentUid();
    if (uid == null) {
      return (outcome: DeletionOutcome.failed, message: errorNotSignedIn);
    }

    if (!_providerIds().contains(reauthableProvider)) {
      // An email-link user would have to leave for their inbox and come back to
      // a relaunched app, so they are asked to re-sign-in first instead.
      return (outcome: DeletionOutcome.needsRelogin, message: null);
    }

    // Unconditional, and before anything is destroyed: every step that can fail
    // on the user's behalf happens while the account is still intact.
    switch (await _reauthenticate()) {
      case ReauthResult.confirmed:
        break;
      case ReauthResult.cancelled:
        return (outcome: DeletionOutcome.reauthCancelled, message: null);
      case ReauthResult.wrongAccount:
        return (outcome: DeletionOutcome.failed, message: errorWrongAccount);
      case ReauthResult.failed:
        return (outcome: DeletionOutcome.failed, message: errorReauthFailed);
    }

    // Before the auth user, always. The per-user Firestore rule needs a
    // credential for this uid, and after the auth delete no such credential can
    // ever exist again — a document left here would be orphaned permanently,
    // removable only by an admin.
    try {
      await _remoteDelete(uid);
    } catch (_) {
      return (outcome: DeletionOutcome.failed, message: errorServerUnreachable);
    }

    // The point of no return.
    try {
      await _authDelete();
    } on FirebaseAuthException catch (error) {
      // Reachable despite the reauth above if the app sat paused in between.
      // The document is already gone, which leaves the account in the state
      // `manageSessionAndFlow()` treats as needing onboarding — survivable, and
      // the user can retry.
      return (
        outcome: DeletionOutcome.failed,
        message: error.code == 'requires-recent-login'
            ? errorVerificationExpired
            : errorDeleteFailed,
      );
    } catch (_) {
      return (outcome: DeletionOutcome.failed, message: errorDeleteFailed);
    }

    await _tearDownLocalData(uid);
    return (outcome: DeletionOutcome.deleted, message: null);
  }

  /// Everything after the point of no return.
  ///
  /// Each step is attempted independently, and a failure is swallowed rather
  /// than reported: the account is already gone, so there is nothing to retry
  /// and nothing the user could act on. Reporting failure here would imply the
  /// account survived. What is left behind is inert — bytes belonging to an
  /// authentication that no longer exists.
  Future<void> _tearDownLocalData(String uid) async {
    for (final step in [
      () => _deleteLogFile(uid),
      _clearSession,
      _clearSignInHints,
      _cancelBackgroundWork,
    ]) {
      try {
        await step();
      } catch (_) {
        // Deliberately continues to the next step.
      }
    }
  }
}
