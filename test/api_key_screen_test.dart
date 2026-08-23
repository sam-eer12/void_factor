import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:void_factor/features/food_log/api_credentials.dart';
import 'package:void_factor/screens/settings/api_key_screen.dart';
import 'package:void_factor/theme/monolith_theme.dart';
import 'package:void_factor/widgets/monolith_text_field.dart';

/// In-memory stand-in for the secure store.
///
/// `flutter_secure_storage` is a platform channel and has no implementation
/// under `flutter_test`, so the real store cannot be reached from a widget test
/// at all. This fake is the seam `ApiCredentialStore` was extracted for.
class FakeApiCredentialStore implements ApiCredentialStore {
  FakeApiCredentialStore({this.provider, this.key});

  String? provider;
  String? key;

  /// Every credential handed to [write], in order — so a test can assert what
  /// was written rather than only what ended up stored.
  final List<ApiCredentials> writes = [];
  int deletes = 0;
  bool failWrites = false;
  bool failDeletes = false;

  @override
  Future<ApiCredentials?> read() async {
    final currentProvider = provider;
    final currentKey = key;
    if (currentProvider == null || currentProvider.isEmpty) return null;
    if (currentKey == null || currentKey.isEmpty) return null;
    return ApiCredentials(provider: currentProvider, key: currentKey);
  }

  @override
  Future<String?> readProvider() async => provider;

  @override
  Future<void> write(ApiCredentials credentials) async {
    if (failWrites) throw Exception('keychain unavailable');
    writes.add(credentials);
    provider = credentials.provider;
    key = credentials.key;
  }

  @override
  Future<void> delete() async {
    if (failDeletes) throw Exception('keychain unavailable');
    deletes++;
    provider = null;
    key = null;
  }
}

