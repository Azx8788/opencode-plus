import 'custom_provider.dart';
import 'server_gateway/value_types_catalog.dart' show ProductException;
import 'server_gateway/value_types_core.dart';

/// Effort identifiers understood by OpenAI-style reasoning controls. These are
/// explicit request overrides, not claims about what every model supports.
const reasoningEffortLevels = [
  'none',
  'minimal',
  'low',
  'medium',
  'high',
  'xhigh',
  'max',
];

/// Offer additions only for models already advertising an effort control.
/// Token-budget variants (e.g. thinkingBudget) are a different protocol.
/// Explicitly disabled variants remain disabled, and custom IDs stay intact.
List<String> additionalReasoningEfforts(CatalogModel model) {
  if (!model.enabled ||
      !model.variants.any(
        (v) => !v.disabled &&
            reasoningEffortLevels.contains(v.reasoningEffort?.toLowerCase()),
      )) {
    return const [];
  }
  final known = model.variants.map((v) => v.id.toLowerCase()).toSet();
  return [for (final id in reasoningEffortLevels) if (!known.contains(id)) id];
}

/// One choice in the single reasoning-level menu. The original variant ID and
/// settings are retained; additions still require persistence before use.
class ReasoningLevelChoice {
  const ReasoningLevelChoice({required this.id, this.variant});
  final String id;
  final CatalogVariant? variant;
  bool get requiresSave => variant == null;
}

/// A compact ascending list, not separate "native" and "custom" menus.
/// Unknown server variants remain selectable, in their original relative
/// order after the standard effort IDs. Disabled IDs are never added back.
List<ReasoningLevelChoice> reasoningLevelChoices(
  CatalogModel model, {
  bool allowOverrides = false,
}) {
  final seen = <String>{};
  final disabled = {
    for (final variant in model.variants)
      if (variant.disabled) variant.id,
  };
  final choices = <ReasoningLevelChoice>[
    for (final variant in model.variants)
      if (!variant.disabled &&
          !disabled.contains(variant.id) &&
          seen.add(variant.id))
        ReasoningLevelChoice(id: variant.id, variant: variant),
    if (allowOverrides)
      for (final id in additionalReasoningEfforts(model))
        ReasoningLevelChoice(id: id),
  ];
  final order = {
    for (final (index, choice) in choices.indexed) choice.id: index,
  };
  int rank(String id) {
    final index = reasoningEffortLevels.indexOf(id.toLowerCase());
    return index < 0 ? reasoningEffortLevels.length : index;
  }
  choices.sort((a, b) {
    final level = rank(a.id).compareTo(rank(b.id));
    return level != 0 ? level : order[a.id]!.compareTo(order[b.id]!);
  });
  return choices;
}

/// Persist one explicit effort override into the server's existing provider.
/// No provider/model-name heuristics, and no project-local shadow config.
/// Existing variants (including their bodies/headers) win over this addition.
Map<String, Object?> withModelReasoningEffort(
  Map<String, Object?> document,
  ProviderConfigFormat format, {
  required String providerID,
  required String modelID,
  required String effort,
}) {
  if (!reasoningEffortLevels.contains(effort) || modelID.trim().isEmpty) {
    throw const ProductException('Invalid reasoning level');
  }
  final root = format == ProviderConfigFormat.v2 ? 'providers' : 'provider';
  final providers = document[root];
  if (providers is! Map) {
    throw const ProductException('The provider list is not an object');
  }
  final provider = providers[providerID];
  if (provider is! Map) {
    throw const ProductException('The provider is not in this configuration');
  }
  final models = provider['models'];
  if (models != null && models is! Map) {
    throw const ProductException('The provider model list is not an object');
  }
  final existing = models is Map ? models[modelID] : null;
  if (existing != null && existing is! Map) {
    throw const ProductException('The model configuration is not an object');
  }
  final model = <String, Object?>{
    if (existing is Map) ...existing.cast<String, Object?>(),
  };
  final variants = model['variants'];
  if (format == ProviderConfigFormat.v2) {
    if (variants != null && variants is! List) {
      throw const ProductException('The model variants are not a list');
    }
    final list = variants as List? ?? const [];
    if (list.any((v) => v is Map && v['id'] == effort)) return document;
    model['variants'] = [
      ...list,
      {'id': effort, 'settings': {'reasoningEffort': effort}},
    ];
  } else {
    if (variants != null && variants is! Map) {
      throw const ProductException('The model variants are not an object');
    }
    final map = variants as Map? ?? const {};
    if (map.containsKey(effort)) return document;
    model['variants'] = {...map, effort: {'reasoningEffort': effort}};
  }
  return {
    ...document,
    root: {
      ...providers.cast<String, Object?>(),
      providerID: {
        ...provider,
        'models': {if (models is Map) ...models, modelID: model},
      },
    },
  };
}
