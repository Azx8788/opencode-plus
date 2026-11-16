import 'dart:convert';

/// One prompt this app observed leaving for an OpenCode 2 server.
///
/// The timestamp and model choice are recorded at dispatch, from the app's
/// own action, not estimated from a later reply. The log deliberately holds
/// no prompt text, no attachment and no credential. A missing model means
/// the server made the choice and the app did not override it; it is not a
/// fabricated model name.
class RequestLogEntry {
  const RequestLogEntry({
    required this.id,
    required this.at,
    required this.profileID,
    required this.sessionID,
    this.providerID,
    this.modelID,
    this.agent,
    this.variant,
  });

  final String id;
  final int at;
  final String profileID;
  final String sessionID;
  final String? providerID, modelID, agent, variant;

  String get modelLabel => [
    if (providerID != null && providerID!.isNotEmpty) providerID!,
    if (modelID != null && modelID!.isNotEmpty) modelID!,
    if (variant != null && variant!.isNotEmpty) variant!,
  ].join('/');

  Map<String, Object?> toJson() => {
    'id': id,
    'at': at,
    'profileID': profileID,
    'sessionID': sessionID,
    if (providerID != null) 'providerID': providerID,
    if (modelID != null) 'modelID': modelID,
    if (agent != null) 'agent': agent,
    if (variant != null) 'variant': variant,
  };

  factory RequestLogEntry.fromJson(Object? raw) {
    if (raw is! Map ||
        raw['id'] is! String ||
        (raw['id'] as String).isEmpty ||
        raw['at'] is! int ||
        raw['profileID'] is! String ||
        raw['sessionID'] is! String ||
        (raw['profileID'] as String).isEmpty ||
        (raw['sessionID'] as String).isEmpty) {
      throw const FormatException('Invalid request log entry');
    }
    String? text(String key) =>
        raw[key] is String && (raw[key] as String).isNotEmpty
        ? raw[key] as String
        : null;
    return RequestLogEntry(
      id: raw['id'],
      at: raw['at'],
      profileID: raw['profileID'],
      sessionID: raw['sessionID'],
      providerID: text('providerID'),
      modelID: text('modelID'),
      agent: text('agent'),
      variant: text('variant'),
    );
  }
}

/// A bounded, strictly parsed snapshot. Corrupt or older-shape data fails
/// closed: the page says the log is unreadable rather than inventing rows.
class RequestLogSnapshot {
  const RequestLogSnapshot({required this.entries});
  static const maxEntries = 2000;
  final List<RequestLogEntry> entries;

  List<RequestLogEntry> forProfile(String profileID) =>
      List.unmodifiable(entries.where((entry) => entry.profileID == profileID));

  String encode() => jsonEncode(entries.map((e) => e.toJson()).toList());

  factory RequestLogSnapshot.decode(String value) {
    final raw = jsonDecode(value);
    if (raw is! List || raw.length > maxEntries) {
      throw const FormatException('Invalid request log');
    }
    return RequestLogSnapshot(
      entries: List.unmodifiable(raw.map(RequestLogEntry.fromJson)),
    );
  }
}
