import 'dart:async';
import 'package:app_links/app_links.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'auth_provider.dart';

/// Handles a Firebase auth action URL that Android/iOS delivered to the app
/// instead of to a browser.
///
/// Reaching this class at all depends on three things outside it: the App
/// Links intent filter on `/__/auth/action`, a `.well-known/assetlinks.json`
/// the system can actually fetch, and `flutter_deeplinking_enabled=false` —
/// without the last one the engine swallows the intent trying to route the URL
/// as a Navigator path.
class LinkVerificationService {
  final Ref _ref;
  final _appLinks = AppLinks();
  StreamSubscription<Uri>? _linkSubscription;

  LinkVerificationService(this._ref);

  void init(GlobalKey<NavigatorState> navigatorKey) {
    _linkSubscription = _appLinks.uriLinkStream.listen(
      (uri) => _handleIncomingLink(uri, navigatorKey),
      onError: (_) {},
    );
    _checkInitialLink(navigatorKey);
  }

  Future<void> _checkInitialLink(GlobalKey<NavigatorState> navigatorKey) async {
    try {
      final initialUri = await _appLinks.getInitialLink();
      if (initialUri != null) {
        await _handleIncomingLink(initialUri, navigatorKey);
      }
    } catch (_) {}
  }

  Future<void> _handleIncomingLink(
    Uri uri,
    GlobalKey<NavigatorState> navigatorKey,
  ) async {
    final mode = uri.queryParameters['mode'];
    final oobCode = uri.queryParameters['oobCode'];

    if (mode == 'verifyEmail' && oobCode != null) {
      await _verifyAndLogin(oobCode, navigatorKey);
    } else if (mode == 'signIn') {
      await _signInAndContinue(uri, navigatorKey);
    }
    // Any other mode — a password reset, an email-change revocation — belongs
    // to Firebase's own hosted handler, which is where the browser sends it.
    // Doing nothing is correct; guessing would apply a code to the wrong flow.
  }

  Future<void> _verifyAndLogin(
    String oobCode,
    GlobalKey<NavigatorState> navigatorKey,
  ) async {
    final auth = FirebaseAuth.instance;

    try {
      await auth.applyActionCode(oobCode);
    } catch (_) {
      // The usual cause is a code already spent — often by the user's own
      // browser a moment earlier, on this same link. That is a success that
      // arrived twice, not a failure, and the account itself is the arbiter.
      if (!await _isCurrentUserVerified(auth)) {
        _goTo(navigatorKey, '/verify-failed');
        return;
      }
    }

    if (auth.currentUser == null) {
      // The link was confirmed, but this install holds no session to release —
      // the account was created elsewhere, or the app was reinstalled. The
      // address is verified now, so signing in is all that is left.
      _goTo(navigatorKey, '/');
      _say(navigatorKey, 'Email confirmed. Log in to continue.');
      return;
    }

    if (await _isCurrentUserVerified(auth)) {
      _goTo(navigatorKey, '/');
    } else {
      _goTo(navigatorKey, '/verify-failed');
    }
  }

  Future<bool> _isCurrentUserVerified(FirebaseAuth auth) async {
    final user = auth.currentUser;
    if (user == null) return false;
    try {
      await user.reload();
    } catch (_) {
      // Offline: fall back to whatever the cached record says rather than
      // calling a verified account unverified.
    }
    return auth.currentUser?.emailVerified ?? false;
  }

  Future<void> _signInAndContinue(
    Uri uri,
    GlobalKey<NavigatorState> navigatorKey,
  ) async {
    try {
      final user = await _ref
          .read(authControllerProvider.notifier)
          .signInWithLink(uri.toString());

      _goTo(navigatorKey, user != null ? '/' : '/verify-failed');
    } catch (_) {
      _goTo(navigatorKey, '/verify-failed');
    }
  }

  /// Always lands on the gate rather than on a named destination: only the
  /// gate knows whether this user still owes onboarding or has a dashboard to
  /// come back to. Routing straight to '/onboarding' walked returning users
  /// through setup they had already completed.
  void _goTo(GlobalKey<NavigatorState> navigatorKey, String route) {
    navigatorKey.currentState?.pushNamedAndRemoveUntil(route, (_) => false);
  }

  void _say(GlobalKey<NavigatorState> navigatorKey, String message) {
    final context = navigatorKey.currentContext;
    if (context == null) return;
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(SnackBar(content: Text(message)));
  }

  void dispose() {
    _linkSubscription?.cancel();
  }
}

final linkVerificationServiceProvider = Provider<LinkVerificationService>((ref) {
  final service = LinkVerificationService(ref);
  ref.onDispose(() => service.dispose());
  return service;
});
