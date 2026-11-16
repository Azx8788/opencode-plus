import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/api2/gateway_mappers.dart';
import 'package:opencode_mobile/api2/models.dart';
import 'package:opencode_mobile/domain/custom_provider.dart';
import 'package:opencode_mobile/domain/custom_provider_record.dart';
import 'package:opencode_mobile/domain/model_reasoning.dart';
import 'package:opencode_mobile/domain/server_gateway/value_types_core.dart';

CatalogModel _model({
  String provider = 'arbitrary-proxy',
  bool enabled = true,
  List<CatalogVariant> variants = const [
    CatalogVariant(id: 'high', options: {'reasoningEffort': 'high'}),
  ],
}) => CatalogModel(
  id: 'opaque-model',
  providerID: provider,
  name: 'Opaque model',
  enabled: enabled,
  status: 'active',
  contextLimit: 200000,
  outputLimit: 32000,
  reasoning: true,
  attachments: false,
  tools: true,
  variants: variants,
);

Map<String, Object?> _config({
  ProviderConfigFormat format = ProviderConfigFormat.v2,
}) {
  final v2 = format == ProviderConfigFormat.v2;
  return {
    'model': 'other/other-model',
    'mcp': {'servers': {}},
    (v2 ? 'providers' : 'provider'): {
      'arbitrary-proxy': {
        (v2 ? 'package' : 'npm'): v2
            ? 'aisdk:@ai-sdk/openai'
            : '@ai-sdk/openai',
        'name': 'Proxy',
        (v2 ? 'settings' : 'options'): {
          'baseURL': 'https://example.test/v1',
          'apiKey': '{file:/root/.secrets/proxy.key}',
          'timeout': 300000,
          'headers': {'X-Example': 'keep'},
        },
        'models': {
          'opaque-model': {
            'modelID': 'api-model-alias',
            'name': 'Opaque model',
            'limit': {'context': 200000, 'output': 32000},
            'capabilities': {
              'reasoning': {
                'supported': true,
                'effort': ['high'],
              },
              'tools': true,
            },
            'settings': {'serviceTier': 'auto'},
            'body': {'custom': true},
            'variants': v2
                ? [
                    {
                      'id': 'deep',
                      'settings': {'reasoningEffort': 'high'},
                      'headers': {'X-Variant': 'keep'},
                      'body': {'customVariant': true},
                    },
                  ]
                : {
                    'deep': {'reasoningEffort': 'high'},
                  },
          },
          'other-model': {'name': 'Leave this alone'},
        },
      },
      'other': {'name': 'Leave this provider alone'},
    },
  };
}

Map _entry(Map document, {ProviderConfigFormat format = ProviderConfigFormat.v2}) =>
    (document[format == ProviderConfigFormat.v2 ? 'providers' : 'provider']
        as Map)['arbitrary-proxy'] as Map;

Map _savedModel(Map document, {ProviderConfigFormat format = ProviderConfigFormat.v2}) =>
    (_entry(document, format: format)['models'] as Map)['opaque-model'] as Map;

