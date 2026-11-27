import 'dart:convert';

import 'server_gateway.dart';
import 'settings_scope.dart';

class SubagentSettingsServer {
  const SubagentSettingsServer({
    required this.profileID,
    required this.binding,
    required this.name,
  });
  final String profileID;
  final String binding;
  final String name;
}

class SubagentSettingsCatalog {
  SubagentSettingsCatalog({
    required Iterable<CatalogModel> models,
    required Iterable<WorkspaceProject> projects,
  }) : models = List.unmodifiable(models),
       projects = List.unmodifiable(projects) {
    final ids = <String>{};
    for (final project in this.projects) {
      SubagentModelCandidate.validateID(project.id);
      if (!ids.add(project.id)) {
        throw const FormatException('Duplicate project');
      }
    }
    final modelIDs = <String>{};
    for (final model in this.models) {
      final candidate = SubagentModelCandidate(
        providerID: model.providerID,
        modelID: model.id,
      );
      if (!modelIDs.add(candidate.key)) {
        throw const FormatException('Duplicate model');
      }
      final variants = <String>{};
      for (final variant in model.variants) {
        SubagentModelCandidate.validateID(variant.id);
        if (!variants.add(variant.id)) {
          throw const FormatException('Duplicate variant');
        }
      }
    }
  }

  final List<CatalogModel> models;
  final List<WorkspaceProject> projects;

  Map<SubagentModelCandidate, String> get candidates => {
    for (final model in models)
      if (model.enabled) ...{
        SubagentModelCandidate(providerID: model.providerID, modelID: model.id):
            model.name,
        for (final variant in model.variants)
          if (!variant.disabled)
            SubagentModelCandidate(
              providerID: model.providerID,
              modelID: model.id,
              variant: variant.id,
            ): model.name,
      },
  };
}

/// An exact candidate, including the variant. A missing variant permits only
/// the model's default, not every variant a provider might add later.
class SubagentModelCandidate {
  SubagentModelCandidate({
    required this.providerID,
    required this.modelID,
    this.variant,
  }) {
    validateID(providerID);
    validateID(modelID);
    if (variant != null) validateID(variant!);
  }

  final String providerID;
  final String modelID;
  final String? variant;

  /// Structured identity: model IDs may themselves contain slashes.
  String get key => jsonEncode([providerID, modelID, variant]);
  String get label =>
      '$providerID/$modelID${variant == null ? '' : '#$variant'}';

  static void validateID(String value) {
    if (value.isEmpty ||
        value.length > 1024 ||
        value.trim() != value ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(value)) {
      throw const FormatException('Invalid subagent identifier');
    }
  }

  Map<String, Object?> toJson() => {
    'providerID': providerID,
    'modelID': modelID,
    if (variant != null) 'variant': variant,
  };

  factory SubagentModelCandidate.fromJson(Object? value) {
    if (value is! Map ||
        value['providerID'] is! String ||
        value['modelID'] is! String ||
        (value.containsKey('variant') && value['variant'] is! String)) {
      throw const FormatException('Invalid subagent candidate');
    }
    return SubagentModelCandidate(
      providerID: value['providerID'] as String,
      modelID: value['modelID'] as String,
      variant: value['variant'] as String?,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SubagentModelCandidate &&
      providerID == other.providerID &&
      modelID == other.modelID &&
      variant == other.variant;

  @override
  int get hashCode => Object.hash(providerID, modelID, variant);
}

/// Deliberately separate from ModelLibrary's picker visibility preferences.
/// Empty means no candidates, never "all models". This is a local draft,
/// not proof that the engine enforces an allowlist.
class SubagentModelPool {
  SubagentModelPool(Iterable<SubagentModelCandidate> candidates)
    : candidates = List.unmodifiable(candidates) {
    if (this.candidates.length > maxCandidates ||
        this.candidates.toSet().length != this.candidates.length) {
      throw const FormatException('Invalid subagent model pool');
    }
  }

  /// A storage bound, not a concurrency limit.
  static const maxCandidates = 1000;
  final List<SubagentModelCandidate> candidates;

  bool contains(SubagentModelCandidate candidate) =>
      candidates.contains(candidate);

  List<Map<String, Object?>> toJson() => [
    for (final candidate in candidates) candidate.toJson(),
  ];

  factory SubagentModelPool.fromJson(Object? value) {
    if (value is! List || value.length > maxCandidates) {
      throw const FormatException('Invalid subagent model pool');
    }
    return SubagentModelPool(value.map(SubagentModelCandidate.fromJson));
  }
}

/// Acknowledged local storage only. No "applied" flag is persisted: reconnects
/// and app restarts must never manufacture a server enforcement receipt.
class SubagentSettingsSnapshot {
  const SubagentSettingsSnapshot({
    required this.target,
    required this.pool,
    required this.inherited,
    required this.stored,
    required this.revision,
  });

  final SettingsTarget target;
  final SubagentModelPool pool;
  final bool inherited;
  final bool stored;
  final int revision;
}

enum SubagentSettingsFailure {
  unavailable,
  corrupt,
  staleTarget,
  conflict,
  storageFailed,
}

class SubagentSettingsException implements Exception {
  const SubagentSettingsException(this.reason);
  final SubagentSettingsFailure reason;

  @override
  String toString() => 'SubagentSettingsException(${reason.name})';
}
