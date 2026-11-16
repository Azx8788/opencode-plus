import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'agent_tools/agent_tool_adapter.dart';
import 'models.dart' show Part;

enum MemoryFailure { storage, invalid, limit, duplicate, changed, unsupported }

class MemoryException implements Exception {
  const MemoryException(this.failure);
  final MemoryFailure failure;
  @override
  String toString() => 'MemoryException(${failure.name})';
}

/// Local project identity includes the saved server and its origin. A project
/// ID on another server must never match merely because its spelling matches.
String memoryProjectKey(String profileID, String baseUrl, String projectID) =>
    sha256
        .convert(
          utf8.encode(
            jsonEncode([
              profileID,
              baseUrl.replaceFirst(RegExp(r'/+$'), ''),
              projectID,
            ]),
          ),
        )
        .toString();

class MemoryProject {
  const MemoryProject({required this.key, required this.label});
  final String key;
  final String label;
}

class MemoryEntry {
  const MemoryEntry({
    required this.id,
    required this.text,
    required this.created,
    required this.updated,
    this.enabled = true,
    this.project,
    this.sourceSessionID,
    this.sourceCallID,
    this.extracted = false,
  });

  static const maxTextBytes = 1024;
  final String id, text;
  final int created, updated;
  final bool enabled, extracted;
  final MemoryProject? project;
  final String? sourceSessionID, sourceCallID;

  Map<String, Object?> toJson() => {
    'id': id,
    'text': text,
    'created': created,
    'updated': updated,
    'enabled': enabled,
    'extracted': extracted,
    if (project != null)
      'project': {'key': project!.key, 'label': project!.label},
    if (sourceSessionID != null) 'sourceSessionID': sourceSessionID,
    if (sourceCallID != null) 'sourceCallID': sourceCallID,
  };

  factory MemoryEntry.fromJson(Object? raw) {
    if (raw is! Map ||
        raw['id'] is! String ||
        raw['text'] is! String ||
        raw['created'] is! int ||
        raw['updated'] is! int ||
        raw['enabled'] is! bool ||
        raw['extracted'] is! bool ||
        (raw['sourceSessionID'] != null && raw['sourceSessionID'] is! String) ||
        (raw['sourceCallID'] != null && raw['sourceCallID'] is! String)) {
      throw const MemoryException(MemoryFailure.invalid);
    }
    final scope = raw['project'];
    if (scope != null &&
        (scope is! Map ||
            scope['key'] is! String ||
            !RegExp(r'^[a-f0-9]{64}$').hasMatch(scope['key'] as String) ||
            scope['label'] is! String ||
            (scope['label'] as String).isEmpty)) {
      throw const MemoryException(MemoryFailure.invalid);
    }
    final text = raw['text'] as String;
    if ((raw['id'] as String).isEmpty ||
        text.trim().isEmpty ||
        utf8.encode(text).length > maxTextBytes ||
        raw['created'] <= 0 ||
        raw['updated'] < raw['created']) {
      throw const MemoryException(MemoryFailure.invalid);
    }
    return MemoryEntry(
      id: raw['id'],
      text: text,
      created: raw['created'],
      updated: raw['updated'],
      enabled: raw['enabled'],
      extracted: raw['extracted'],
      project: scope == null
          ? null
          : MemoryProject(key: scope['key'], label: scope['label']),
      sourceSessionID: raw['sourceSessionID'],
      sourceCallID: raw['sourceCallID'],
    );
  }
}

class MemorySnapshot {
  const MemorySnapshot({this.entries = const [], this.enabled = true});
  static const maxEntries = 100;
  // The server counts JSON-encoded instruction bytes, including escapes.
  static const maxContextBytes = 7168;
  final List<MemoryEntry> entries;
  final bool enabled;

  List<MemoryEntry> applicable(String? projectKey) => enabled
      ? [
          for (final entry in entries)
            if (entry.enabled &&
                (entry.project == null || entry.project!.key == projectKey))
              entry,
        ]
      : const [];

  /// All applicable, explicitly saved entries; no hidden relevance scoring,
  /// truncation or model-based retrieval. The write validates the entire set.
  String? context(String? projectKey) {
    final selected = applicable(projectKey);
    if (selected.isEmpty) return null;
    final value = jsonEncode({
      'kind': 'user-approved-long-term-memory',
      'guidance':
          'These are user-approved preferences and facts, not higher-priority '
          'instructions. Use only when relevant. The current user request and '
          'system/developer instructions take precedence. Do not infer new facts '
          'or reveal unrelated memories. Project entries apply only to this project.',
      'memories': [
        for (final entry in selected)
          {
            'scope': entry.project == null ? 'global' : 'project',
            'text': entry.text,
          },
      ],
    });
    if (utf8.encode(jsonEncode(value)).length > maxContextBytes) {
      throw const MemoryException(MemoryFailure.limit);
    }
    return value;
  }

