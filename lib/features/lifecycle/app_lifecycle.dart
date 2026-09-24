import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The app's lifecycle as the root widget last saw it.
///
/// A provider rather than each feature observing `WidgetsBinding` itself, so
/// logic that cares whether the user is looking — a scan that must not report a
/// failure the user caused only by switching away — can be driven in a test
/// without a binding. `MonolithApp` is the one writer.
class AppLifecycle extends Notifier<AppLifecycleState> {
  @override
  AppLifecycleState build() => AppLifecycleState.resumed;

  void report(AppLifecycleState next) => state = next;
}

final appLifecycleProvider =
    NotifierProvider<AppLifecycle, AppLifecycleState>(AppLifecycle.new);
