import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../models/user_profile.dart';
import '../../models/weight_entry.dart';
import '../auth/auth_provider.dart';
import '../auth/session_provider.dart';
import '../profile/profile_repository.dart';
import 'weight_log_store.dart';

/// A local weight write that could not be completed.
///
/// Deliberately not reusing `FoodAnalysisException`: nothing about saving a
/// weight involves the analysis microservice, and borrowing its exception would
/// couple this feature to the food pipeline's error vocabulary.
class WeightLogException implements Exception {
  const WeightLogException(this.message);

  /// Display-ready copy, in the app's uppercase voice.
  final String message;

  @override
  String toString() => message;
}

/// How far a save got.
///
/// Two endings rather than one, because the local write and the profile
/// write-through fail independently and mean different things to the user. The
/// measurement being safely on disk is the part that matters; the profile mirror
/// is a convenience that can be caught up on the next save.
enum WeightSaveOutcome {
  /// On disk, and `UserProfile.weight` now agrees with it.
  saved,

  /// On disk, but the profile mirror could not be updated — offline, most
  /// likely. Nothing was lost; BMR will read a slightly stale weight until the
  /// next successful save.
  savedWithoutSync,
}

/// A `FutureProvider` because both halves of building the store are async: the
/// documents directory comes from `path_provider`, and the uid comes from the
/// auth stream.
///
/// Watching the auth stream is what re-points the store at a new file when the
/// signed-in user changes, so the next user never reads the previous one's
/// history. Mirrors `foodLogStoreProvider`.
final weightLogStoreProvider = FutureProvider<WeightLogStore>((ref) async {
  final user = await ref.watch(authStateProvider.future);
  final uid = user?.uid;
  if (uid == null) {
    // The projections screen sits behind auth, so this is a programming error
    // rather than a state the user can reach.
    throw StateError('Cannot open a weight log without a signed-in user');
  }
  final dir = await getApplicationDocumentsDirectory();
  return WeightLogStore(dir: dir, uid: uid);
});

/// The weight history, newest entry first.
///
/// The in-memory list is the source of truth and this notifier is its only
/// writer, so there are no snapshots to reconcile — the same arrangement
/// `RecentFoodLog` uses.
///
/// Unlike the food log, the list is kept **sorted** rather than in insertion
/// order. A backdated weigh-in is a normal thing to enter ("I forgot to log
/// Monday"), and a chart drawn from an unsorted series would connect its points
/// in entry order and zig-zag backwards through time. The store stays
/// order-agnostic; the sort belongs to the reader that depends on it.
class WeightLog extends AsyncNotifier<List<WeightEntry>> {
  static const String errorSaveFailed = "COULDN'T SAVE — TRY AGAIN";

  @override
  Future<List<WeightEntry>> build() async {
    final store = await ref.watch(weightLogStoreProvider.future);
    return _sorted(await store.readAll());
  }

  /// Adds [entry], persists the whole history, then mirrors the newest weight
  /// into `UserProfile.weight`.
  ///
  /// Persists **before** committing state, for the reason `RecentFoodLog.add`
  /// documents: unlike a Firestore write there is no offline queue to fall back
  /// on, so an entry that failed to write exists in memory and nowhere else and
  /// would vanish on next launch with no indication it was ever lost.
  ///
  /// The profile write-through happens **after** the local commit and cannot
  /// undo it. That ordering is the whole point: the series is the user's data
  /// and the profile field is a derived mirror, so a network failure must cost
  /// the mirror, never the measurement.
  Future<WeightSaveOutcome> add(WeightEntry entry) async {
    final store = await ref.read(weightLogStoreProvider.future);
    final current = state.value ?? _sorted(await store.readAll());
    final next = _sorted([entry, ...current]);

    try {
      await store.writeAll(next);
    } catch (_) {
      throw const WeightLogException(errorSaveFailed);
    }

    state = AsyncData(next);

    // Only the newest measurement defines "current weight". Backdating an older
    // weigh-in must not drag the profile — and therefore BMR — backwards.
    if (next.first.id != entry.id) return WeightSaveOutcome.saved;

    return await _syncProfileWeight(entry.weightKg);
  }

  /// Mirrors [weightKg] into the profile so BMR, the dashboard, and Edit Profile
  /// agree with what the chart shows.
  ///
  /// Loads before saving rather than patching a cached copy. `ProfileRepository`
  /// writes the whole field set with merge semantics, so saving a stale profile
  /// would quietly revert whatever the user last changed in Goals & Diet.
  /// `load()` prefers Firestore and never throws.
  Future<WeightSaveOutcome> _syncProfileWeight(double weightKg) async {
    try {
      final repository = ref.read(profileRepositoryProvider);
      final profile = await repository.load();

      // A profile that was never filled in has no other fields worth
      // preserving, and writing height 0 / age 0 alongside the weight would
      // make the projection look computable when it is not. Onboarding owns
      // that first write.
      if (profile.height <= 0 || profile.age <= 0) {
        return WeightSaveOutcome.savedWithoutSync;
      }

      await repository.save(profile.copyWith(weight: weightKg));
      // Everything that renders a weight watches profileProvider — the same
      // invalidate-after-write the settings screens do.
      ref.invalidate(profileProvider);
      return WeightSaveOutcome.saved;
    } catch (_) {
      return WeightSaveOutcome.savedWithoutSync;
    }
  }

  /// Newest first, on a copy.
  ///
  /// Sorted on a copy because the caller's list may be the notifier's own state,
  /// and sorting in place would mutate state outside a state assignment.
  static List<WeightEntry> _sorted(List<WeightEntry> entries) {
    return List<WeightEntry>.from(entries)
      ..sort((a, b) => b.recordedAt.compareTo(a.recordedAt));
  }
}

final weightLogProvider =
    AsyncNotifierProvider<WeightLog, List<WeightEntry>>(() {
  return WeightLog();
});

/// The newest recorded weight, or `null` when nothing has been logged yet.
///
/// Read by the projection engine's caller in preference to `UserProfile.weight`:
/// the write-through keeps the two equal in the normal case, but when it fails
/// the series is the one that is definitely current.
WeightEntry? latestWeight(List<WeightEntry> newestFirst) =>
    newestFirst.isEmpty ? null : newestFirst.first;

/// The weight the projection should treat as "today's", falling back to the
/// profile when no weigh-in exists.
///
/// A single place for the precedence rule, so the engine, the chart, and the
/// entry sheet cannot disagree about which number is current.
double currentWeightKg(List<WeightEntry> newestFirst, UserProfile profile) {
  final latest = latestWeight(newestFirst);
  return latest?.weightKg ?? profile.weight;
}
