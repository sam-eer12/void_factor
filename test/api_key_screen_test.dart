import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:void_factor/features/food_log/api_credentials.dart';
import 'package:void_factor/screens/settings/api_key_screen.dart';
import 'package:void_factor/widgets/monolith_text_field.dart';

/// In-memory stand-in for the secure store.
///
/// `flutter_secure_storage` is a platform channel and has no implementation
/// under `flutter_test`, so the real store cannot be reached from a widget test
/// at all. This fake is the seam `ApiCredentialStore` was extracted for, and it
/// keeps the real store's ordering contract: the default first, then the rest
/// in [kApiProviders] order.
class FakeApiCredentialStore implements ApiCredentialStore {
  FakeApiCredentialStore({Map<String, String>? keys, this.defaultProvider})
      : keys = {...?keys} {
    defaultProvider ??= this.keys.isEmpty ? null : this.keys.keys.first;
  }

  final Map<String, String> keys;
  String? defaultProvider;

  /// Every credential handed to [write], in order — so a test can assert what
  /// was written rather than only what ended up stored.
  final List<ApiCredentials> writes = [];
  final List<String> removed = [];
  final List<String> promoted = [];
  bool failWrites = false;
  bool failDeletes = false;
  bool failDefault = false;

  @override
  Future<List<ApiCredentials>> readAll() async {
    final order = [
      if (defaultProvider != null && keys.containsKey(defaultProvider))
        defaultProvider!,
      for (final provider in kApiProviders)
        if (provider != defaultProvider && keys.containsKey(provider)) provider,
    ];
    return [
      for (final provider in order)
        ApiCredentials(provider: provider, key: keys[provider]!),
    ];
  }

  @override
  Future<void> write(ApiCredentials credentials) async {
    if (failWrites) throw Exception('keychain unavailable');
    writes.add(credentials);
    keys[credentials.provider] = credentials.key.trim();
    defaultProvider ??= credentials.provider;
  }

  @override
  Future<void> setDefaultProvider(String provider) async {
    if (failDefault) throw Exception('keychain unavailable');
    promoted.add(provider);
    defaultProvider = provider;
  }

  @override
  Future<void> deleteProvider(String provider) async {
    if (failDeletes) throw Exception('keychain unavailable');
    removed.add(provider);
    keys.remove(provider);
    if (defaultProvider != provider) return;
    final remaining = [
      for (final other in kApiProviders)
        if (keys.containsKey(other)) other,
    ];
    defaultProvider = remaining.isEmpty ? null : remaining.first;
  }

  @override
  Future<void> deleteAll() async {
    keys.clear();
    defaultProvider = null;
  }
}

