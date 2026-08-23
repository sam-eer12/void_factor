import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:void_factor/features/auth/account_deletion.dart';

void main() {
  // Every seam appends to this, so a test can assert both what ran and the order
  // it ran in. The order is the part of this design that cannot be repaired
  // afterwards, so it is the part worth pinning down.
  late List<String> calls;
  late String? currentUid;
  late List<String> torndownUids;

  setUp(() {
    calls = [];
    currentUid = 'uid-1';
    torndownUids = [];
  });

  AccountDeletionService service({
    List<String> providerIds = const ['google.com'],
    ReauthResult reauth = ReauthResult.confirmed,
    Object? remoteDeleteThrows,
    Object? authDeleteThrows,
    Object? logDeleteThrows,
    Object? clearSessionThrows,
  }) {
    return AccountDeletionService(
      currentUid: () => currentUid,
      providerIds: () => providerIds,
      reauthenticate: () async {
        calls.add('reauth');
        return reauth;
      },
      remoteDelete: (uid) async {
        calls.add('remoteDelete:$uid');
        if (remoteDeleteThrows != null) throw remoteDeleteThrows;
      },
      authDelete: () async {
        calls.add('authDelete');
        if (authDeleteThrows != null) throw authDeleteThrows;
        // Firebase clears `currentUser` on a successful delete, so anything
        // reading the uid from the SDK after this point reads null.
        currentUid = null;
      },
      deleteLogFile: (uid) async {
        calls.add('deleteLogFile:$uid');
        torndownUids.add(uid);
        if (logDeleteThrows != null) throw logDeleteThrows;
      },
      clearSession: () async {
        calls.add('clearSession');
        if (clearSessionThrows != null) throw clearSessionThrows;
      },
      clearSignInHints: () async => calls.add('clearSignInHints'),
      cancelBackgroundWork: () async => calls.add('cancelBackgroundWork'),
    );
  }

  group('order of operations', () {
    test('deletes the profile document before the auth user', () async {
      await service().deleteAccount();

      // Reversing these two orphans the document permanently: once the auth user
      // is gone the client never holds a credential for that uid again, and the
      // per-user Firestore rule needs one.
      expect(
        calls.indexOf('remoteDelete:uid-1'),
        lessThan(calls.indexOf('authDelete')),
      );
    });

    test('reauthenticates before anything is destroyed', () async {
      await service().deleteAccount();

      expect(calls.first, 'reauth');
    });

    test('tears down local data only once the account is gone', () async {
      await service().deleteAccount();

      final authDelete = calls.indexOf('authDelete');
      for (final step in [
        'deleteLogFile:uid-1',
        'clearSession',
        'clearSignInHints',
        'cancelBackgroundWork',
      ]) {
        expect(calls.indexOf(step), greaterThan(authDelete), reason: step);
      }
    });

    test('reports a completed deletion with nothing to say', () async {
      final result = await service().deleteAccount();

      expect(result.outcome, DeletionOutcome.deleted);
      expect(result.message, isNull);
    });
  });

  group('the uid it tears down', () {
    test('is the one captured before the delete', () async {
      await service().deleteAccount();

      // Read from the SDK afterwards this would be null, and the log file — named
      // for the uid — would survive the account that owned it.
      expect(torndownUids, ['uid-1']);
    });

    test('refuses when nobody is signed in', () async {
      currentUid = null;

      final result = await service().deleteAccount();

      expect(result.outcome, DeletionOutcome.failed);
      expect(result.message, AccountDeletionService.errorNotSignedIn);
      expect(calls, isEmpty);
    });
  });

  group('who may delete in place', () {
    test('an email-link account is asked to sign in again', () async {
      // Reauthenticating one needs a freshly sent link, which means leaving the
      // app and coming back to a relaunched process with the dialog gone.
      final result = await service(providerIds: const ['password'])
          .deleteAccount();

      expect(result.outcome, DeletionOutcome.needsRelogin);
      expect(calls, isEmpty);
    });

    test('an account with no provider at all is asked to sign in again',
        () async {
      final result = await service(providerIds: const []).deleteAccount();

      expect(result.outcome, DeletionOutcome.needsRelogin);
    });

    test('a Google account among several providers may proceed', () async {
      final result =
          await service(providerIds: const ['password', 'google.com'])
              .deleteAccount();

      expect(result.outcome, DeletionOutcome.deleted);
    });
  });

  group('failures before the point of no return', () {
    test('a cancelled reauthentication destroys nothing', () async {
      final result =
          await service(reauth: ReauthResult.cancelled).deleteAccount();

      expect(result.outcome, DeletionOutcome.reauthCancelled);
      // Like backing out of a picker: a deliberate choice, so nothing is said.
      expect(result.message, isNull);
      expect(calls, ['reauth']);
    });

    test('a different Google account is refused by name', () async {
      final result =
          await service(reauth: ReauthResult.wrongAccount).deleteAccount();

      expect(result.outcome, DeletionOutcome.failed);
      expect(result.message, AccountDeletionService.errorWrongAccount);
      expect(calls, ['reauth']);
    });

    test('a reauthentication that fails otherwise is reported', () async {
      final result = await service(reauth: ReauthResult.failed).deleteAccount();

      expect(result.outcome, DeletionOutcome.failed);
      expect(result.message, AccountDeletionService.errorReauthFailed);
      expect(calls, ['reauth']);
    });

    test('a failed document delete leaves the account intact', () async {
      final result =
          await service(remoteDeleteThrows: Exception('offline')).deleteAccount();

      expect(result.outcome, DeletionOutcome.failed);
      expect(result.message, AccountDeletionService.errorServerUnreachable);
      // The user can retry. Deleting the auth user here would have stranded the
      // document forever.
      expect(calls, isNot(contains('authDelete')));
      expect(calls, isNot(contains('clearSession')));
    });
  });

  group('failures at the delete itself', () {
    test('a credential that went stale is reported as expired', () async {
      final result = await service(
        authDeleteThrows: FirebaseAuthException(code: 'requires-recent-login'),
      ).deleteAccount();

      expect(result.outcome, DeletionOutcome.failed);
      expect(result.message, AccountDeletionService.errorVerificationExpired);
      // The account survives, so the session it is using has to survive too.
      expect(calls, isNot(contains('clearSession')));
    });

    test('any other delete failure is reported', () async {
      final result =
          await service(authDeleteThrows: Exception('boom')).deleteAccount();

      expect(result.outcome, DeletionOutcome.failed);
      expect(result.message, AccountDeletionService.errorDeleteFailed);
    });
  });

  group('teardown after the account is gone', () {
    test('clears every trace the account left on the device', () async {
      await service().deleteAccount();

      expect(
        calls,
        containsAll([
          'deleteLogFile:uid-1',
          'clearSession',
          'clearSignInHints',
          'cancelBackgroundWork',
        ]),
      );
    });

    test('a log file it cannot delete does not fail the deletion', () async {
      final result =
          await service(logDeleteThrows: Exception('read-only')).deleteAccount();

      // The account is already gone: there is nothing to retry and reporting
      // failure would imply it survived.
      expect(result.outcome, DeletionOutcome.deleted);
    });

    test('one failing teardown step does not skip the others', () async {
      await service(logDeleteThrows: Exception('read-only')).deleteAccount();

      expect(
        calls,
        containsAll(['clearSession', 'clearSignInHints', 'cancelBackgroundWork']),
      );
    });

    test('a failing session clear does not skip the others either', () async {
      final result = await service(clearSessionThrows: Exception('locked'))
          .deleteAccount();

      expect(result.outcome, DeletionOutcome.deleted);
      expect(calls, containsAll(['clearSignInHints', 'cancelBackgroundWork']));
    });
  });
}
