import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:void_factor/screens/settings/delete_account_dialog.dart';

void main() {
  // What the last `show()` resolved to, or null while the dialog is still up —
  // so a test can tell "the user declined" from "nothing happened yet".
  late bool? outcome;

  Future<void> openDialog(WidgetTester tester) async {
    outcome = null;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () async =>
                    outcome = await DeleteAccountDialog.show(context),
                child: const Text('OPEN'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('OPEN'));
    await tester.pumpAndSettle();
  }

  Future<void> type(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextFormField), text);
    await tester.pump();
  }

  final deleteAction =
      find.widgetWithText(TextButton, DeleteAccountDialog.confirmLabel);

  bool isArmed(WidgetTester tester) =>
      tester.widget<TextButton>(deleteAction).enabled;

  group('what it warns about', () {
    testWidgets('names everything the deletion destroys', (tester) async {
      await openDialog(tester);

      for (final item in DeleteAccountDialog.destroyedItems) {
        expect(find.text(item), findsOneWidget, reason: item);
      }
    });

    testWidgets('names the food logs on this device explicitly',
        (tester) async {
      await openDialog(tester);

      // The data the user has put the most work into, and the only copy — a
      // warning that spoke only of "your account" would not mention it.
      expect(find.textContaining('FOOD LOG'), findsOneWidget);
    });

    testWidgets('says which word unlocks the action', (tester) async {
      await openDialog(tester);

      expect(
        find.textContaining(DeleteAccountDialog.confirmWord),
        findsWidgets,
      );
    });
  });

  group('the typed confirmation', () {
    testWidgets('starts disarmed', (tester) async {
      await openDialog(tester);

      expect(isArmed(tester), isFalse);
    });

    testWidgets('stays disarmed for an emptied field', (tester) async {
      await openDialog(tester);

      await type(tester, 'DELETE');
      await type(tester, '');

      expect(isArmed(tester), isFalse);
    });

    testWidgets('stays disarmed for a partial word', (tester) async {
      await openDialog(tester);

      await type(tester, 'DELET');

      expect(isArmed(tester), isFalse);
    });

    testWidgets('stays disarmed for the wrong case', (tester) async {
      await openDialog(tester);

      // Case is the part that makes typing it a deliberate act rather than a
      // reflex, so it is not relaxed.
      await type(tester, 'delete');

      expect(isArmed(tester), isFalse);
    });

    testWidgets('stays disarmed for the word inside a sentence',
        (tester) async {
      await openDialog(tester);

      await type(tester, 'DELETE MY ACCOUNT');

      expect(isArmed(tester), isFalse);
    });

    testWidgets('arms on the exact word', (tester) async {
      await openDialog(tester);

      await type(tester, DeleteAccountDialog.confirmWord);

      expect(isArmed(tester), isTrue);
    });

    testWidgets('arms on the word with stray whitespace around it',
        (tester) async {
      await openDialog(tester);

      // A copied word arrives with a space attached often enough, and the
      // difference is invisible on screen: refusing it would read as a bug.
      await type(tester, '  DELETE ');

      expect(isArmed(tester), isTrue);
    });
  });

  group('what it hands back', () {
    testWidgets('confirming returns true', (tester) async {
      await openDialog(tester);

      await type(tester, DeleteAccountDialog.confirmWord);
      await tester.tap(deleteAction);
      await tester.pumpAndSettle();

      expect(outcome, isTrue);
    });

    testWidgets('cancelling returns false', (tester) async {
      await openDialog(tester);

      await tester.tap(find.widgetWithText(TextButton, 'CANCEL'));
      await tester.pumpAndSettle();

      expect(outcome, isFalse);
    });

    testWidgets('dismissing it counts as declining, never as consent',
        (tester) async {
      await openDialog(tester);

      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      // `showDialog` resolves null on a barrier tap, and a null read as
      // anything but "no" would delete an account nobody confirmed.
      expect(outcome, isFalse);
    });

    testWidgets('the disarmed action neither confirms nor closes',
        (tester) async {
      await openDialog(tester);

      await tester.tap(deleteAction);
      await tester.pumpAndSettle();

      expect(outcome, isNull);
      expect(deleteAction, findsOneWidget);
    });
  });
}
