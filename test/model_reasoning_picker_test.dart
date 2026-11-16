import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:opencode_mobile/background/live_background.dart';
import 'package:opencode_mobile/domain/models.dart';
import 'package:opencode_mobile/domain/server_gateway/value_types_core.dart';
import 'package:opencode_mobile/state/connection.dart';
import 'package:opencode_mobile/state/profiles.dart';
import 'package:opencode_mobile/ui/widgets/pickers.dart';

CatalogSnapshot _catalog({bool maxAvailable = false}) => CatalogSnapshot(
  providers: const [CatalogProvider(id: 'new-proxy', name: 'New proxy', enabled: true)],
  agents: const [],
  models: [CatalogModel(
    id: 'opaque-model', providerID: 'new-proxy', name: 'Opaque model',
    enabled: true, status: 'active', contextLimit: 200000, outputLimit: 32000,
    reasoning: true, attachments: false, tools: true,
    variants: [
      const CatalogVariant(id: 'high', options: {'reasoningEffort': 'high'}),
      if (maxAvailable) const CatalogVariant(id: 'max', options: {'reasoningEffort': 'max'}),
    ],
  )],
);

void main() {
  late ConnectionController connection;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    connection = ConnectionController(
      ProfileStore(prefs: prefs),
      isIsolated: true,
      backgroundLive: BackgroundLiveController(
        preferences: prefs,
        invoke: (method, [arguments]) async => const {},
      ),
    )
      ..catalog = _catalog()
      ..selectedModel = ModelRef(providerID: 'new-proxy', modelID: 'opaque-model')
      ..selectedVariant = 'high';
  });
  tearDown(() => connection.dispose());

  Future<void> mount(
    WidgetTester tester, {
    Future<void> Function(ModelRef, String)? save,
    VoidCallback? applied,
  }) => tester.pumpWidget(MaterialApp(
    home: Scaffold(body: ModelCatalogView(
      controller: connection,
      saveReasoningEffort: save,
      onApplied: applied,
    )),
  ));

  Future<void> chooseMax(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('model-picker-thinking')));
    await tester.pumpAndSettle();
    final option = find.byKey(const ValueKey('model-extra-effort-max'));
    expect(option, findsOneWidget);
    await tester.ensureVisible(option);
    await tester.tap(option);
    await tester.pumpAndSettle();
  }

  Future<void> apply(WidgetTester tester) async {
    final button = find.byKey(const ValueKey('use-model-new-proxy-opaque-model'));
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pumpAndSettle();
  }

  testWidgets('Max is visible and saved before changing the selection', (tester) async {
    final writes = <String>[];
    var applied = 0;
    await mount(tester, save: (model, effort) async {
      expect(connection.selectedVariant, 'high');
      writes.add('${model.wireName}#$effort');
      connection.catalog = _catalog(maxAvailable: true);
    }, applied: () => applied++);
    await tester.pumpAndSettle();
    await chooseMax(tester);
    expect(connection.selectedVariant, 'high', reason: 'choosing a draft is not a save');
    await apply(tester);
    expect(writes, ['new-proxy/opaque-model#max']);
    expect(connection.selectedVariant, 'max');
    expect(applied, 1);
    await tester.tap(find.byKey(const Key('model-picker-thinking')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('model-variant-opaque-model-max')), findsOneWidget);
    expect(find.byKey(const ValueKey('model-extra-effort-max')), findsNothing);
  });

  testWidgets('saving fails without pretending that Max was applied', (tester) async {
    var applied = 0;
    await mount(tester, save: (_, _) async { throw StateError('fixture write refused'); },
        applied: () => applied++);
    await tester.pumpAndSettle();
    await chooseMax(tester);
    await apply(tester);
    expect(connection.selectedVariant, 'high');
    expect(applied, 0);
    expect(find.textContaining('Could not save the reasoning level'), findsOneWidget);
  });

  testWidgets('reload must actually advertise Max before it can be selected', (tester) async {
    var applied = 0;
    await mount(tester, save: (_, _) async {}, applied: () => applied++);
    await tester.pumpAndSettle();
    await chooseMax(tester);
    await apply(tester);
    expect(connection.selectedVariant, 'high');
    expect(applied, 0);
    expect(find.textContaining('the server has not loaded this reasoning level'), findsOneWidget);
  });

  testWidgets('does not apply to a different project after the write awaits', (tester) async {
    await mount(tester, save: (_, _) async {
      connection.locationRevision++;
      connection.catalog = _catalog(maxAvailable: true);
    });
    await tester.pumpAndSettle();
    await chooseMax(tester);
    await apply(tester);
    expect(connection.selectedVariant, 'high');
  });

  testWidgets('read-only servers do not get a fake working Max option', (tester) async {
    await mount(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('model-picker-thinking')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('model-extra-effort-max')), findsNothing);
  });

  testWidgets('a missing selection remains named rather than becoming Default', (tester) async {
    connection.selectedVariant = 'max';
    await mount(tester);
    await tester.pumpAndSettle();
    expect(find.textContaining('max · unavailable'), findsNothing);
    expect(find.textContaining('Max · unavailable'), findsOneWidget);
    await tester.tap(find.byKey(const Key('model-picker-thinking')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('model-variant-unavailable')), findsOneWidget);
    expect(connection.selectedVariant, 'max');
  });
}
