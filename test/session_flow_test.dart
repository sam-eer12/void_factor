import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:void_factor/features/auth/auth_provider.dart';
import 'package:void_factor/features/auth/session_provider.dart';
import 'package:void_factor/models/user_profile.dart';

/// The flow only ever asks whether there is a user, never who it is.
class FakeUser implements User {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// Stands in for the real service, which reaches Firebase Auth and Firestore
/// from its field initialisers and so cannot be built in a unit test at all.
class FakeSessionService implements SessionService {
  FakeSessionService(this.result);

  /// What the next sync resolves to: 'dashboard', 'onboarding' or 'login'.
  String result;

  /// Set to hold a sync open, so the state *during* the check can be observed.
  Completer<void>? gate;

  @override
  Future<String> manageSessionAndFlow() async {
    final held = gate;
    if (held != null) await held.future;
    return result;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  /// Lets the pending microtasks the flow is built from run to completion.
  Future<void> settle() async {
    for (var i = 0; i < 4; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  late FakeSessionService service;
  late ProviderContainer container;
  late List<AuthFlowState> seen;
  late int profileBuilds;

  setUp(() async {
    service = FakeSessionService('dashboard');
    profileBuilds = 0;
    container = ProviderContainer(overrides: [
      authStateProvider.overrideWith((ref) => Stream.value(FakeUser())),
      sessionServiceProvider.overrideWithValue(service),
      profileProvider.overrideWith((ref) async {
        profileBuilds++;
        return const UserProfile(
          height: 180,
          weight: 75,
          age: 30,
          gender: 'male',
          goal: WeightGoal.maintain,
          targetWeight: 75,
          weeklyRate: 0.5,
          allergies: [],
        );
      }),
    ]);
    addTearDown(container.dispose);

    seen = [];
    container.listen(
      authFlowProvider,
      (_, next) => seen.add(next),
      fireImmediately: true,
    );
    // Settings keeps this alive in the app; without a listener an invalidation
    // here would be a silent no-op and prove nothing.
    container.listen(profileProvider, (_, _) {}, fireImmediately: true);

    await settle();
    expect(container.read(authFlowProvider), AuthFlowState.dashboard);
    seen.clear();
  });

  test('a re-check over the dashboard leaves the screen where it is', () async {
    service.gate = Completer<void>();
    final rerun = container.read(authFlowProvider.notifier).checkFlow();
    await settle();

    // AuthGate re-checks on every app resume, and returning from the camera or
    // the photo picker is a resume. Dropping to `loading` here would unmount
    // the shell — taking the in-flight scan's screen with it — and rebuild it
    // at tab 0, which is how a scan used to land the user on the dashboard
    // with nothing to show for it.
    expect(container.read(authFlowProvider), AuthFlowState.dashboard);
    expect(seen, isEmpty);

    service.gate!.complete();
    await rerun;
    expect(container.read(authFlowProvider), AuthFlowState.dashboard);
    expect(seen, isEmpty);
  });

  test('arriving refreshes the profile, a resume that changed nothing does not',
      () async {
    // setUp started watching before the flow settled, so the arrival at the
    // dashboard rebuilt it a second time. That refresh is the point: it is how
    // Settings sees what the session sync just reconciled.
    final afterArrival = profileBuilds;
    expect(afterArrival, greaterThan(1));

    await container.read(authFlowProvider.notifier).checkFlow();
    await settle();

    // Doing it again on every resume would throw a half-filled Edit Profile
    // form back to a spinner for a change that never happened.
    expect(profileBuilds, afterArrival);
  });

  test('a session invalidated elsewhere still sends the user to login',
      () async {
    // Not blanking the screen must not mean not reacting to the answer.
    service.result = 'login';
    await container.read(authFlowProvider.notifier).checkFlow();
    await settle();

    expect(container.read(authFlowProvider), AuthFlowState.login);
    expect(seen, [AuthFlowState.login]);
  });

  test('onboarding is not restarted by a resume mid-form', () async {
    service.result = 'onboarding';
    await container.read(authFlowProvider.notifier).checkFlow();
    await settle();
    seen.clear();

    service.gate = Completer<void>();
    final rerun = container.read(authFlowProvider.notifier).checkFlow();
    await settle();

    // ProfileInitScreen holds the height, weight and age the user has typed in
    // its own state; unmounting it for the length of a Firestore read empties
    // every field.
    expect(container.read(authFlowProvider), AuthFlowState.onboarding);
    expect(seen, isEmpty);

    service.gate!.complete();
    await rerun;
  });

  group('a failed account reload', () {
    test('signs out only for an account that is gone', () {
      for (final code in const [
        'user-not-found',
        'user-disabled',
        'user-token-expired',
        'invalid-user-token',
      ]) {
        expect(
          SessionService.isAccountGone(FirebaseAuthException(code: code)),
          isTrue,
          reason: code,
        );
      }
    });

    test('keeps the session when the phone is only offline', () {
      // This check runs on every resume. Treating a dropped connection as a
      // dead account signed people out — and erased their keys — for opening
      // the app without signal.
      expect(
        SessionService.isAccountGone(
            FirebaseAuthException(code: 'network-request-failed')),
        isFalse,
      );
      expect(
        SessionService.isAccountGone(
            FirebaseAuthException(code: 'too-many-requests')),
        isFalse,
      );
      expect(SessionService.isAccountGone(Exception('socket closed')), isFalse);
    });
  });
}
