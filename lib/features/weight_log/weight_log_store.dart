import 'dart:convert';
import 'dart:io';

import '../../models/weight_entry.dart';

/// Reads and writes one user's weight history as a JSON file on the device.
///
/// A structural twin of `FoodLogStore`, for the same reasons: the history is
/// per-device data with no cross-device or offline-sync requirement, and
/// `users/{uid}` is the only Firestore document the app owns. Not secure
/// storage either — a body weight is personal but it is not a credential, and
/// the payload grows without bound.
///
/// The one place the app *does* mirror a weight to Firestore is
/// `UserProfile.weight`, which holds the single latest value because BMR needs
/// it. The series itself stays here. See `WeightLog.add` for that write-through.
///
/// Named a Store rather than a Repository because there is no remote half.
///
/// The whole file is rewritten on every change. [readAll]/[writeAll] are the
/// only operations; there is no `add(entry)`, because a read-modify-write inside
/// the store would race with the caller's own in-memory list. The caller holds
/// the list and hands back the complete new state.
class WeightLogStore {
  /// Envelope version, separate from each entry's own `schemaVersion`. A wrapper
  /// object rather than a bare array leaves room to add fields without
  /// reinterpreting existing files.
  static const int currentSchemaVersion = 1;

  WeightLogStore({required Directory dir, required String uid})
      : _dir = dir,
        _uid = uid;

  final Directory _dir;
  final String _uid;

  /// One file per uid — the mechanism that makes keeping history across a logout
  /// safe: the next user on the device reads a different path, so there is no
  /// shared file to filter and no way to leak a prior user's weights.
  File get file => File('${_dir.path}/weight_logs_$_uid.json');

  File get _tempFile => File('${file.path}.tmp');

  /// Every entry the file holds, in stored order.
  ///
  /// Never throws. A history that cannot be read comes back empty, because
  /// failing to open the screen is a worse outcome than showing nothing: the
  /// file is the only copy, so there is no repair path the user could take from
  /// an error.
  Future<List<WeightEntry>> readAll() async {
    try {
      if (!await file.exists()) return const [];
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) return const [];
      final rawEntries = decoded['entries'];
      if (rawEntries is! List) return const [];

      final entries = <WeightEntry>[];
      for (final raw in rawEntries) {
        if (raw is! Map<String, dynamic>) continue;
        final entry = WeightEntry.tryFromMap(raw);
        // A single unplottable point costs that point, not the rest of the
        // series — and dropping it is what keeps the regression honest.
        if (entry != null) entries.add(entry);
      }
      return entries;
    } on FormatException {
      return const [];
    } on FileSystemException {
      return const [];
    }
  }

  /// Replaces the file with exactly [entries].
  ///
  /// Written to a temp file and renamed into place. `rename` is atomic within a
  /// filesystem, so an interruption leaves either the old complete file or the
  /// new one — never a half-written history, which [readAll] would have to
  /// discard in full.
  Future<void> writeAll(List<WeightEntry> entries) async {
    if (!await _dir.exists()) {
      await _dir.create(recursive: true);
    }
    final payload = jsonEncode({
      'schemaVersion': currentSchemaVersion,
      'entries': entries.map((e) => e.toMap()).toList(),
    });
    await _tempFile.writeAsString(payload, flush: true);
    await _tempFile.rename(file.path);
  }

  /// Erases this user's history. Called on account deletion, never on logout.
  ///
  /// Removes the temp file too: a stale one holds the same measurements the user
  /// asked to erase.
  Future<void> delete() async {
    for (final target in [file, _tempFile]) {
      try {
        if (await target.exists()) await target.delete();
      } on FileSystemException {
        // Already gone, or unreadable. Either way there is nothing to retry and
        // account deletion must not stall on it.
      }
    }
  }
}