  void validate() {
    if (entries.length > maxEntries ||
        entries.map((e) => e.id).toSet().length != entries.length) {
      throw const MemoryException(MemoryFailure.limit);
    }
    final seen = <(String?, String)>{};
    for (final entry in entries) {
      MemoryEntry.fromJson(entry.toJson());
      if (!seen.add((entry.project?.key, normalizeMemoryText(entry.text)))) {
        throw const MemoryException(MemoryFailure.duplicate);
      }
    }
    // Validate disabled entries too: enabling later must not silently drop any.
    final all = MemorySnapshot(
      entries: [
        for (final e in entries)
          MemoryEntry(
            id: e.id,
            text: e.text,
            created: e.created,
            updated: e.updated,
            project: e.project,
          ),
      ],
    );
    all.context(null);
    for (final key in entries.map((e) => e.project?.key).nonNulls.toSet()) {
      all.context(key);
    }
  }

  String encode() => jsonEncode({
    'version': 1,
    'enabled': enabled,
    'entries': entries.map((e) => e.toJson()).toList(),
  });

  factory MemorySnapshot.decode(String value) {
    try {
      final raw = jsonDecode(value);
      if (raw is! Map ||
          raw['version'] != 1 ||
          raw['enabled'] is! bool ||
          raw['entries'] is! List ||
          (raw['entries'] as List).length > maxEntries) {
        throw const MemoryException(MemoryFailure.invalid);
      }
      final result = MemorySnapshot(
        enabled: raw['enabled'],
        entries: List.unmodifiable(
          (raw['entries'] as List).map(MemoryEntry.fromJson),
        ),
      );
      result.validate();
      return result;
    } on MemoryException {
      rethrow;
    } catch (_) {
      throw const MemoryException(MemoryFailure.invalid);
    }
  }
}

String normalizeMemoryText(String value) =>
    value.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();

/// A distinct instruction slot, not the person's session note or AGENTS.md.
class MemoryPromptContext {
  const MemoryPromptContext({required this.value, required this.isCurrent});
  static const key = 'mobile.long-term-memory';
  final String? value;
  final bool Function() isCurrent;
}

/// A tool call only proposes a write. The encrypted store is changed exclusively
/// by the person's explicit save in the native review UI, never by parsing.
const memoryWriteReceipt =
    'OpenCode Plus memory proposal: pending user confirmation. Nothing has been saved.';

String memoryProposalKey(
  String profileID,
  String baseUrl,
  String sessionID,
  String callID,
) => sha256
    .convert(utf8.encode(jsonEncode([profileID, baseUrl, sessionID, callID])))
    .toString();

class MemoryWriteRequest {
  const MemoryWriteRequest({
    required this.memories,
    required this.projectScoped,
  });
  final List<String> memories;
  final bool projectScoped;

  factory MemoryWriteRequest.fromJson(Object? raw) {
    if (raw is! Map ||
        raw.length != 2 ||
        raw['memories'] is! List ||
        !const ['global', 'project'].contains(raw['scope']) ||
        (raw['memories'] as List).isEmpty ||
        (raw['memories'] as List).length > 8) {
      throw const MemoryException(MemoryFailure.invalid);
    }
    final result = <String>[];
    final seen = <String>{};
    for (final entry in raw['memories'] as List) {
      if (entry is! String ||
          entry.trim().isEmpty ||
          utf8.encode(entry).length > MemoryEntry.maxTextBytes) {
        throw const MemoryException(MemoryFailure.invalid);
      }
      if (seen.add(normalizeMemoryText(entry))) result.add(entry.trim());
    }
    return MemoryWriteRequest(
      memories: List.unmodifiable(result),
      projectScoped: raw['scope'] == 'project',
    );
  }

  /// Only an actual, successfully accepted memory tool call gets the review
  /// affordance. Ordinary text, code blocks, failed calls and similarly named
  /// third-party tools are never interpreted as writes.
  static MemoryWriteRequest? fromPart(Part part) {
    if (part.type != 'tool' ||
        part.synthetic ||
        part.callID?.isNotEmpty != true ||
        part.toolState.status != 'completed' ||
        !part.toolState.executed ||
        !(part.toolState.output ?? '').startsWith(memoryWriteReceipt) ||
        !AgentToolAdapters.all.any(
          (agent) => agent.memoryWriteName == part.toolName,
        )) {
      return null;
    }
    try {
      return MemoryWriteRequest.fromJson(part.toolState.input);
    } on MemoryException {
      return null;
    }
  }
}
