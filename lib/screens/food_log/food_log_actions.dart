import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/food_log/food_analysis_client.dart';
import '../../features/food_log/food_log_providers.dart';
import '../../models/food_entry.dart';
import 'food_entry_form_screen.dart';

/// Correcting and removing a logged entry.
///
/// Shared by the vision tab and the history screen because both draw the same
/// rows from the same provider. A delete that offered undo on one screen and not
/// the other would be the same log behaving like two different ones.
const String undoLabel = 'UNDO';
const String deleteFailedLabel = "COULDN'T DELETE — TRY AGAIN";
const String undoFailedLabel = "COULDN'T RESTORE IT — TRY AGAIN";

String deletedLabel(FoodEntry entry) =>
    'DELETED ${entry.name.trim().toUpperCase()}';

/// Opens [entry] in the form, pre-filled. Saving replaces it in place.
///
/// Restorable, like every way into the form, so an edit half made when Android
/// kills the app is still there when it comes back.
void editFoodEntry(BuildContext context, FoodEntry entry) {
  Navigator.restorablePush(
    context,
    FoodEntryFormScreen.restorableRoute,
    arguments: FoodEntryFormScreen.editArguments(entry),
  );
}

/// Opens the form on what a scan read off the plate, for the user to confirm.
///
/// Takes the navigator rather than a context because both callers resolve it
/// before a long wait — the scan — during which their own context may go.
void openScanResult(NavigatorState navigator, FoodAnalysis draft) {
  navigator.restorablePush(
    FoodEntryFormScreen.restorableRoute,
    arguments: FoodEntryFormScreen.scanArguments(draft),
  );
}

/// Removes [entry], offering to put it back.
///
/// Undo rather than a confirmation dialog: a mis-logged meal is low stakes and
/// gets deleted often, and a modal on every delete trains people to dismiss
/// modals. The account-deletion dialog stays where it is — that one has no undo.
Future<void> deleteFoodEntry(
  BuildContext context,
  WidgetRef ref,
  FoodEntry entry,
) async {
  final messenger = ScaffoldMessenger.of(context);
  final log = ref.read(recentFoodLogProvider.notifier);

  final int index;
  try {
    index = await log.remove(entry.id);
  } on FoodAnalysisException catch (error) {
    messenger.showSnackBar(SnackBar(content: Text(error.message)));
    return;
  } catch (_) {
    messenger.showSnackBar(const SnackBar(content: Text(deleteFailedLabel)));
    return;
  }

  // Already gone — deleted from the other screen, most likely. The user's goal
  // is met, so there is nothing to say and nothing to offer undoing.
  if (index == -1) return;

  // Deleting three rows quickly would otherwise queue three snackbars, and the
  // undo for the first would appear long after the row left the screen.
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(
    SnackBar(
      content: Text(deletedLabel(entry)),
      action: SnackBarAction(
        label: undoLabel,
        onPressed: () async {
          try {
            await log.insertAt(entry, index);
          } catch (_) {
            // The entry is gone from disk and the user asked for it back, so a
            // silent failure here would be the worst of both.
            messenger.showSnackBar(
              const SnackBar(content: Text(undoFailedLabel)),
            );
          }
        },
      ),
    ),
  );
}
