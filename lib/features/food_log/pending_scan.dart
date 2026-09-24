import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

/// A photographed meal that has not been read yet, left by an earlier process.
typedef PendingScan = ({File image, DateTime startedAt});

/// Keeps the photo of a scan in flight on disk until the analysis answers.
///
/// A scan crosses two stretches where Android is free to kill the app: while
/// the camera or the gallery is in front, and while the upload waits on the
/// provider — long enough for the user to switch away. Held only in memory, the
/// photo died with the process and the user came back to a dashboard, the meal
/// they had just photographed gone without a word. Held here, the next launch
/// finds it and finishes the scan.
///
/// One scan at a time, like the vision tab itself: a single photo and a small
/// marker beside it naming whose it is and when it was taken.
class PendingScanStore {
  PendingScanStore({
    Future<Directory> Function()? directory,
    DateTime Function()? clock,
    this.maxAge = const Duration(hours: 1),
  })  : _directory = directory ?? getApplicationSupportDirectory,
        _clock = clock ?? DateTime.now;

  final Future<Directory> Function() _directory;
  final DateTime Function() _clock;

  /// Past this, a leftover scan is dropped rather than resumed. A meal
  /// photographed an hour ago and never confirmed was most likely abandoned,
  /// and opening a form for it out of nowhere would be the surprise.
  final Duration maxAge;

  static const String _folder = 'pending_scan';
  static const String _imageName = 'scan.jpg';
  static const String _markerName = 'scan.json';

  /// The prefix the capture gateway names its compressed copies with.
  static const String tempImagePrefix = 'vf_meal_';

  /// Null when there is nowhere to keep it — a platform without
  /// path_provider, such as a test host — in which case scans simply are not
  /// resumable, exactly as before this existed.
  Future<Directory?> _dir() async {
    try {
      final dir = Directory('${(await _directory()).path}/$_folder');
      await dir.create(recursive: true);
      return dir;
    } catch (_) {
      return null;
    }
  }

  /// Takes [image] into the store and records it as the scan in flight.
  ///
  /// Returns the file to upload: the kept copy, or [image] itself when the
  /// store is unavailable. Moved rather than copied, so a scan never leaves
  /// two copies of a meal photo behind.
  Future<File> hold(File image, {required String? owner}) async {
    final dir = await _dir();
    if (dir == null) return image;

    final kept = File('${dir.path}/$_imageName');
    try {
      if (image.path != kept.path) {
        try {
          await image.rename(kept.path);
        } on FileSystemException {
          // A different filesystem: copy, then drop the original.
          await image.copy(kept.path);
          await _deleteQuietly(image);
        }
      }
      await File('${dir.path}/$_markerName').writeAsString(
        jsonEncode({
          'owner': owner,
          'startedAt': _clock().toIso8601String(),
        }),
        flush: true,
      );
      return kept;
    } on FileSystemException {
      // Not being resumable is no reason to fail a scan that can still run.
      return await kept.exists() ? kept : image;
    }
  }

  /// The scan an earlier process left in flight, if it belongs to [owner] and
  /// is recent enough to resume.
  ///
  /// Anything else found there — another account's photo, a stale one, a
  /// marker without its image — is removed on the way.
  Future<PendingScan?> find({required String? owner}) async {
    final dir = await _dir();
    if (dir == null) return null;

    final image = File('${dir.path}/$_imageName');
    final marker = File('${dir.path}/$_markerName');
    try {
      if (!await image.exists() || !await marker.exists()) {
        await clear();
        return null;
      }
      final decoded = jsonDecode(await marker.readAsString());
      final startedAt = decoded is Map
          ? DateTime.tryParse(decoded['startedAt']?.toString() ?? '')
          : null;
      final heldFor = decoded is Map ? decoded['owner'] : null;
      final fresh = startedAt != null &&
          _clock().difference(startedAt) <= maxAge &&
          !startedAt.isAfter(_clock());
      if (!fresh || heldFor != owner) {
        await clear();
        return null;
      }
      return (image: image, startedAt: startedAt);
    } on FormatException {
      await clear();
      return null;
    } on FileSystemException {
      return null;
    }
  }

  /// Forgets the scan in flight, photo and all. Called once the analysis has
  /// answered either way — a result is in the form, a failure is on screen.
  Future<void> clear() async {
    final dir = await _dir();
    if (dir == null) return;
    await _deleteQuietly(File('${dir.path}/$_imageName'));
    await _deleteQuietly(File('${dir.path}/$_markerName'));
  }

  /// Deletes compressed photos a crash left in the temp directory.
  ///
  /// Only ones older than [olderThan]: a scan being compressed right now
  /// lives there for the second before [hold] takes it.
  static Future<void> sweepStrayTempImages({
    Directory? temp,
    Duration olderThan = const Duration(minutes: 10),
    DateTime Function() clock = DateTime.now,
  }) async {
    final dir = temp ?? Directory.systemTemp;
    try {
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last;
        if (!name.startsWith(tempImagePrefix) || !name.endsWith('.jpg')) {
          continue;
        }
        final modified = await entity.lastModified();
        if (clock().difference(modified) >= olderThan) {
          await _deleteQuietly(entity);
        }
      }
    } on FileSystemException {
      // A temp directory that cannot be listed has nothing we can clean.
    }
  }

  static Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // Already gone, or the OS will reclaim it; neither is worth a failure.
    }
  }
}

final pendingScanStoreProvider = Provider<PendingScanStore>((ref) {
  return PendingScanStore();
});
