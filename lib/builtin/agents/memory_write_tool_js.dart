import 'dart:convert';

import '../../domain/long_term_memory.dart' show memoryWriteReceipt;

/// No vault access and no new service: the completed tool call carries the
/// proposal to the app. Only the native review's Save can persist its contents.
String get memoryWriteToolJavascript =>
    '''
const memoryWriteReceipt = ${jsonEncode(memoryWriteReceipt)};
$_javascript
''';

const _javascript = r'''
const memoryWriteTool = {
  name: 'memory_write',
  description: 'Propose durable memories in OpenCode Plus ONLY when the user '
    + 'explicitly asks to remember something or summarize this conversation into memory. '
    + 'Use only facts and preferences the user stated or confirmed, in their language; '
    + 'not speculation, assistant claims, temporary tasks, secrets or credentials. '
    + 'Up to 8 concise entries, at most 1024 UTF-8 bytes each. '
    + 'scope=project means this conversation\'s project; scope=global means all projects. '
    + 'The tool returns immediately and does NOT save: the person reviews, edits, '
    + 'selects and explicitly saves in the app. End your turn after submitting. '
    + 'Never claim the memories have been saved. If none qualify, explain without calling.',
  inputSchema: {
    type: 'object', additionalProperties: false, required: ['memories', 'scope'],
    properties: {
      memories: {type: 'array', minItems: 1, maxItems: 8,
        items: {type: 'string', minLength: 1, maxLength: 1024}},
      scope: {type: 'string', enum: ['global', 'project']}
    }
  },
  annotations: {readOnlyHint: true, destructiveHint: false,
    idempotentHint: false, openWorldHint: false}
};
function validateMemoryWrite(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)
      || Object.keys(value).length !== 2 || !['global', 'project'].includes(value.scope)
      || !Array.isArray(value.memories) || value.memories.length < 1 || value.memories.length > 8
      || value.memories.some(text => typeof text !== 'string' || !text.trim()
        || Buffer.byteLength(text, 'utf8') > 1024)) throw new Error('Invalid memory proposal');
}
''';
