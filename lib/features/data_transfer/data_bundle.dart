import 'dart:convert';

import '../../models/food_entry.dart';
import '../../models/user_profile.dart';
import '../../models/weight_entry.dart';

/// Everything one user's device holds, in one portable file.
///
/// Exists because the food and weight logs are per-device JSON with no sync:
/// reinstalling, switching phones or clearing app data destroys them
/// permanently. The food-logging design accepted that and named this as the
/// mitigation.
///
/// The profile rides along for completeness — a user asking for their data
/// should get all of it — but [mergeInto] deliberately never restores it. The
/// profile is already mirrored to Firestore and comes back on login, so the
/// only things import needs to rescue are the ones nothing else can recover.
class DataBundle {
  /// Envelope version, separate from each entry's own `schemaVersion`.
  static const int currentSchemaVersion = 1;

  /// Identifies a file as ours before anything tries to read it as one. A
  /// user picking the wrong file from a share sheet is the common case, not
  /// the exotic one.
  static const String formatMarker = 'void_factor.export';

  final DateTime exportedAt;
  final UserProfile? profile;
  final List<FoodEntry> foodEntries;
  final List<WeightEntry> weightEntries;

  const DataBundle({
    required this.exportedAt,
    required this.profile,
    required this.foodEntries,
    required this.weightEntries,
  });

  Map<String, dynamic> toMap() => {
        'format': formatMarker,
        'schemaVersion': currentSchemaVersion,
        'exportedAt': exportedAt.toIso8601String(),
        'profile': profile?.toMap(),
        'foodEntries': foodEntries.map((e) => e.toMap()).toList(),
        'weightEntries': weightEntries.map((e) => e.toMap()).toList(),
      };

  String toJsonString() =>
      const JsonEncoder.withIndent('  ').convert(toMap());

  /// Parses an exported file. Returns `null` when the text is not one of ours.
  ///
  /// Individual unreadable entries are skipped rather than failing the import:
  /// one corrupt row should cost that row, not the other three hundred. A
  /// missing or wrong `format` marker does fail, because a file that is not an
  /// export has nothing worth salvaging and silently importing zero entries
  /// from it would look like success.
  static DataBundle? tryParse(String raw) {
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return null;
    }
    if (decoded is! Map<String, dynamic>) return null;
    if (decoded['format'] != formatMarker) return null;

    final foods = <FoodEntry>[];
    final rawFoods = decoded['foodEntries'];
    if (rawFoods is List) {
      for (final row in rawFoods) {
        if (row is! Map<String, dynamic>) continue;
        final entry = FoodEntry.tryFromMap(row);
        if (entry != null) foods.add(entry);
      }
    }

    final weights = <WeightEntry>[];
    final rawWeights = decoded['weightEntries'];
    if (rawWeights is List) {
      for (final row in rawWeights) {
        if (row is! Map<String, dynamic>) continue;
        final entry = WeightEntry.tryFromMap(row);
        if (entry != null) weights.add(entry);
      }
    }

    final rawProfile = decoded['profile'];
    return DataBundle(
      exportedAt:
          DateTime.tryParse(decoded['exportedAt']?.toString() ?? '') ??
              DateTime.fromMillisecondsSinceEpoch(0),
      profile: rawProfile is Map<String, dynamic>
          ? UserProfile.fromMap(rawProfile)
          : null,
      foodEntries: foods,
      weightEntries: weights,
    );
  }

  /// Adds every entry [existing] does not already hold, newest first.
  ///
  /// Union by id, never replacement. Three properties follow, and all three are
  /// what make an import safe to run without reading the file first:
  /// importing the same bundle twice changes nothing, importing an old bundle
  /// cannot delete newer entries, and an entry that exists on both sides keeps
  /// the copy already on the device.
  static List<T> mergeById<T>(
    List<T> existing,
    List<T> incoming, {
    required String Function(T) idOf,
    required DateTime Function(T) timeOf,
  }) {
    final known = existing.map(idOf).toSet();
    final merged = [
      ...existing,
      ...incoming.where((e) => !known.contains(idOf(e))),
    ];
    merged.sort((a, b) => timeOf(b).compareTo(timeOf(a)));
    return merged;
  }
}

/// What an import actually changed, for the sentence shown afterwards.
///
/// Counts what was added rather than what the file contained: "added 0 meals"
/// after importing a 200-meal file is the correct and reassuring answer when
/// they were all already there, and "imported 200" would be a lie.
class ImportSummary {
  final int foodEntriesAdded;
  final int weightEntriesAdded;

  const ImportSummary({
    required this.foodEntriesAdded,
    required this.weightEntriesAdded,
  });

  bool get changedNothing => foodEntriesAdded == 0 && weightEntriesAdded == 0;
}
