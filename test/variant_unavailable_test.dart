import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/domain/models.dart';
import 'package:opencode_mobile/domain/server_gateway/value_types_core.dart';
import 'package:opencode_mobile/state/connection.dart';

CatalogSnapshot _catalog({List<CatalogVariant> variants = const []}) =>
    CatalogSnapshot(
      providers: const [],
      agents: const [],
      models: [
        CatalogModel(
          id: 'gpt-6-astra',
          providerID: 'gpt1',
          name: 'GPT-6 Astra',
          enabled: true,
          status: 'active',
          contextLimit: 1000000,
          outputLimit: 32000,
          reasoning: true,
          attachments: true,
          tools: true,
          variants: variants,
        ),
      ],
    );

void main() {
  test('recognises the server variant-unavailable error', () {
    expect(
      MessageErrorKind.fromName('VariantUnavailableError'),
      MessageErrorKind.variantUnavailable,
    );
    expect(
      MessageErrorKind.refineFromText(
        MessageErrorKind.unknown,
        'Variant unavailable for gpt1/gpt-6-astra: max',
      ),
      MessageErrorKind.variantUnavailable,
    );
  });

  test('gives a useful fallback for a vanished reasoning level', () {
    expect(
      sessionErrorFallbackText('VariantUnavailableError'),
      contains('reasoning level'),
    );
  });

  test('variant availability is model- and provider-scoped', () {
    final model = ModelRef(providerID: 'gpt1', modelID: 'gpt-6-astra');
    expect(
      catalogOffersSessionVariant(
        _catalog(variants: [const CatalogVariant(id: 'max')]),
        model,
        'max',
      ),
      isTrue,
    );
    expect(catalogOffersSessionVariant(_catalog(), model, 'max'), isFalse);
    expect(catalogOffersSessionVariant(_catalog(), model, ''), isTrue);
    expect(
      catalogOffersSessionVariant(
        _catalog(variants: [const CatalogVariant(id: 'max', disabled: true)]),
        model,
        'max',
      ),
      isFalse,
    );
  });
}
