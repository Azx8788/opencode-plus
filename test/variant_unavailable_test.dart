import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/api2/events.dart';
import 'package:opencode_mobile/api2/gateway_events.dart';
import 'package:opencode_mobile/domain/models.dart';

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
    expect(
      sessionErrorFallbackText('VariantUnavailableError'),
      isNot(contains('will use the model default')),
    );
  });

  test('model and provider changes invalidate the picker catalog', () {
    final adapter = Api2EventAdapter();
    for (final type in ['model.updated', 'provider.updated']) {
      final event = Api2EventEnvelope.fromJson({'type': type, 'data': {}});
      expect(event.event, isA<Api2RefreshHintEvent>());
      expect(adapter.adapt(event).single.type, 'catalog.updated');
    }
  });
}
