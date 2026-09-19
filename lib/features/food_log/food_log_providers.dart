import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

import '../../models/food_entry.dart';
import '../auth/auth_provider.dart';
import 'api_credentials.dart';
import 'food_analysis_client.dart';
import 'food_log_grouping.dart';
import 'food_log_store.dart';

final foodAnalysisClientProvider = Provider<FoodAnalysisClient>((ref) {
  return FoodAnalysisClient(
    credentialStore: ref.watch(apiCredentialStoreProvider),
  );
});

/// A `FutureProvider` because both halves of building the store are async: the
/// documents directory comes from `path_provider`, and the uid comes from the
/// auth stream.
///
/// Watching the auth stream is what re-points the store at a new file when the
/// signed-in user changes, so the next user never reads the previous one's log.
final foodLogStoreProvider = FutureProvider<FoodLogStore>((ref) async {
  final user = await ref.watch(authStateProvider.future);
  final uid = user?.uid;
  if (uid == null) {
    // Both food screens sit behind auth, so this is a programming error rather
    // than a state the user can reach.
    throw StateError('Cannot open a food log without a signed-in user');
  }
  final dir = await getApplicationDocumentsDirectory();
  return FoodLogStore(dir: dir, uid: uid);
});

/// Seam over `image_picker` plus `flutter_image_compress`.
///
/// One seam rather than two, because the screens only ever want the finished
/// artifact: a compressed JPEG ready to upload. Returns `null` when the user
/// backs out of the picker.
abstract class ImageCaptureGateway {
  Future<File?> capture(ImageSource source);
}

class ImagePickerCaptureGateway implements ImageCaptureGateway {
  const ImagePickerCaptureGateway();

  /// Long edge cap and JPEG quality for the upload. A phone photo is several MB
  /// and every provider re-encodes it to base64 anyway, which inflates it by a
  /// third; 1024px is more than enough for a model to read a plate.
  static const int maxDimension = 1024;
  static const int jpegQuality = 80;

  @override
  Future<File?> capture(ImageSource source) async {
    final picked = await ImagePicker().pickImage(source: source);
    if (picked == null) return null;

    final target =
        '${Directory.systemTemp.path}/vf_meal_${DateTime.now().millisecondsSinceEpoch}.jpg';
    final compressed = await FlutterImageCompress.compressAndGetFile(
      picked.path,
      target,
      minWidth: maxDimension,
      minHeight: maxDimension,
      quality: jpegQuality,
    );
    // Compression is an optimisation, not a requirement: if the plugin declines
    // (an unsupported format, say), upload the original rather than fail.
    return compressed == null ? File(picked.path) : File(compressed.path);
  }
}

final imageCaptureGatewayProvider = Provider<ImageCaptureGateway>((ref) {
  return const ImagePickerCaptureGateway();
});

/// Holds in-flight and error state for one vision analysis.
///
/// State drives the spinner and the error text. [capture] additionally returns
/// the result so the screen knows whether to navigate, and the three outcomes
/// are kept on separate channels: a draft means go to the form, `null` means the
/// user cancelled and nothing should happen, and a throw means show the message.
class VisionAnalysisController extends AsyncNotifier<FoodAnalysis?> {
  static const String errorPermissionDenied =
      'PERMISSION DENIED — ENABLE IN SETTINGS';

  @override
  Future<FoodAnalysis?> build() async => null;

  /// Picks an image, compresses it, and analyses it.
  ///
  /// Returns `null` if the user dismissed the picker. Throws
  /// [FoodAnalysisException] with display-ready copy on any failure.
  Future<FoodAnalysis?> capture(ImageSource source) async {
    state = const AsyncLoading();
    File? image;
    try {
      try {
        image = await ref.read(imageCaptureGatewayProvider).capture(source);
      } on PlatformException {
        // image_picker reports a refused camera or library permission this way.
        throw const FoodAnalysisException(errorPermissionDenied);
      }

      if (image == null) {
        // Cancelling is a deliberate choice, not a failure: back to idle in
        // silence, and no scan spent against the rate limit.
        state = const AsyncData(null);
        return null;
      }

      final result = await ref.read(foodAnalysisClientProvider).analyze(image);
      state = AsyncData(result);
      return result;
    } catch (error, stack) {
      state = AsyncError(error, stack);
      rethrow;
    } finally {
      // The compressed copy has served its purpose either way; leaving it would
      // accumulate multi-megabyte files in the temp directory.
      if (image != null && await image.exists()) {
        try {
          await image.delete();
        } on FileSystemException {
          // A temp file the OS will reclaim anyway is not worth failing over.
        }
      }
    }
  }
}

final visionAnalysisProvider =
    AsyncNotifierProvider<VisionAnalysisController, FoodAnalysis?>(() {
  return VisionAnalysisController();
});