void main() {
  const saveLabel = 'SAVE KEY';
  const removeLabel = 'REMOVE KEY';

  /// Pushes the screen onto a host route, the way Settings does, so that a pop
  /// after saving is a real navigation rather than a no-op on the root route.
  Future<void> pumpScreen(
    WidgetTester tester,
    FakeApiCredentialStore store,
  ) async {
    tester.view.physicalSize = const Size(800, 1400);
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

  /// The label sits above the field rather than inside it, so reach the editable
  /// widget through the `MonolithTextField` ancestor.
  final keyField = find.descendant(
    of: find.byType(MonolithTextField),
    matching: find.byType(TextFormField),
  );

  /// A provider tile reads as chosen by inverting: filled black, white text.
  bool isSelected(WidgetTester tester, String provider) {
    final container = tester.widget<Container>(find.ancestor(
      of: find.text(provider),
      matching: find.byType(Container),
    ));
    return (container.decoration as BoxDecoration).color ==
        MonolithTheme.primary;
  }

  group('what it shows', () {
    testWidgets('never renders the stored key into the field', (tester) async {
      final store = FakeApiCredentialStore(
        provider: 'GEMINI',
        key: 'sk-secret-value',
      );

      await pumpScreen(tester, store);

      // A secret the user cannot act on seeing, on a screen that can be
      // shoulder-surfed or screenshotted, is cost with no benefit.
      expect(find.text('sk-secret-value'), findsNothing);
      expect(
        tester.widget<EditableText>(find.byType(EditableText)).controller.text,
        isEmpty,
      );
    });

    testWidgets('preselects the provider already configured', (tester) async {
      final store = FakeApiCredentialStore(
        provider: 'OPENROUTER',
        key: 'sk-abc',
      );

      await pumpScreen(tester, store);

      expect(isSelected(tester, 'OPENROUTER'), isTrue);
      expect(isSelected(tester, 'GEMINI'), isFalse);
    });

    testWidgets('falls back to GEMINI when nothing is configured',
        (tester) async {
      await pumpScreen(tester, FakeApiCredentialStore());

      expect(isSelected(tester, 'GEMINI'), isTrue);
    });

    testWidgets('names the provider a key is currently set for',
        (tester) async {
      final store = FakeApiCredentialStore(provider: 'NVIDIA NIM', key: 'nv-1');

      await pumpScreen(tester, store);

      expect(find.text('CURRENTLY SET · NVIDIA NIM'), findsOneWidget);
    });

    testWidgets('says so when no key is set', (tester) async {
      await pumpScreen(tester, FakeApiCredentialStore());

      expect(find.text('NOT SET'), findsOneWidget);
    });

    testWidgets('treats a provider with no key as not set', (tester) async {
      // Half a credential authenticates nothing, so it must not read as
      // configured — the provider name alone would imply a working key.
      final store = FakeApiCredentialStore(provider: 'GEMINI');

      await pumpScreen(tester, store);

      expect(find.text('NOT SET'), findsOneWidget);
      expect(isSelected(tester, 'GEMINI'), isTrue);
    });
  });

  group('saving', () {
    testWidgets('writes the key together with the chosen provider',
        (tester) async {
      final store = FakeApiCredentialStore();
      await pumpScreen(tester, store);

      await tester.enterText(keyField, 'sk-new-key');
      await tester.tap(find.text(saveLabel));
      await tester.pumpAndSettle();

      final written = store.writes.single;
      expect(written.key, 'sk-new-key');
      expect(written.provider, 'GEMINI');
    });

    testWidgets('writes the provider the user picked, not the stored one',
        (tester) async {
      final store = FakeApiCredentialStore(provider: 'GEMINI', key: 'sk-old');
      await pumpScreen(tester, store);

      await tester.tap(find.text('OPENROUTER'));
      await tester.pump();
      await tester.enterText(keyField, 'sk-or-key');
      await tester.tap(find.text(saveLabel));
      await tester.pumpAndSettle();

      expect(store.writes.single.provider, 'OPENROUTER');
      expect(store.writes.single.key, 'sk-or-key');
    });

    testWidgets('rejects an empty key instead of clearing what is stored',
        (tester) async {
      final store = FakeApiCredentialStore(provider: 'GEMINI', key: 'sk-old');
      await pumpScreen(tester, store);

      await tester.tap(find.text(saveLabel));
      await tester.pumpAndSettle();

      // An empty field means "no change", never "delete my key" — removal has
      // its own button, behind a confirmation.
      expect(store.writes, isEmpty);
      expect(store.key, 'sk-old');
      expect(find.text('REQUIRED'), findsOneWidget);
      expect(find.text(saveLabel), findsOneWidget);
    });

    testWidgets('rejects a key that is only whitespace', (tester) async {
      final store = FakeApiCredentialStore(provider: 'GEMINI', key: 'sk-old');
      await pumpScreen(tester, store);

      await tester.enterText(keyField, '   ');
      await tester.tap(find.text(saveLabel));
      await tester.pumpAndSettle();

      expect(store.writes, isEmpty);
      expect(store.key, 'sk-old');
    });

    testWidgets('leaves the screen once the key is saved', (tester) async {
      final store = FakeApiCredentialStore();
      await pumpScreen(tester, store);

      await tester.enterText(keyField, 'sk-new-key');
      await tester.tap(find.text(saveLabel));
      await tester.pumpAndSettle();

      expect(find.text(saveLabel), findsNothing);
    });

    testWidgets('stays put and says so when the write fails', (tester) async {
      final store = FakeApiCredentialStore()..failWrites = true;
      await pumpScreen(tester, store);

      await tester.enterText(keyField, 'sk-new-key');
      await tester.tap(find.text(saveLabel));
      await tester.pumpAndSettle();

      // Popping here would report a saved key that vision capture then cannot
      // find.
      expect(find.text(saveLabel), findsOneWidget);
      expect(find.text(ApiKeyScreen.errorSaveFailed), findsOneWidget);
    });
  });

  group('removing', () {
    testWidgets('offers removal only when there is a key to remove',
        (tester) async {
      await pumpScreen(tester, FakeApiCredentialStore());

      expect(find.text(removeLabel), findsNothing);
    });

    testWidgets('offers removal when a key is set', (tester) async {
      final store = FakeApiCredentialStore(provider: 'GEMINI', key: 'sk-old');

      await pumpScreen(tester, store);

      expect(find.text(removeLabel), findsOneWidget);
    });

    testWidgets('asks before removing', (tester) async {
      final store = FakeApiCredentialStore(provider: 'GEMINI', key: 'sk-old');
      await pumpScreen(tester, store);

      await tester.tap(find.text(removeLabel));
      await tester.pumpAndSettle();

      // The key cannot be recovered from the app once deleted; the user has to
      // go back to the provider's console for it.
      expect(find.text(ApiKeyScreen.confirmRemoveTitle), findsOneWidget);
      expect(store.deletes, 0);
    });

    testWidgets('leaves the key alone when the removal is cancelled',
        (tester) async {
      final store = FakeApiCredentialStore(provider: 'GEMINI', key: 'sk-old');
      await pumpScreen(tester, store);

      await tester.tap(find.text(removeLabel));
      await tester.pumpAndSettle();
      await tester.tap(find.text('CANCEL'));
      await tester.pumpAndSettle();

      expect(store.deletes, 0);
      expect(store.key, 'sk-old');
      expect(find.text('CURRENTLY SET · GEMINI'), findsOneWidget);
    });

    testWidgets('removes the credential once confirmed', (tester) async {
      final store = FakeApiCredentialStore(provider: 'GEMINI', key: 'sk-old');
      await pumpScreen(tester, store);

      await tester.tap(find.text(removeLabel));
      await tester.pumpAndSettle();
      await tester.tap(find.text('REMOVE'));
      await tester.pumpAndSettle();

      expect(store.deletes, 1);
      expect(store.key, isNull);
      expect(store.provider, isNull);
    });

    testWidgets('stays open reporting NOT SET so a new key can be entered',
        (tester) async {
      final store = FakeApiCredentialStore(provider: 'GEMINI', key: 'sk-old');
      await pumpScreen(tester, store);

      await tester.tap(find.text(removeLabel));
      await tester.pumpAndSettle();
      await tester.tap(find.text('REMOVE'));
      await tester.pumpAndSettle();

      // Replacing a key is the common case; popping would make the user walk
      // back in through Settings.
      expect(find.text('NOT SET'), findsOneWidget);
      expect(find.text(removeLabel), findsNothing);
      expect(find.text(saveLabel), findsOneWidget);
    });

    testWidgets('keeps the key and says so when the removal fails',
        (tester) async {
      final store = FakeApiCredentialStore(provider: 'GEMINI', key: 'sk-old')
        ..failDeletes = true;
      await pumpScreen(tester, store);

      await tester.tap(find.text(removeLabel));
      await tester.pumpAndSettle();
      await tester.tap(find.text('REMOVE'));
      await tester.pumpAndSettle();

      // Reporting a removal that did not happen would leave the user believing
      // a key they wanted gone is gone.
      expect(store.key, 'sk-old');
      expect(find.text(ApiKeyScreen.errorRemoveFailed), findsOneWidget);
      expect(find.text('CURRENTLY SET · GEMINI'), findsOneWidget);
    });
  });

  group('the reveal toggle', () {
    testWidgets('obscures what is typed by default', (tester) async {
      await pumpScreen(tester, FakeApiCredentialStore());

      expect(
        tester.widget<MonolithTextField>(find.byType(MonolithTextField))
            .obscureText,
        isTrue,
      );
    });

    testWidgets('reveals the key on request', (tester) async {
      await pumpScreen(tester, FakeApiCredentialStore());

      await tester.tap(find.byIcon(Icons.visibility));
      await tester.pump();

      expect(
        tester.widget<MonolithTextField>(find.byType(MonolithTextField))
            .obscureText,
        isFalse,
      );
      // Pasting a key is error-prone and the field is the only place to check
      // it, so the toggle has to go both ways.
      expect(find.byIcon(Icons.visibility_off), findsOneWidget);
    });
  });
}
