import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import '../../models/food_entry.dart';

/// Reads and writes one user's food log as a JSON file on the device.
///
/// Deliberately not Firestore: the log is per-device convenience data with no
/// cross-device or offline-sync requirement, and `users/{uid}` is the only
/// Firestore document the app owns. Deliberately not secure storage either —
/// meals are not secrets, and the payload grows without bound.
///
/// Named a Store rather than a Repository because there is no remote half.
///
/// [readAll]/[writeAll] are the only operations; there is no `add(entry)`,
/// because a read-modify-write inside the store would race with the caller's
/// own in-memory list. The caller holds the list and hands back the complete
/// new state.
///
/// ## On disk
///
/// A snapshot — the whole log, rewritten atomically — plus a journal of the
/// single-entry changes made since, one JSON line each. The log only grows, so
/// rewriting all of it for every meal logged would cost a year of meals to save
/// one; appending a line costs the meal. [writeAll] works out which of the two a
/// change needs by comparing it with the list it last read or wrote: one entry
/// added, removed or edited is a line, anything else — an import, a first write
/// — is a snapshot. Every [maxJournalOps] lines the journal is folded into a new
/// snapshot, so neither file grows without bound.
///
/// Each snapshot names the journal generation that follows it, and a journal is
/// only ever replayed onto the snapshot that names it. A crash between writing a
/// new snapshot and deleting the old journal therefore leaves an orphan the
/// next read ignores and removes, never a change applied twice.
class FoodLogStore {
  /// Envelope version, separate from each entry's own `schemaVersion`. A wrapper
  /// object rather than a bare array leaves room to add fields without
  /// reinterpreting existing files — which is how `journal` was added.
  static const int currentSchemaVersion = 1;

  /// Journal lines kept before they are folded into a new snapshot.
  static const int maxJournalOps = 256;

  /// Past this, a snapshot is parsed on a background isolate. About a year and
  /// a half of meals: small enough that nobody waits on it before then, and
  /// the frame that reads it at launch never stalls after.
  static const int backgroundParseBytes = 512 * 1024;

  /// The same threshold, counted in entries, for encoding.
  static const int backgroundEncodeEntries = 2000;

  FoodLogStore({required Directory dir, required String uid})
      : _dir = dir,
        _uid = uid;

  final Directory _dir;
  final String _uid;

  /// Whose log this is.
  String get uid => _uid;

  /// One file per uid. This is the mechanism that makes keeping logs across a
  /// logout safe: the next user on the device reads a different path, so there
  /// is no shared file to filter and no way to leak a prior user's meals.
  File get file => File('${_dir.path}/food_logs_$_uid.json');

  File get _tempFile => File('${file.path}.tmp');

  String get _journalPrefix => 'food_logs_$_uid.';
  static const String _journalSuffix = '.journal';

  File _journalFile(int generation) =>
      File('${_dir.path}/$_journalPrefix$generation$_journalSuffix');

  /// What is on disk, as far as this instance knows: the list, the journal
  /// generation after the snapshot, and how many lines that journal holds.
  ///
  /// Null until a read or write has established it — and after anything that
  /// leaves it uncertain, such as a snapshot that would not parse — in which
  /// case the next write is a whole snapshot rather than a line on top of
  /// something unknown.
  List<FoodEntry>? _baseline;
  int _generation = 0;
  int _journalOps = 0;

  /// Every entry the file holds, in stored order.
  ///
  /// Never throws. A log that cannot be read comes back empty, because failing
  /// to open the screen is a worse outcome than showing nothing: the file is the
  /// only copy, so there is no repair path the user could take from an error.
  Future<List<FoodEntry>> readAll() async {
    _baseline = null;
    try {
      if (!await file.exists()) {
        // Nothing logged yet. The baseline stays unknown, so the first write
        // lays down a snapshot for later lines to build on — a journal is only
        // ever read against the snapshot that names it.
        await _removeOrphanJournals(keep: -1);
        return const [];
      }
      final snapshot = await _readSnapshot();
      if (snapshot == null) return const [];
      final (entries, generation) = snapshot;

      final ops = await _readJournal(generation);
      for (final op in ops) {
        _apply(entries, op);
      }
      await _removeOrphanJournals(keep: generation);

      _generation = generation;
      _journalOps = ops.length;
      _baseline = List.unmodifiable(entries);
      return entries;
    } on FileSystemException {
      return const [];
    }
  }