/// The food log both screens read, newest entry first.
///
/// The in-memory list is the source of truth and this notifier is its only
/// writer, so there are no snapshots to reconcile: state changes are explicit
/// rather than echoes of a remote write. Both history screens watch this one
/// provider, which is what makes a save from the form redraw both.
class RecentFoodLog extends AsyncNotifier<List<FoodEntry>> {
  static const String errorSaveFailed = "COULDN'T SAVE — TRY AGAIN";

  @override
  Future<List<FoodEntry>> build() async {
    final store = await ref.watch(foodLogStoreProvider.future);
    return store.readAll();
  }

  /// Adds [entry] and persists the whole log.
  ///
  /// Persists **before** committing state. Unlike a Firestore write there is no
  /// offline queue to fall back on: an entry that failed to write exists in
  /// memory and nowhere else, and would vanish on next launch with no
  /// indication it was ever lost. Throwing here keeps the UI honest.
  Future<void> add(FoodEntry entry) async {
    final store = await ref.read(foodLogStoreProvider.future);
    final current = state.value ?? await store.readAll();
    final next = [entry, ...current];

    await _persist(store, next);
  }

  /// Replaces the entry sharing [entry]'s id, keeping its position in the log.
  ///
  /// Named `replace` rather than `update` because `AsyncNotifier` already
  /// declares an `update`, and overriding it with a different contract would be
  /// a trap for anyone who called the inherited one expecting its behaviour.
  ///
  /// Position is kept rather than recomputed because an edit that moved a meal
  /// to the top of the list would look like a second meal was logged. The id and
  /// `loggedAt` are the entry's identity here; only what it describes changes.
  ///
  /// Silently does nothing when the id is absent, which is what a stale screen
  /// editing an entry deleted elsewhere produces. Writing it back would
  /// resurrect a row the user deleted.
  Future<void> replace(FoodEntry entry) async {
    final store = await ref.read(foodLogStoreProvider.future);
    final current = state.value ?? await store.readAll();

    final index = current.indexWhere((e) => e.id == entry.id);
    if (index == -1) return;

    final next = [...current]..[index] = entry;
    await _persist(store, next);
  }

  /// Removes the entry with [id] and reports where it was.
  ///
  /// The index is returned so an undo can put it back where it came from rather
  /// than at the top of the log. Returns -1 when the id is absent, which is a
  /// no-op: deleting something already deleted is the outcome the user wanted
  /// either way.
  Future<int> remove(String id) async {
    final store = await ref.read(foodLogStoreProvider.future);
    final current = state.value ?? await store.readAll();

    final index = current.indexWhere((e) => e.id == id);
    if (index == -1) return -1;

    final next = [...current]..removeAt(index);
    await _persist(store, next);
    return index;
  }

  /// Puts [entry] back at [index]. The undo half of [remove].
  ///
  /// Position matters: [add] prepends, so undoing through it would move an old
  /// meal to the top of the log and make a restored entry look like a new one.
  ///
  /// The index is clamped rather than trusted. Between the delete and the undo
  /// the user may have logged or removed something else, and a stale index
  /// would otherwise throw on a list that is now shorter.
  Future<void> insertAt(FoodEntry entry, int index) async {
    final store = await ref.read(foodLogStoreProvider.future);
    final current = state.value ?? await store.readAll();
    if (current.any((e) => e.id == entry.id)) return;

    final next = [...current]
      ..insert(index.clamp(0, current.length), entry);
    await _persist(store, next);
  }

  /// Writes [next] to disk, then commits it to state.
  ///
  /// Same ordering and same reasoning as [add]: the file is the only copy, so a
  /// change that failed to write must not be shown as though it succeeded.
  Future<void> _persist(FoodLogStore store, List<FoodEntry> next) async {
    try {
      await store.writeAll(next);
    } catch (_) {
      throw const FoodAnalysisException(errorSaveFailed);
    }
    state = AsyncData(next);
  }
}

final recentFoodLogProvider =
    AsyncNotifierProvider<RecentFoodLog, List<FoodEntry>>(() {
  return RecentFoodLog();
});

/// The clock the dashboard's "today" is measured against.
///
/// A provider rather than `DateTime.now()` so a test can stand at either side of
/// midnight, which is the only place the calendar-day boundary can be wrong.
final foodLogClockProvider = Provider<DateTime Function()>((ref) {
  return DateTime.now;
});

/// Today's intake, scaled by each entry's serving multiplier.
///
/// Derived from [recentFoodLogProvider] rather than read from the store, so a
/// meal saved in the form updates the dashboard without either screen knowing
/// about the other.
final todayTotalsProvider = FutureProvider<DayTotals>((ref) async {
  final entries = await ref.watch(recentFoodLogProvider.future);
  return totalsForDay(entries, day: ref.read(foodLogClockProvider)());
});
