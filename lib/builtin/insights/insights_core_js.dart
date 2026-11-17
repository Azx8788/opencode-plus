/// Independent, provider-neutral event projection. Retains timing, identity
/// and structured status only; never prompt text, tool input/output or keys.
const insightsCoreJs = r'''
export function project(event) {
  const d = event.data ?? {}, type = event.type;
  if (!type?.startsWith('session.') || !d.sessionID) return null;
  if (type.endsWith('.delta') || type === 'session.tool.progress') return null;
  const allowed = new Set([
    'session.created','session.deleted','session.inbox.enqueued','session.inbox.delivered',
    'session.inbox.cancelled','session.execution.started','session.execution.succeeded',
    'session.execution.failed','session.execution.interrupted','session.step.started',
    'session.step.first-token','session.step.streamed','session.step.ended','session.step.failed',
    'session.text.started','session.text.ended','session.reasoning.started','session.reasoning.ended',
    'session.tool.input.started','session.tool.input.ended','session.tool.called','session.tool.success',
    'session.tool.failed','session.retry.scheduled',
  ]);
  if (!allowed.has(type)) return null;
  const out = { type, sessionID:d.sessionID };
  if (Number.isSafeInteger(event.created) && event.created > 0) out.at = event.created;
  if (typeof event.id === 'string') out.id = event.id;
  for (const key of ['assistantMessageID','inboxID','callID','parentID','reason']) {
    if (typeof d[key] === 'string') out[key] = d[key];
  }
  for (const key of ['ordinal','attempt','at']) {
    if (Number.isSafeInteger(d[key])) out[key === 'at' ? 'retryAt' : key] = d[key];
  }
  const m = d.model;
  if (m && typeof m.providerID === 'string' && typeof m.id === 'string') {
    out.model = {providerID:m.providerID,id:m.id};
  }
  const metadata = d.item?.payload?.metadata ?? d.item?.metadata ?? event.metadata;
  const task = metadata?.['mobile.task'];
  if (task && typeof task.id === 'string' && ['independent','supplement','pending'].includes(task.intent)) {
    out.task = {id:task.id,intent:task.intent};
  }
  if (d.tokens && typeof d.tokens === 'object') {
    const tokens = {};
    for (const key of ['input','output','reasoning']) if (Number.isSafeInteger(d.tokens[key]) && d.tokens[key]>=0) tokens[key]=d.tokens[key];
    const cache = {};
    for (const key of ['read','write']) if (Number.isSafeInteger(d.tokens.cache?.[key]) && d.tokens.cache[key]>=0) cache[key]=d.tokens.cache[key];
    if (Object.keys(cache).length) tokens.cache=cache;
    if (Object.keys(tokens).length) out.tokens=tokens;
  }
  if (d.error && typeof d.error.type === 'string') {
    out.error = {type:d.error.type};
    if (Number.isSafeInteger(d.error.status)) out.error.status = d.error.status;
  }
  // Exact child identity only, never scan arbitrary output for session IDs.
  const child = d.metadata?.sessionID ?? d.metadata?.sessionId;
  if (typeof child === 'string') out.childSessionID = child;
  return out;
}

export function append(snapshot, event, max = 10000) {
  const item = project(event);
  if (!item || (item.id && snapshot.entries.some(e => e.id === item.id))) return snapshot;
  const seq = snapshot.seq + 1;
  const entries = [...snapshot.entries, {...item,seq}];
  const excess = Math.max(0, entries.length - max);
  return {version:1,seq,entries:entries.slice(excess),truncated:snapshot.truncated || excess > 0};
}
''';
