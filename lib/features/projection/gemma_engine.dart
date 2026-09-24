import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Why the engine could not be installed.
///
/// [code] is the name `GemmaEngineDelivery.kt` gives Play's error, so the model
/// service can tell a network failure from a full disk without parsing prose.
class GemmaEngineException implements Exception {
  const GemmaEngineException(this.code);

  final String code;

  static const String notInstalled = 'NOT_INSTALLED';

  bool get isNetwork => code == 'NETWORK_ERROR';
  bool get isStorage => code == 'INSUFFICIENT_STORAGE';

  @override
  String toString() => 'GemmaEngineException($code)';
}

/// The native inference engine, which on Android arrives separately from the
/// app.
///
/// A Play bundle ships LiteRT-LM as the on-demand `gemma_engine` module, so a
/// user who never downloads the model never downloads the engine either. This is
/// the Dart half of that: whether it is here, fetching it, and making its
/// libraries loadable before flutter_gemma asks for them by name.
///
/// Everywhere else — iOS, and any Android build that is not a bundle — the
/// engine is part of the app, and every method here is a no-op that says so.
abstract class GemmaEngine {
  Future<bool> isInstalled();

  /// Whether an install is running — possibly one started before a restart.
  Future<bool> isInstalling();

  /// Installs the engine, reporting bytes as Play delivers them.
  ///
  /// Throws [GemmaEngineException] when Play cannot.
  Future<void> install({
    required void Function(int downloaded, int total) onProgress,
  });

  /// Makes the engine loadable in this process. Call before any inference.
  Future<void> ensureLoaded();

  /// Lets Play reclaim the engine once nothing needs it.
  Future<void> release();

  /// Bytes free where the model is written, or null where that is unknown.
  Future<int?> freeBytes();
}

class PlatformGemmaEngine implements GemmaEngine {
  PlatformGemmaEngine({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('void_factor/gemma_engine');

  final MethodChannel _channel;

  /// Libraries are process-global, so whether they are loaded is too.
  static bool _loaded = false;

  void Function(int downloaded, int total)? _onProgress;

  bool get _delivered => !kIsWeb && Platform.isAndroid;

  /// Paths to preload, in order. Null when the engine is not installed; empty
  /// when it is in the base APK, where flutter_gemma finds it unaided.
  ///
  /// An Android build without the channel — a test host, an add-to-app embed —
  /// has the engine wherever it always had it, so that also reads as empty.
  Future<List<String>?> _libraryPaths() async {
    try {
      return await _channel.invokeListMethod<String>('libraryPaths');
    } on MissingPluginException {
      return const [];
    }
  }

  @override
  Future<bool> isInstalled() async {
    if (!_delivered) return true;
    return await _libraryPaths() != null;
  }

  @override
  Future<bool> isInstalling() async {
    if (!_delivered) return false;
    try {
      return await _channel.invokeMethod<bool>('installing') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<void> install({
    required void Function(int downloaded, int total) onProgress,
  }) async {
    if (!_delivered) return;
    _onProgress = onProgress;
    _channel.setMethodCallHandler(_onPlatformCall);
    try {
      await _channel.invokeMethod<void>('install');
    } on PlatformException catch (e) {
      throw GemmaEngineException(e.code);
    } on MissingPluginException {
      // No delivery channel means nothing to deliver.
    } finally {
      _onProgress = null;
    }
  }

  Future<void> _onPlatformCall(MethodCall call) async {
    if (call.method != 'progress') return;
    final args = call.arguments;
    if (args is List && args.length == 2) {
      _onProgress?.call((args[0] as num).toInt(), (args[1] as num).toInt());
    }
  }

  @override
  Future<void> ensureLoaded() async {
    if (_loaded || !_delivered) return;
    final paths = await _libraryPaths();
    if (paths == null) {
      throw const GemmaEngineException(GemmaEngineException.notInstalled);
    }
    if (paths.isNotEmpty) _preload(paths);
    _loaded = true;
  }

  /// Loads each library by path, globally, through flutter_gemma's own helper.
  ///
  /// The helper rather than `DynamicLibrary.open` for two reasons. Dart opens
  /// libraries RTLD_LOCAL, and the GPU accelerators find LiteRtLm's symbols only
  /// if it was loaded RTLD_GLOBAL — which is exactly what the plugin itself does
  /// with this same call. And a dlopen issued from a real library resolves in
  /// the app's linker namespace, where the plugin's later open-by-name will look.
  static void _preload(List<String> paths) {
    final proxy = DynamicLibrary.open('libStreamProxy.so');
    final loadGlobal = proxy.lookupFunction<Pointer<Void> Function(Pointer<Utf8>),
        Pointer<Void> Function(Pointer<Utf8>)>('stream_proxy_load_global');
    for (final path in paths) {
      final native = path.toNativeUtf8();
      try {
        if (loadGlobal(native) == nullptr) {
          throw StateError('Could not load $path');
        }
      } finally {
        malloc.free(native);
      }
    }
  }

  @override
  Future<void> release() async {
    if (!_delivered) return;
    try {
      await _channel.invokeMethod<void>('deferredUninstall');
    } on MissingPluginException {
      // Nothing was delivered, so nothing to give back.
    } on PlatformException {
      // Best effort: keeping 20 MB of engine is not worth an error.
    }
  }

  @override
  Future<int?> freeBytes() async {
    if (!_delivered) return null;
    try {
      return await _channel.invokeMethod<int>('freeBytes');
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }
}
