import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

import '../../models/food_entry.dart';
import '../auth/auth_provider.dart';
import '../lifecycle/app_lifecycle.dart';
import 'api_credentials.dart';
import 'food_analysis_client.dart';
import 'food_log_grouping.dart';
import 'food_log_store.dart';
import 'pending_scan.dart';

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

  /// The photo a picker delivered after Android had killed the app behind it,
  /// compressed as [capture] would have; `null` when there is none.
  ///
  /// The camera is a separate app, and a phone short of memory reclaims the
  /// one in the background — this one. The picker's result then arrives at a
  /// fresh process with no call waiting for it, and is held until asked for.
  Future<File?> recoverLost();
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
    return _compressed(picked.path);
  }

  @override
  Future<File?> recoverLost() async {
    // Only Android hands a result to a process other than the one that asked.
    if (!Platform.isAndroid) return null;
    final response = await ImagePicker().retrieveLostData();
    if (response.isEmpty) return null;
    final picked = response.file ?? response.files?.firstOrNull;
    if (picked == null) return null;
    return _compressed(picked.path);
  }

  Future<File> _compressed(String pickedPath) async {
    final target = '${Directory.systemTemp.path}/'
        '${PendingScanStore.tempImagePrefix}${DateTime.now().millisecondsSinceEpoch}.jpg';
    final compressed = await FlutterImageCompress.compressAndGetFile(
      pickedPath,
      target,
      minWidth: maxDimension,
      minHeight: maxDimension,
      quality: jpegQuality,
    );
    // Compression is an optimisation, not a requirement: if the plugin declines
    // (an unsupported format, say), upload the original rather than fail.
    if (compressed == null) return File(pickedPath);

    // The picker's full-size copy has done its job. Only ever one in the app's
    // own temp directory — which is where the picker writes the copies it
    // hands out — so a photo in the user's gallery can never be touched.
    if (pickedPath.startsWith(Directory.systemTemp.path)) {
      try {
        await File(pickedPath).delete();
      } on FileSystemException {
        // The OS clears its temp directory on its own schedule.
      }
    }
    return File(compressed.path);
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
///
/// A scan survives the app being killed partway. Its photo is held on disk
/// until the analysis answers ([PendingScanStore]), and a photo the camera
/// delivered to a killed app is recovered from the picker; the next launch
/// finishes either through [hasPendingScan] and [resumePending].
class VisionAnalysisController extends AsyncNotifier<FoodAnalysis?> {
  static const String errorPermissionDenied =
      'PERMISSION DENIED — ENABLE IN SETTINGS';

  /// How many times a scan the app was backgrounded through is retried on
  /// return before its failure is shown.
  static const int maxRetriesOnReturn = 2;

  /// Idle from the first frame. Returned synchronously so the state is data
  /// at once: an async build would read as loading for a moment, and loading
  /// is what [hasPendingScan] takes to mean a scan is already running — which
  /// is exactly the moment a relaunch asks.
  @override
  FutureOr<FoodAnalysis?> build() => null;

  /// Set from the first line of [resumePending], before anything awaits, so a
  /// second shell asking in the same frame cannot start the same scan again.
  bool _resuming = false;

  PendingScanStore get _pending => ref.read(pendingScanStoreProvider);

  /// Whose scan this is, so a resume never finishes another account's photo.
  /// Null only where there is no store to name a user — a test host.
  Future<String?> _owner() async {
    try {
      return (await ref.read(foodLogStoreProvider.future)).uid;
    } catch (_) {
      return null;
    }
  }

  /// Picks an image, compresses it, and analyses it.
  ///
  /// Returns `null` if the user dismissed the picker. Throws
  /// [FoodAnalysisException] with display-ready copy on any failure.
  Future<FoodAnalysis?> capture(ImageSource source) async {
    state = const AsyncLoading();
    File? image;
    try {
      image = await ref.read(imageCaptureGatewayProvider).capture(source);
    } on PlatformException catch (_, stack) {
      // image_picker reports a refused camera or library permission this way.
      const error = FoodAnalysisException(errorPermissionDenied);
      state = AsyncError(error, stack);
      throw error;
    } catch (error, stack) {
      state = AsyncError(error, stack);
      rethrow;
    }

    if (image == null) {
      // Cancelling is a deliberate choice, not a failure: back to idle in
      // silence, and no scan spent against the rate limit.
      state = const AsyncData(null);
      return null;
    }

    // On disk before the upload, which is the stretch the user is most likely
    // to spend in another app.
    final held = await _pending.hold(image, owner: await _owner());
    return _analyse(held);
  }

  /// Whether an earlier process left a scan unfinished: a held photo, or one
  /// the picker delivered after the app was killed behind it.
  ///
  /// False while a scan is already running here, so asking twice — two shells
  /// on the stack both checking — cannot start the same scan twice.
  Future<bool> hasPendingScan() async {
    if (state.isLoading || _resuming) return false;
    final owner = await _owner();
    if (await _pending.find(owner: owner) != null) return true;

    final File? recovered;
    try {
      recovered = await ref.read(imageCaptureGatewayProvider).recoverLost();
    } catch (_) {
      // A result the picker cannot hand back is a scan that never happened.
      return false;
    }
    if (recovered == null) return false;
    await _pending.hold(recovered, owner: owner);
    return true;
  }

  /// Finishes the scan [hasPendingScan] found, exactly as [capture] would have
  /// finished it: same states, same result, same failures.
  Future<FoodAnalysis?> resumePending() async {
    if (state.isLoading || _resuming) return null;
    _resuming = true;
    try {
      final pending = await _pending.find(owner: await _owner());
      if (pending == null) return null;
      state = const AsyncLoading();
      return await _analyse(pending.image);
    } finally {
      _resuming = false;
    }
  }

  Future<FoodAnalysis?> _analyse(File image) async {
    // Android freezes an app shortly after it leaves the screen, so a scan the
    // user switched away from can come back as unreachable only because the
    // app was not running to hear the answer. That failure is the user's
    // switching, not the network's, and is retried once they return; the photo
    // stays held meanwhile, so being killed while away still resumes.
    var leftDuringAttempt = false;
    final lifecycle = ref.listen(appLifecycleProvider, (_, next) {
      if (next != AppLifecycleState.resumed) leftDuringAttempt = true;
    });

    try {
      for (var retries = 0;; retries++) {
        try {
          final result =
              await ref.read(foodAnalysisClientProvider).analyze(image);
          state = AsyncData(result);
          return result;
        } on FoodAnalysisException catch (error) {
          final interrupted = leftDuringAttempt &&
              error.message == FoodAnalysisClient.errorUnreachable &&
              retries < maxRetriesOnReturn;
          if (!interrupted) rethrow;
          await _returnToForeground();
          leftDuringAttempt = false;
        }
      }
    } catch (error, stack) {
      state = AsyncError(error, stack);
      rethrow;
    } finally {
      lifecycle.close();
      // Answered either way: the result is in the form, or the failure is on
      // screen. Nothing left to resume, and no photo left behind.
      await _pending.clear();
      if (await image.exists()) {
        try {
          await image.delete();
        } on FileSystemException {
          // A temp file the OS will reclaim anyway is not worth failing over.
        }
      }
    }
  }

  Future<void> _returnToForeground() {
    if (ref.read(appLifecycleProvider) == AppLifecycleState.resumed) {
      return Future.value();
    }
    final back = Completer<void>();
    late final ProviderSubscription<AppLifecycleState> subscription;
    subscription = ref.listen(appLifecycleProvider, (_, next) {
      if (next == AppLifecycleState.resumed && !back.isCompleted) {
        back.complete();
        subscription.close();
      }
    });
    return back.future;
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
