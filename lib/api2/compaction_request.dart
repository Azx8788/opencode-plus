import '../domain/server_gateway.dart' show CompactOptions, ServerCapabilities;

/// The body a compaction request carries for [capabilities].
///
/// The pinned OpenCode 2 contract accepts only `{}`. Fields are therefore
/// emitted solely when the connected server advertises the matching
/// capability, so an older server never receives an unknown option.
Map<String, dynamic> compactSessionBody(
  CompactOptions options,
  ServerCapabilities capabilities,
) {
  final body = <String, dynamic>{};
  if (capabilities.compactionOptions) {
    final instructions = options.instructions.trim();
    if (instructions.isNotEmpty) body['instructions'] = instructions;
    if (options.keepTokens != null && options.keepTurns == null) {
      body['keep'] = {'tokens': options.keepTokens};
    }
  }
  if (capabilities.compactionKeepTurns && options.keepTurns != null) {
    body['keepTurns'] = options.keepTurns;
  }
  return body;
}