void main() {
  group('generic effort options', () {
    test('one ascending menu keeps both real and extra choices', () {
      final choices = reasoningLevelChoices(_model(), allowOverrides: true);
      expect(choices.map((c) => c.id), reasoningEffortLevels);
      expect(choices.firstWhere((c) => c.id == 'high').requiresSave, isFalse);
      expect(choices.firstWhere((c) => c.id == 'max').requiresSave, isTrue);
    });

    test('existing modes keep their IDs and order without duplicate levels', () {
      final model = _model(variants: const [
        CatalogVariant(id: 'deep-b', options: {'reasoningEffort': 'high'}),
        CatalogVariant(id: 'HIGH', options: {'reasoningEffort': 'high'}),
        CatalogVariant(id: 'deep-a', options: {'reasoningEffort': 'high'}),
        CatalogVariant(id: 'max', disabled: true),
      ]);
      final choices = reasoningLevelChoices(model, allowOverrides: true);
      expect(choices.map((c) => c.id), isNot(contains('max')));
      expect(choices.map((c) => c.id), isNot(contains('high')));
      expect(choices.map((c) => c.id), contains('HIGH'));
      expect(choices.map((c) => c.id).toList().sublist(choices.length - 2),
          ['deep-b', 'deep-a']);
    });

    test('any proxy advertising reasoning effort can request Max', () {
      for (final provider in ['new-proxy', 'another-proxy', 'unknown-123']) {
        expect(additionalReasoningEfforts(_model(provider: provider)), contains('max'));
        expect(additionalReasoningEfforts(_model(provider: provider)), isNot(contains('high')));
      }
    });

    test('does not duplicate known IDs or revive a disabled Max', () {
      final options = additionalReasoningEfforts(_model(variants: const [
        CatalogVariant(id: 'high', options: {'reasoning_effort': 'high'}),
        CatalogVariant(id: 'max', disabled: true),
        CatalogVariant(id: 'my-deep-mode', options: {'reasoningEffort': 'high'}),
      ]));
      expect(options, isNot(contains('max')));
      expect(options, isNot(contains('high')));
      expect(options, contains('xhigh'));
    });

    test('the API mapping keeps explicitly disabled variants disabled', () {
      final wire = Api2ModelInfo.fromJson({
        'id': 'opaque-model',
        'providerID': 'arbitrary-proxy',
        'variants': [
          {'id': 'high', 'settings': {'reasoningEffort': 'high'}},
          {'id': 'max', 'disabled': true, 'settings': {'reasoningEffort': 'max'}},
        ],
      })!;
      final mapped = mapApi2CatalogModel(wire);
      expect(mapped.variants.last.disabled, isTrue);
      expect(additionalReasoningEfforts(mapped), isNot(contains('max')));
    });

    test('no guessing for unknown models or thinking-token budgets', () {
      expect(additionalReasoningEfforts(_model(variants: const [])), isEmpty);
      expect(additionalReasoningEfforts(_model(enabled: false)), isEmpty);
      expect(additionalReasoningEfforts(_model(variants: const [
        CatalogVariant(id: 'high', options: {'thinkingBudget': 16000}),
      ])), isEmpty);
    });
  });

  group('persistent overrides', () {
    test('v2 stores a real variant setting and preserves all other fields', () {
      final before = _config();
      final original = jsonEncode(before);
      final after = withModelReasoningEffort(
        before,
        ProviderConfigFormat.v2,
        providerID: 'arbitrary-proxy',
        modelID: 'opaque-model',
        effort: 'max',
      );
      expect(jsonEncode(before), original, reason: 'never mutate the read snapshot');
      final variants = _savedModel(after)['variants'] as List;
      expect(variants.last, {'id': 'max', 'settings': {'reasoningEffort': 'max'}});
      expect(variants.first, (_savedModel(before)['variants'] as List).first);
      for (final key in ['name', 'modelID', 'limit', 'capabilities', 'body', 'settings']) {
        expect(_savedModel(after)[key], _savedModel(before)[key], reason: key);
      }
      expect(_entry(after)['settings'], _entry(before)['settings']);
      expect((_entry(after)['models'] as Map)['other-model'], (_entry(before)['models'] as Map)['other-model']);
      expect(after['model'], before['model']);
      expect(after['mcp'], before['mcp']);
      expect((after['providers'] as Map)['other'], (before['providers'] as Map)['other']);
      expect(
        identical(withModelReasoningEffort(
          after,
          ProviderConfigFormat.v2,
          providerID: 'arbitrary-proxy',
          modelID: 'opaque-model',
          effort: 'max',
        ), after),
        isTrue,
        reason: 'reopening and applying Max does not rewrite the file again',
      );
    });

    test('v1 writes keyed variants rather than a v2 array', () {
      final before = _config(format: ProviderConfigFormat.v1);
      final after = withModelReasoningEffort(
        before,
        ProviderConfigFormat.v1,
        providerID: 'arbitrary-proxy',
        modelID: 'opaque-model',
        effort: 'max',
      );
      expect((_savedModel(after, format: ProviderConfigFormat.v1)['variants'] as Map)['max'], {'reasoningEffort': 'max'});
      expect(_entry(after, format: ProviderConfigFormat.v1)['options'], _entry(before, format: ProviderConfigFormat.v1)['options']);
    });

    test('a catalog model need not have a model-specific config yet', () {
      final before = _config();
      final after = withModelReasoningEffort(
        before,
        ProviderConfigFormat.v2,
        providerID: 'arbitrary-proxy',
        modelID: 'catalog-only-model',
        effort: 'max',
      );
      expect((_entry(after)['models'] as Map)['catalog-only-model'], {
        'variants': [{'id': 'max', 'settings': {'reasoningEffort': 'max'}}],
      });
    });

    test('does not replace an existing disabled/custom Max setting', () {
      final before = _config();
      _savedModel(before)['variants'] = [
        {'id': 'max', 'disabled': true, 'settings': {'custom': 'keep'}},
      ];
      expect(identical(withModelReasoningEffort(
        before,
        ProviderConfigFormat.v2,
        providerID: 'arbitrary-proxy',
        modelID: 'opaque-model',
        effort: 'max',
      ), before), isTrue);
    });

    test('invalid inputs are refused without modifying the configuration', () {
      final before = _config();
      final original = jsonEncode(before);
      for (final provider in ['arbitrary-proxy', 'missing-provider']) {
        expect(() => withModelReasoningEffort(
          before,
          ProviderConfigFormat.v2,
          providerID: provider,
          modelID: 'opaque-model',
          effort: provider == 'arbitrary-proxy' ? 'invented-effort' : 'max',
        ), throwsException);
      }
      expect(jsonEncode(before), original);
    });
  });

  group('provider form round trip', () {
    test('save/read/edit/save keeps Max, custom capabilities and alias', () {
      final initial = withModelReasoningEffort(
        _config(),
        ProviderConfigFormat.v2,
        providerID: 'arbitrary-proxy',
        modelID: 'opaque-model',
        effort: 'max',
      );
      final record = readCustomProviders(initial, ProviderConfigFormat.v2).records.single;
      final edited = record.toDraft().mergeInto(initial, ProviderConfigFormat.v2, replace: true);
      expect(_savedModel(edited)['variants'], _savedModel(initial)['variants']);
      expect(_savedModel(edited)['modelID'], 'api-model-alias');
      expect((_savedModel(edited)['capabilities'] as Map)['reasoning'], (_savedModel(initial)['capabilities'] as Map)['reasoning']);
      expect(_savedModel(edited)['settings'], {'serviceTier': 'auto'});
      expect(_savedModel(edited)['body'], {'custom': true});
      expect((_entry(edited)['settings'] as Map)['apiKey'], '{file:/root/.secrets/proxy.key}');
    });

    test('fetching models with an empty draft does not erase variant settings', () {
      final before = _config();
      final draft = CustomProviderDraft(
        name: 'Proxy', id: 'arbitrary-proxy',
        protocol: ProviderProtocol.responses,
        baseUrl: 'https://example.test/v1',
        keyMode: ProviderKeyMode.external,
      );
      final after = draft.mergeInto(before, ProviderConfigFormat.v2, replace: true, requireModels: false);
      expect(_savedModel(after)['variants'], _savedModel(before)['variants']);
      expect(_entry(after)['models'], _entry(before)['models']);
    });

    test('editable keys/headers and disabled flags still change normally', () {
      final before = _config();
      _savedModel(before)['disabled'] = true;
      final draft = CustomProviderDraft(
        name: 'Proxy', id: 'arbitrary-proxy',
        protocol: ProviderProtocol.responses,
        baseUrl: 'https://new.example.test/v1',
        apiKey: 'fixture-new-key', keyMode: ProviderKeyMode.plaintext,
        models: const [CustomProviderModel(id: 'opaque-model')],
        disabledModelIDs: const ['other-model'],
      );
      final after = draft.mergeInto(before, ProviderConfigFormat.v2, replace: true);
      final settings = _entry(after)['settings'] as Map;
      expect(settings['apiKey'], 'fixture-new-key');
      expect(settings['baseURL'], 'https://new.example.test/v1');
      expect(settings.containsKey('headers'), isFalse);
      expect(_savedModel(after).containsKey('disabled'), isFalse);
      expect(((_entry(after)['models'] as Map)['other-model'] as Map)['disabled'], isTrue);
      expect(_savedModel(after)['variants'], _savedModel(before)['variants']);
    });
  });
}