void main() {
  const gemini = 0;
  const openrouter = 1;
  const nvidia = 2;

  /// Pushes the screen onto a host route, the way Settings does, so that a pop
  /// is a real navigation rather than a no-op on the root route.
  Future<void> pumpScreen(
    WidgetTester tester,
    FakeApiCredentialStore store,
  ) async {
    tester.view.physicalSize = const Size(800, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(ProviderScope(
      overrides: [apiCredentialStoreProvider.overrideWithValue(store)],
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: ElevatedButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const ApiKeyScreen()),
              ),
              child: const Text('HOST'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('HOST'));
    await tester.pumpAndSettle();
  }

  /// The blocks are rendered in [kApiProviders] order, so a provider's field is
  /// reached by its index rather than by hunting for its label.
  Finder keyField(int provider) => find.descendant(
        of: find.byType(MonolithTextField).at(provider),
        matching: find.byType(TextFormField),
      );

  /// The editable inside a provider's field, for asserting what it holds.
  Finder editable(int provider) => find.byType(EditableText).at(provider);

  /// The dialog's confirm action, told apart from the per-provider REMOVE
  /// buttons by being the only one built from a [TextButton].
  final confirmRemove =
      find.widgetWithText(TextButton, ApiKeyScreen.removeLabel);

  group('what it shows', () {
    testWidgets('offers a field for every provider at once', (tester) async {
      await pumpScreen(tester, FakeApiCredentialStore());

      // The whole point of the screen: someone holding three keys enters them
      // in one pass rather than walking back in through Settings twice more.
      expect(find.byType(MonolithTextField), findsNWidgets(3));
      for (final provider in kApiProviders) {
        expect(find.text(provider), findsOneWidget);
      }
    });

    testWidgets('never renders a stored key into a field', (tester) async {
      await pumpScreen(
        tester,
        FakeApiCredentialStore(keys: {'GEMINI': 'sk-secret-value'}),
      );

      // A secret the user cannot act on seeing, on a screen that can be
      // shoulder-surfed or screenshotted, is cost with no benefit.
      expect(find.text('sk-secret-value'), findsNothing);
      for (final field in tester.widgetList<EditableText>(
        find.byType(EditableText),
      )) {
        expect(field.controller.text, isEmpty);
      }
    });

    testWidgets('names the key every scan starts with', (tester) async {
      await pumpScreen(
        tester,
        FakeApiCredentialStore(keys: {'NVIDIA NIM': 'nv-1'}),
      );

      expect(find.text('EVERY SCAN USES NVIDIA NIM'), findsOneWidget);
    });

    testWidgets('spells out the order when there are fallbacks',
        (tester) async {
      await pumpScreen(
        tester,
        FakeApiCredentialStore(
          keys: {'GEMINI': 'g', 'OPENROUTER': 'or'},
          defaultProvider: 'OPENROUTER',
        ),
      );

      // Which key is in use is the question this screen exists to answer, and
      // with fallbacks in play the answer is a sequence, not a name.
      expect(find.text('EVERY SCAN TRIES OPENROUTER → GEMINI'), findsOneWidget);
    });

    testWidgets('says so when there is nothing to scan with', (tester) async {
      await pumpScreen(tester, FakeApiCredentialStore());

      expect(find.text(ApiKeyScreen.noKeysLine), findsOneWidget);
    });

    testWidgets('badges the leader, the fallbacks and the empty slots',
        (tester) async {
      await pumpScreen(
        tester,
        FakeApiCredentialStore(
          keys: {'GEMINI': 'g', 'OPENROUTER': 'or'},
          defaultProvider: 'GEMINI',
        ),
      );

      expect(find.text(ApiKeyScreen.activeBadge), findsOneWidget);
      expect(find.text(ApiKeyScreen.fallbackBadge), findsOneWidget);
      expect(find.text(ApiKeyScreen.notSetBadge), findsOneWidget);
    });

    testWidgets('treats a provider with no key as not set', (tester) async {
      // Half a credential authenticates nothing, so naming the provider alone
      // would imply a working key.
      await pumpScreen(
        tester,
        FakeApiCredentialStore(defaultProvider: 'GEMINI'),
      );

      expect(find.text(ApiKeyScreen.notSetBadge), findsNWidgets(3));
      expect(find.text(ApiKeyScreen.noKeysLine), findsOneWidget);
    });
  });

  group('saving', () {
    testWidgets('writes all three keys in one pass', (tester) async {
      final store = FakeApiCredentialStore();
      await pumpScreen(tester, store);

      await tester.enterText(keyField(gemini), 'g-key');
      await tester.enterText(keyField(openrouter), 'or-key');
      await tester.enterText(keyField(nvidia), 'nv-key');
      await tester.tap(find.text(ApiKeyScreen.saveLabel));
      await tester.pumpAndSettle();

      expect(
        {for (final w in store.writes) w.provider: w.key},
        {'GEMINI': 'g-key', 'OPENROUTER': 'or-key', 'NVIDIA NIM': 'nv-key'},
      );
    });

    testWidgets('writes only the fields that were filled', (tester) async {
      final store = FakeApiCredentialStore();
      await pumpScreen(tester, store);

      await tester.enterText(keyField(openrouter), 'or-key');
      await tester.tap(find.text(ApiKeyScreen.saveLabel));
      await tester.pumpAndSettle();

      expect(store.writes.single.provider, 'OPENROUTER');
    });

    testWidgets('leaves a stored key alone when its field is empty',
        (tester) async {
      final store = FakeApiCredentialStore(keys: {'GEMINI': 'sk-old'});
      await pumpScreen(tester, store);

      await tester.enterText(keyField(nvidia), 'nv-key');
      await tester.tap(find.text(ApiKeyScreen.saveLabel));
      await tester.pumpAndSettle();

      // An empty field means "leave this one alone", never "delete my key" —
      // removal has its own button, behind a confirmation.
      expect(store.keys['GEMINI'], 'sk-old');
      expect(store.writes.single.provider, 'NVIDIA NIM');
    });

    testWidgets('refuses a save with nothing entered', (tester) async {
      final store = FakeApiCredentialStore(keys: {'GEMINI': 'sk-old'});
      await pumpScreen(tester, store);

      await tester.tap(find.text(ApiKeyScreen.saveLabel));
      await tester.pumpAndSettle();

      expect(store.writes, isEmpty);
      expect(find.text(ApiKeyScreen.errorNothingToSave), findsOneWidget);
    });

    testWidgets('ignores a field holding only whitespace', (tester) async {
      final store = FakeApiCredentialStore();
      await pumpScreen(tester, store);

      await tester.enterText(keyField(gemini), '   ');
      await tester.tap(find.text(ApiKeyScreen.saveLabel));
      await tester.pumpAndSettle();

      expect(store.writes, isEmpty);
    });

    testWidgets('stays put so the new state is visible', (tester) async {
      final store = FakeApiCredentialStore();
      await pumpScreen(tester, store);

      await tester.enterText(keyField(gemini), 'g-key');
      await tester.tap(find.text(ApiKeyScreen.saveLabel));
      await tester.pumpAndSettle();

      // Seeing the badge flip to ACTIVE is the confirmation the save landed,
      // and the user may well want to set a second key straight after.
      expect(find.text(ApiKeyScreen.saveLabel), findsOneWidget);
      expect(find.text('EVERY SCAN USES GEMINI'), findsOneWidget);
    });

    testWidgets('empties a field once its key is stored', (tester) async {
      final store = FakeApiCredentialStore();
      await pumpScreen(tester, store);

      await tester.enterText(keyField(gemini), 'g-key');
      await tester.tap(find.text(ApiKeyScreen.saveLabel));
      await tester.pumpAndSettle();

      expect(tester.widget<EditableText>(editable(gemini)).controller.text,
          isEmpty);
    });

    testWidgets('keeps the typed key and says so when the write fails',
        (tester) async {
      final store = FakeApiCredentialStore()..failWrites = true;
      await pumpScreen(tester, store);

      await tester.enterText(keyField(gemini), 'g-key');
      await tester.tap(find.text(ApiKeyScreen.saveLabel));
      await tester.pumpAndSettle();

      // Clearing the field would report a saved key that vision capture then
      // cannot find, and make the user paste it a second time.
      expect(find.text(ApiKeyScreen.errorSaveFailed), findsOneWidget);
      expect(tester.widget<EditableText>(editable(gemini)).controller.text,
          'g-key');
    });
  });

  group('choosing which key leads', () {
    testWidgets('offers no promotion for a provider with no key',
        (tester) async {
      await pumpScreen(tester, FakeApiCredentialStore());

      expect(find.text(ApiKeyScreen.makeDefaultLabel), findsNothing);
    });

    testWidgets('offers no promotion for the one already leading',
        (tester) async {
      await pumpScreen(
        tester,
        FakeApiCredentialStore(keys: {'GEMINI': 'g'}),
      );

      expect(find.text(ApiKeyScreen.makeDefaultLabel), findsNothing);
    });

    testWidgets('offers it on every saved key that is not leading',
        (tester) async {
      await pumpScreen(
        tester,
        FakeApiCredentialStore(
          keys: {'GEMINI': 'g', 'OPENROUTER': 'or', 'NVIDIA NIM': 'nv'},
          defaultProvider: 'GEMINI',
        ),
      );

      expect(find.text(ApiKeyScreen.makeDefaultLabel), findsNWidgets(2));
    });

    testWidgets('promotes the chosen key and reorders the rest',
        (tester) async {
      final store = FakeApiCredentialStore(
        keys: {'GEMINI': 'g', 'OPENROUTER': 'or'},
        defaultProvider: 'GEMINI',
      );
      await pumpScreen(tester, store);

      await tester.tap(find.text(ApiKeyScreen.makeDefaultLabel));
      await tester.pumpAndSettle();

      expect(store.promoted, ['OPENROUTER']);
      expect(find.text('EVERY SCAN TRIES OPENROUTER → GEMINI'), findsOneWidget);
    });

    testWidgets('keeps the old order and says so when the change fails',
        (tester) async {
      final store = FakeApiCredentialStore(
        keys: {'GEMINI': 'g', 'OPENROUTER': 'or'},
        defaultProvider: 'GEMINI',
      )..failDefault = true;
      await pumpScreen(tester, store);

      await tester.tap(find.text(ApiKeyScreen.makeDefaultLabel));
      await tester.pumpAndSettle();

      expect(find.text(ApiKeyScreen.errorDefaultFailed), findsOneWidget);
      expect(find.text('EVERY SCAN TRIES GEMINI → OPENROUTER'), findsOneWidget);
    });
  });

  group('removing', () {
    testWidgets('offers removal only where there is a key to remove',
        (tester) async {
      await pumpScreen(
        tester,
        FakeApiCredentialStore(keys: {'GEMINI': 'g', 'OPENROUTER': 'or'}),
      );

      expect(find.text(ApiKeyScreen.removeLabel), findsNWidgets(2));
    });

    testWidgets('asks first, naming what scans will do instead',
        (tester) async {
      final store = FakeApiCredentialStore(
        keys: {'GEMINI': 'g', 'OPENROUTER': 'or'},
        defaultProvider: 'GEMINI',
      );
      await pumpScreen(tester, store);

      await tester.tap(find.text(ApiKeyScreen.removeLabel).first);
      await tester.pumpAndSettle();

      // The key cannot be recovered from the app once deleted; the user has to
      // go back to the provider's console for it.
      expect(find.text(ApiKeyScreen.confirmRemoveTitle), findsOneWidget);
      expect(
        find.textContaining('SCANS WILL USE OPENROUTER INSTEAD'),
        findsOneWidget,
      );
      expect(store.removed, isEmpty);
    });

    testWidgets('warns that analysis stops when it is the last key',
        (tester) async {
      await pumpScreen(tester, FakeApiCredentialStore(keys: {'GEMINI': 'g'}));

      await tester.tap(find.text(ApiKeyScreen.removeLabel));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('FOOD ANALYSIS STOPS WORKING'),
        findsOneWidget,
      );
    });

    testWidgets('leaves the key alone when the removal is cancelled',
        (tester) async {
      final store = FakeApiCredentialStore(keys: {'GEMINI': 'g'});
      await pumpScreen(tester, store);

      await tester.tap(find.text(ApiKeyScreen.removeLabel));
      await tester.pumpAndSettle();
      await tester.tap(find.text('CANCEL'));
      await tester.pumpAndSettle();

      expect(store.removed, isEmpty);
      expect(find.text('EVERY SCAN USES GEMINI'), findsOneWidget);
    });

    testWidgets('removes only the provider that was asked for', (tester) async {
      final store = FakeApiCredentialStore(
        keys: {'GEMINI': 'g', 'OPENROUTER': 'or'},
        defaultProvider: 'GEMINI',
      );
      await pumpScreen(tester, store);

      // Two REMOVE buttons, in block order: the second is OPENROUTER's.
      await tester.tap(find.text(ApiKeyScreen.removeLabel).at(1));
      await tester.pumpAndSettle();
      await tester.tap(confirmRemove);
      await tester.pumpAndSettle();

      expect(store.removed, ['OPENROUTER']);
      expect(store.keys['GEMINI'], 'g');
      expect(find.text('EVERY SCAN USES GEMINI'), findsOneWidget);
    });

    testWidgets('hands the lead to a fallback when the leader is removed',
        (tester) async {
      final store = FakeApiCredentialStore(
        keys: {'GEMINI': 'g', 'OPENROUTER': 'or'},
        defaultProvider: 'GEMINI',
      );
      await pumpScreen(tester, store);

      await tester.tap(find.text(ApiKeyScreen.removeLabel).first);
      await tester.pumpAndSettle();
      await tester.tap(confirmRemove);
      await tester.pumpAndSettle();

      expect(find.text('EVERY SCAN USES OPENROUTER'), findsOneWidget);
    });

    testWidgets('stays open so a new key can be entered', (tester) async {
      final store = FakeApiCredentialStore(keys: {'GEMINI': 'g'});
      await pumpScreen(tester, store);

      await tester.tap(find.text(ApiKeyScreen.removeLabel));
      await tester.pumpAndSettle();
      await tester.tap(confirmRemove);
      await tester.pumpAndSettle();

      // Replacing a key is the common reason to remove one; popping would make
      // the user walk back in through Settings.
      expect(find.text(ApiKeyScreen.noKeysLine), findsOneWidget);
      expect(find.text(ApiKeyScreen.removeLabel), findsNothing);
      expect(find.text(ApiKeyScreen.saveLabel), findsOneWidget);
    });

    testWidgets('keeps the key and says so when the removal fails',
        (tester) async {
      final store = FakeApiCredentialStore(keys: {'GEMINI': 'g'})
        ..failDeletes = true;
      await pumpScreen(tester, store);

      await tester.tap(find.text(ApiKeyScreen.removeLabel));
      await tester.pumpAndSettle();
      await tester.tap(confirmRemove);
      await tester.pumpAndSettle();

      // Reporting a removal that did not happen would leave the user believing
      // a key they wanted gone is gone.
      expect(store.keys['GEMINI'], 'g');
      expect(find.text(ApiKeyScreen.errorRemoveFailed), findsOneWidget);
      expect(find.text('EVERY SCAN USES GEMINI'), findsOneWidget);
    });
  });

  group('the reveal toggle', () {
    testWidgets('obscures every field by default', (tester) async {
      await pumpScreen(tester, FakeApiCredentialStore());

      for (final field in tester.widgetList<MonolithTextField>(
        find.byType(MonolithTextField),
      )) {
        expect(field.obscureText, isTrue);
      }
    });

    testWidgets('reveals one field without revealing the others',
        (tester) async {
      await pumpScreen(tester, FakeApiCredentialStore());

      await tester.tap(find.byIcon(Icons.visibility).at(openrouter));
      await tester.pump();

      final fields = tester
          .widgetList<MonolithTextField>(find.byType(MonolithTextField))
          .toList();
      expect(fields[gemini].obscureText, isTrue);
      expect(fields[openrouter].obscureText, isFalse);
      expect(fields[nvidia].obscureText, isTrue);
    });
  });
}