  /// The snapshot's entries and the journal generation it names, or null when
  /// the file is not a log at all.
  Future<(List<FoodEntry>, int)?> _readSnapshot() async {
    final length = await file.length();
    final raw = await file.readAsString();
    // Parsed where the size says it is worth an isolate. The result comes back
    // without a copy — Isolate.run hands over what the worker built.
    return length > backgroundParseBytes
        ? Isolate.run(() => _decodeSnapshot(raw))
        : _decodeSnapshot(raw);
  }

  static (List<FoodEntry>, int)? _decodeSnapshot(String raw) {
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return null;
    }
    if (decoded is! Map<String, dynamic>) return null;
    final rawEntries = decoded['entries'];
    if (rawEntries is! List) return null;

    final entries = <FoodEntry>[];
    for (final raw in rawEntries) {
      if (raw is! Map<String, dynamic>) continue;
      final entry = FoodEntry.tryFromMap(raw);
      // A single unrenderable row costs that row, not the rest of the log.
      if (entry != null) entries.add(entry);
    }
    final generation = decoded['journal'];
    return (entries, generation is int ? generation : 0);
  }

  Future<List<Map<String, dynamic>>> _readJournal(int generation) async {
    final journal = _journalFile(generation);
    if (!await journal.exists()) return const [];
    final ops = <Map<String, dynamic>>[];
    for (final line in const LineSplitter().convert(await journal.readAsString())) {
      if (line.trim().isEmpty) continue;
      try {
        final op = jsonDecode(line);
        if (op is Map<String, dynamic>) ops.add(op);
      } on FormatException {
        // A line torn by a crash mid-append. Only ever the last one, and what
        // it described was never reported to the user as saved.
      }
    }
    return ops;
  }

  /// Replays one journal line. Written by [writeAll] from a list it had just
  /// compared, so each names the position it changed; the id is checked too,
  /// and wins where the two disagree.
  static void _apply(List<FoodEntry> entries, Map<String, dynamic> op) {
    final at = op['at'];
    final index = at is int ? at : 0;
    switch (op['op']) {
      case 'insert':
        final raw = op['entry'];
        final entry = raw is Map<String, dynamic> ? FoodEntry.tryFromMap(raw) : null;
        if (entry == null || entries.any((e) => e.id == entry.id)) return;
        entries.insert(index.clamp(0, entries.length), entry);
      case 'remove':
        final id = op['id'];
        final position = index < entries.length && entries[index].id == id
            ? index
            : entries.indexWhere((e) => e.id == id);
        if (position != -1) entries.removeAt(position);
      case 'replace':
        final raw = op['entry'];
        final entry = raw is Map<String, dynamic> ? FoodEntry.tryFromMap(raw) : null;
        if (entry == null) return;
        final position = index < entries.length && entries[index].id == entry.id
            ? index
            : entries.indexWhere((e) => e.id == entry.id);
        if (position != -1) entries[position] = entry;
    }
  }

  /// Journals from generations no snapshot names any more: what a crash
  /// between writing a snapshot and deleting its predecessor's journal leaves.
  Future<void> _removeOrphanJournals({required int keep}) async {
    if (!await _dir.exists()) return;
    await for (final entity in _dir.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      if (!name.startsWith(_journalPrefix) || !name.endsWith(_journalSuffix)) {
        continue;
      }
      final generation = int.tryParse(name.substring(
          _journalPrefix.length, name.length - _journalSuffix.length));
      if (generation != null && generation != keep) {
        await _deleteQuietly(entity);
      }
    }
  }

  /// Replaces the log with exactly [entries].
  ///
  /// A journal line when [entries] is the last known list with one entry added,
  /// removed or edited; otherwise a whole new snapshot. Either way, the change
  /// is on disk when this returns — the caller commits nothing before that.
  Future<void> writeAll(List<FoodEntry> entries) async {
    final baseline = _baseline;
    final op = baseline == null || _journalOps >= maxJournalOps
        ? null
        : _diff(baseline, entries);

    if (op == null) {
      await _writeSnapshot(entries);
    } else if (op.isNotEmpty) {
      await _journalFile(_generation).writeAsString(
        '${jsonEncode(op)}\n',
        mode: FileMode.append,
        flush: true,
      );
      _journalOps++;
    }
    _baseline = List.unmodifiable(entries);
  }

  /// The single change from [before] to [after] as a journal line; empty when
  /// nothing changed; null when it is more than one change, which a snapshot
  /// records instead.
  ///
  /// By identity rather than by value: the notifier builds each new list from
  /// the entries of the last, so an untouched entry is the very same object.
  static Map<String, Object?>? _diff(
    List<FoodEntry> before,
    List<FoodEntry> after,
  ) {
    var first = 0;
    final shorter = before.length < after.length ? before.length : after.length;
    while (first < shorter && identical(before[first], after[first])) {
      first++;
    }

    bool tailsMatch(int beforeFrom, int afterFrom) {
      if (before.length - beforeFrom != after.length - afterFrom) return false;
      for (var i = 0; beforeFrom + i < before.length; i++) {
        if (!identical(before[beforeFrom + i], after[afterFrom + i])) {
          return false;
        }
      }
      return true;
    }

    if (after.length == before.length) {
      if (first == before.length) return const {};
      final changed = after[first];
      if (changed.id != before[first].id || !tailsMatch(first + 1, first + 1)) {
        return null;
      }
      return {'op': 'replace', 'at': first, 'entry': changed.toMap()};
    }
    if (after.length == before.length + 1 && tailsMatch(first, first + 1)) {
      return {'op': 'insert', 'at': first, 'entry': after[first].toMap()};
    }
    if (after.length + 1 == before.length && tailsMatch(first + 1, first)) {
      return {'op': 'remove', 'at': first, 'id': before[first].id};
    }
    return null;
  }

  /// Written to a temp file and renamed into place. `rename` is atomic within a
  /// filesystem, so an interruption leaves either the old complete file or the
  /// new one — never a half-written log, which [readAll] would have to discard
  /// in full.
  Future<void> _writeSnapshot(List<FoodEntry> entries) async {
    if (!await _dir.exists()) {
      await _dir.create(recursive: true);
    }
    final previous = _generation;
    final next = previous + 1;
    final payload = entries.length > backgroundEncodeEntries
        ? await Isolate.run(() => _encodeSnapshot(entries, next))
        : _encodeSnapshot(entries, next);
    await _tempFile.writeAsString(payload, flush: true);
    await _tempFile.rename(file.path);

    // The new snapshot holds everything the old journal did, and names a
    // journal that does not exist yet.
    _generation = next;
    _journalOps = 0;
    await _deleteQuietly(_journalFile(previous));
  }

  static String _encodeSnapshot(List<FoodEntry> entries, int generation) =>
      jsonEncode({
        'schemaVersion': currentSchemaVersion,
        'journal': generation,
        'entries': entries.map((e) => e.toMap()).toList(),
      });

  /// Erases this user's log. Called on account deletion, never on logout.
  ///
  /// Removes the temp file and every journal too: each holds the same meal
  /// names the user asked to erase.
  Future<void> delete() async {
    for (final target in [file, _tempFile]) {
      await _deleteQuietly(target);
    }
    try {
      await _removeOrphanJournals(keep: -1);
    } on FileSystemException {
      // Account deletion must not stall on a directory it cannot list.
    }
    _baseline = null;
    _generation = 0;
    _journalOps = 0;
  }

  static Future<void> _deleteQuietly(File target) async {
    try {
      if (await target.exists()) await target.delete();
    } on FileSystemException {
      // Already gone, or unreadable. Either way there is nothing to retry and
      // account deletion must not stall on it.
    }
  }
}
