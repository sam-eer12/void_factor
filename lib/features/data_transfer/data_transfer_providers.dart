import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../models/food_entry.dart';
import '../../models/weight_entry.dart';
import '../auth/session_provider.dart';
import '../food_log/food_log_providers.dart';
import '../weight_log/weight_log_providers.dart';
import 'data_bundle.dart';

/// A failure with a message already written for the user, matching the
/// convention `FoodAnalysisException` established.
class DataTransferException implements Exception {
  final String message;

  const DataTransferException(this.message);

  @override
  String toString() => message;
}

/// Moving one file into and out of the app.
///
/// Export and import sit behind one seam rather than two because they are one
/// concern — handing the file to the OS and taking it back — and because a test
/// that fakes one almost always wants to fake the other.
abstract class DataFileGateway {
  /// Hands [contents] to the share sheet under [filename].
  Future<void> share(String contents, String filename);

  /// Returns the picked file's contents, or `null` if the user backed out.
  Future<String?> pick();
}

class PlatformDataFileGateway implements DataFileGateway {
  const PlatformDataFileGateway();

  @override
  Future<void> share(String contents, String filename) async {
    // Written to the temp directory rather than handed over as bytes: the share
    // sheet passes a file URI to whichever app the user picks, so the file has
    // to exist somewhere that app can read.
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/$filename');
    await file.writeAsString(contents, flush: true);
    try {
      await SharePlus.instance.share(
        ShareParams(files: [XFile(file.path)], fileNameOverrides: [filename]),
      );
    } finally {
      // The receiving app has copied it by the time the sheet closes, and an
      // export left behind is a copy of the user's whole history sitting in a
      // directory they never chose.
      try {
        if (await file.exists()) await file.delete();
      } on FileSystemException {
        // The OS reclaims the temp directory anyway.
      }
    }
  }

  @override
  Future<String?> pick() async {
    // No type filter: exports carry a .json extension, but a file that has been
    // through a chat app or a cloud drive often comes back without one, and a
    // filter that hides the user's own export is worse than reading a wrong
    // file and saying so.
    final file = await openFile();
    if (file == null) return null;
    return file.readAsString();
  }
}

final dataFileGatewayProvider = Provider<DataFileGateway>((ref) {
  return const PlatformDataFileGateway();
});

/// Export and import of everything this device holds.
///
/// `AsyncNotifier<void>` because the screen needs the in-flight and failed
/// states — an export of a long history is not instant — but neither operation
/// has a result worth holding onto afterwards.
class DataTransferController extends AsyncNotifier<void> {
  static const String errorExportFailed = "COULDN'T BUILD YOUR EXPORT";
  static const String errorUnreadableFile =
      "THAT FILE ISN'T A VOID FACTOR EXPORT";
  static const String errorImportFailed = "COULDN'T IMPORT — TRY AGAIN";

  @override
  Future<void> build() async {}

  /// Filename carrying the export date, so a folder of them sorts and reads.
  static String filenameFor(DateTime now) {
    String two(int n) => n.toString().padLeft(2, '0');
    return 'void-factor-${now.year}-${two(now.month)}-${two(now.day)}.json';
  }

  Future<void> export() async {
    state = const AsyncLoading();
    try {
      final bundle = DataBundle(
        exportedAt: DateTime.now(),
        profile: await ref.read(profileProvider.future),
        foodEntries: await ref.read(recentFoodLogProvider.future),
        weightEntries: await ref.read(weightLogProvider.future),
      );
      await ref.read(dataFileGatewayProvider).share(
            bundle.toJsonString(),
            filenameFor(bundle.exportedAt),
          );
      state = const AsyncData(null);
    } catch (error, stack) {
      state = AsyncError(error, stack);
      throw const DataTransferException(errorExportFailed);
    }
  }

  /// Merges a bundle into this device. Returns `null` if the picker was
  /// dismissed — a deliberate choice, so nothing happens and nothing is said.
  Future<ImportSummary?> import() async {
    state = const AsyncLoading();
    try {
      final raw = await ref.read(dataFileGatewayProvider).pick();
      if (raw == null) {
        state = const AsyncData(null);
        return null;
      }

      final bundle = DataBundle.tryParse(raw);
      if (bundle == null) {
        throw const DataTransferException(errorUnreadableFile);
      }

      final summary = await _merge(bundle);
      state = const AsyncData(null);
      return summary;
    } on DataTransferException catch (error, stack) {
      state = AsyncError(error, stack);
      rethrow;
    } catch (error, stack) {
      state = AsyncError(error, stack);
      throw const DataTransferException(errorImportFailed);
    }
  }

  /// Writes the merged logs, then rebuilds the notifiers from disk.
  ///
  /// Both files are written before either provider is invalidated, so a failure
  /// part-way leaves the screens showing the old state consistently rather than
  /// one log updated and the other not.
  ///
  /// The profile in the bundle is deliberately ignored. It is already mirrored
  /// to Firestore and returns on login, so restoring it would risk overwriting
  /// a newer profile to recover something that was never at risk.
  Future<ImportSummary> _merge(DataBundle bundle) async {
    final foodStore = await ref.read(foodLogStoreProvider.future);
    final weightStore = await ref.read(weightLogStoreProvider.future);

    final existingFood = await ref.read(recentFoodLogProvider.future);
    final existingWeight = await ref.read(weightLogProvider.future);

    final mergedFood = DataBundle.mergeById<FoodEntry>(
      existingFood,
      bundle.foodEntries,
      idOf: (e) => e.id,
      timeOf: (e) => e.loggedAt,
    );
    final mergedWeight = DataBundle.mergeById<WeightEntry>(
      existingWeight,
      bundle.weightEntries,
      idOf: (e) => e.id,
      timeOf: (e) => e.recordedAt,
    );

    await foodStore.writeAll(mergedFood);
    await weightStore.writeAll(mergedWeight);

    ref.invalidate(recentFoodLogProvider);
    ref.invalidate(weightLogProvider);

    return ImportSummary(
      foodEntriesAdded: mergedFood.length - existingFood.length,
      weightEntriesAdded: mergedWeight.length - existingWeight.length,
    );
  }
}

final dataTransferProvider =
    AsyncNotifierProvider<DataTransferController, void>(() {
  return DataTransferController();
});
