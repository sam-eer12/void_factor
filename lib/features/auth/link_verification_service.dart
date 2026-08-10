import 'dart:async';
import 'package:app_links/app_links.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'auth_provider.dart';

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
  }

  Future<void> _verifyAndLogin(
    String oobCode,
    GlobalKey<NavigatorState> navigatorKey,
  ) async {
    final auth = FirebaseAuth.instance;
    try {
      await auth.applyActionCode(oobCode);
      User? user = auth.currentUser;
      if (user != null) {
        await user.reload();
        user = auth.currentUser;

        if (user != null && user.emailVerified) {
          navigatorKey.currentState?.pushNamedAndRemoveUntil(
            '/onboarding',
            (route) => false,
          );
        } else {
          navigatorKey.currentState?.pushNamedAndRemoveUntil(
            '/verify-failed',
            (route) => false,
          );
        }
      }
    } catch (e) {
      navigatorKey.currentState?.pushNamedAndRemoveUntil(
        '/verify-failed',
        (route) => false,
      );
    }
  }

  Future<void> _signInAndContinue(
    Uri uri,
    GlobalKey<NavigatorState> navigatorKey,
  ) async {
    try {
      final user = await _ref
          .read(authControllerProvider.notifier)
          .signInWithLink(uri.toString());

      if (user != null) {
        navigatorKey.currentState?.pushNamedAndRemoveUntil(
          '/onboarding',
          (route) => false,
        );
      } else {
        navigatorKey.currentState?.pushNamedAndRemoveUntil(
          '/verify-failed',
          (route) => false,
        );
      }
    } catch (_) {
      navigatorKey.currentState?.pushNamedAndRemoveUntil(
        '/verify-failed',
        (route) => false,
      );
    }
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
