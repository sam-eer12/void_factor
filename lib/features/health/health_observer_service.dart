import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Dart side of the iOS HealthKit observer. The native layer registers
/// HKObserverQuery + background delivery and emits a data-changed ping (no
/// payload) on the event channel; this service surfaces those as a `Stream`.
///
/// No-op on Android — the method channel simply has no handler there, and
/// [start]/[stop] swallow the resulting MissingPluginException.
class HealthObserverService {
  static const EventChannel _events =
      EventChannel('app/health_observer/events');
  static const MethodChannel _methods = MethodChannel('app/health_observer');

  Stream<void>? _stream;

  Stream<void> get changes =>
      _stream ??= _events.receiveBroadcastStream().map((_) {});

  Future<void> start() async {
    try {
      await _methods.invokeMethod('startObservers');
    } on MissingPluginException {
      // Android / unsupported platform — nothing to start.
    } on PlatformException {
      // Permission not yet granted; ignored, retried on next enable.
    }
  }

  Future<void> stop() async {
    try {
      await _methods.invokeMethod('stopObservers');
    } on MissingPluginException {
      // Android / unsupported platform — nothing to stop.
    }
  }
}

final healthObserverServiceProvider =
    Provider<HealthObserverService>((ref) => HealthObserverService());
