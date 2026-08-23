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
class VisionAnalysisController extends AsyncNotifier<(String, Nutrients)?> {
  static const String errorPermissionDenied =
      'PERMISSION DENIED — ENABLE IN SETTINGS';

  @override
  Future<(String, Nutrients)?> build() async => null;

  /// Picks an image, compresses it, and analyses it.
  ///
  /// Returns `null` if the user dismissed the picker. Throws
  /// [FoodAnalysisException] with display-ready copy on any failure.
  Future<(String, Nutrients)?> capture(ImageSource source) async {
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
    AsyncNotifierProvider<VisionAnalysisController, (String, Nutrients)?>(() {
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
