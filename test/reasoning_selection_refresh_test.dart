import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:opencode_mobile/background/live_background.dart';
import 'package:opencode_mobile/domain/models.dart';
import 'package:opencode_mobile/domain/server_gateway.dart';
import 'package:opencode_mobile/state/connection.dart';
import 'package:opencode_mobile/state/profiles.dart';

class _CatalogGateway implements ServerGateway {
  @override
  void close() {}

  @override
  ServerCapabilities get capabilities => const ServerCapabilities(
    providerRuntimeRefresh: false,
  );

  @override
  Future<ProvidersResponse> providers() async => ProvidersResponse(
    providers: [
      ProviderInfo(
        id: 'new-proxy',
        name: 'New proxy',
        modelIDs: const ['opaque-model'],
        modelData: const {
          'opaque-model': {
            'variants': {'high': {'reasoningEffort': 'high'}},
          },
        },
      ),
    ],
  );

  @override
  Future<List<AgentInfo>> agents() async => [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _CatalogOperations implements ServerOperationsGateway {
  @override
  Future<CatalogSnapshot> loadCatalog() async => const CatalogSnapshot(
    providers: [],
    agents: [],
    models: [
      CatalogModel(
        id: 'opaque-model',
        providerID: 'new-proxy',
        name: 'Opaque model',
        enabled: true,
        status: 'active',
        contextLimit: 200000,
        outputLimit: 32000,
        reasoning: true,
        attachments: false,
        tools: true,
        variants: [
          CatalogVariant(id: 'high', options: {'reasoningEffort': 'high'}),
        ],
      ),
    ],
  );

  @override
  Future<List<IntegrationInfo>> listIntegrations() async => [];

  @override
  Future<ChatDefaults> loadChatDefaults() async => const ChatDefaults();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('a metadata refresh cannot silently lower the chosen Max level', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final connection = ConnectionController(
      ProfileStore(prefs: prefs),
      isIsolated: true,
      backgroundLive: BackgroundLiveController(
        preferences: prefs,
        invoke: (method, [arguments]) async => const {},
      ),
    )
      ..api = _CatalogGateway()
      ..repository = _CatalogOperations()
      ..selectedModel = ModelRef(providerID: 'new-proxy', modelID: 'opaque-model')
      ..selectedVariant = 'max';
    addTearDown(connection.dispose);
    await connection.refreshCatalog();
    expect(connection.catalogError, isNull);
    expect(connection.catalog!.models.single.variants.single.id, 'high');
    expect(connection.selectedVariant, 'max');
    expect(connection.selectedModel!.wireName, 'new-proxy/opaque-model');
  });
}
