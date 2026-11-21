/// OpenCode V2 executors receive session/message/call/agent identity and cancellation from Core.
const shizukuPluginJs = r'''
import { Plugin } from '@opencode/plugin';
import { createHash } from 'node:crypto';
import { setTimeout as delay } from 'node:timers/promises';
import { nativeTransport, abortError } from './bridge.js';

const terminal = new Set(['succeeded', 'failed', 'denied', 'cancelled', 'unknown']);
const object = value => value !== null && typeof value === 'object' && !Array.isArray(value);
const hash = value => createHash('sha256').update(JSON.stringify(value)).digest('hex');
const failure = (code, operationId, mayHaveRun = false) => ({ protocolVersion: 1, environment: 'android', fallback: false,
  state: mayHaveRun ? 'unknown' : 'not_executed', reason: code,
  ...(!mayHaveRun ? { executionStage: 'not_dispatched' } : {}), ...(operationId ? { operationId } : {}) });
const result = value => ({ content: JSON.stringify(value), metadata: { android: {
  operationId: value.operationId, state: value.state, backend: value.backend, uid: value.uid,
  serviceInstance: value.serviceInstance, elapsedMs: value.elapsedMs, termination: value.termination,
  reason: value.reason, executionStage: value.executionStage, exitCode: value.exitCode,
} } });
function identity(ctx, context, descriptor) {
  const fields = [ctx.location?.directory, context.sessionID, context.messageID, context.id, context.agent];
  if (!fields.every(v => typeof v === 'string' && v.length > 0 && !v.includes('\0'))) throw new Error('Tool caller identity unavailable');
  const scope = { runtimeId: descriptor.runtimeId, directory: fields[0], sessionID: fields[1],
    messageID: fields[2], callID: fields[3], agentID: fields[4] };
  return { source: 'opencode_tool', scope };
}
function permission(ctx, context, action, resources, metadata = {}) {
  return ctx.permission.assert({ sessionID: context.sessionID, agent: context.agent,
    source: { type: 'tool', messageID: context.messageID, id: context.id }, action, resources, save: [], metadata });
}

export function makeTools(ctx, transport = nativeTransport) {
  const call = (descriptor, method, owner, extra = {}, signal) => transport.exchange(descriptor,
    { method, ...owner, ...extra }, { signal });
  const checkAbort = context => { if (context.signal.aborted) throw abortError(); };
  const status = async (_input, context) => {
    await permission(ctx, context, 'shizuku_status', ['*']);
    checkAbort(context);
    try { const d = await transport.describe(); return result(await call(d, 'status', {}, {}, context.signal)); }
    catch (error) { if (context.signal.aborted) throw abortError(); return result(failure(error.code ?? 'android_bridge_unavailable')); }
  };
  const previousResult = async ({ operation_id }, context) => {
    await permission(ctx, context, 'shizuku_result', [operation_id]);
    checkAbort(context);
    try {
      const d = await transport.describe();
      return result(await call(d, 'result', identity(ctx, context, d), { operationId: operation_id }, context.signal));
    } catch (error) {
      if (context.signal.aborted) throw abortError();
      return result(failure(error.code ?? 'result_unavailable', operation_id, true));
    }
  };

  const execute = async (input, context) => {
    if (!object(input) || typeof input.command !== 'string' || input.command.trim().length === 0
        || input.command.includes('\0') || Buffer.byteLength(input.command) > 16384
        || (input.timeout_ms !== undefined && (!Number.isSafeInteger(input.timeout_ms) || input.timeout_ms < 1000 || input.timeout_ms > 120000))) {
      return result(failure('invalid_command'));
    }
    checkAbort(context);
    let descriptor;
    try { descriptor = await transport.describe(); }
    catch (error) { checkAbort(context); return result(failure(error.code ?? 'android_bridge_unavailable')); }
    const owner = identity(ctx, context, descriptor);
    const operationId = hash(owner.scope);
    const args = { operationId, command: input.command, ...(input.timeout_ms !== undefined ? { timeoutMs: input.timeout_ms } : {}) };
    // Preserve the operation reference before Core/Android approval can interrupt
    // the tool. A missing final reply can then be inspected, never resubmitted.
    await context.progress({ status: 'Checking Android command authorization', android: {
      operationId, state: 'queued', executionStage: 'not_dispatched' } });
    let cancellation, submitted = false, permissionPending = false;
    const cancel = () => cancellation ??= (async () => {
      try {
        const d = await transport.describe();
        if (d.runtimeId !== descriptor.runtimeId) return failure('runtime_changed', operationId, submitted);
        return await call(d, 'cancel', owner, { operationId });
      } catch (_) { return failure('cancel_unconfirmed', operationId, submitted); }
    })();
    const onAbort = () => { void cancel(); };
    const watch = async initial => {
      let value = initial;
      const deadline = performance.now() + 255000; // Bounded waiting budget, not a claimed execution time.
      while (!value.error && !terminal.has(value.state)) {
        if (!['queued', 'waiting', 'running'].includes(value.state)) return result(failure('invalid_operation_state', operationId, true));
        await context.progress({ status: value.state === 'waiting' ? 'Waiting for Android confirmation' : 'Android command running',
          android: { operationId, state: value.state, uid: value.uid, backend: value.backend,
            executionStage: value.executionStage } });
        if (performance.now() >= deadline) { await cancel(); return result(failure('execution_result_timeout', operationId, true)); }
        await delay(500, undefined, { signal: context.signal });
        const d = await transport.describe();
        if (d.runtimeId !== descriptor.runtimeId) return result(failure('runtime_changed', operationId, true));
        value = await call(d, 'result', owner, { operationId }, context.signal);
      }
      return result(value);
    };
    context.signal.addEventListener('abort', onAbort, { once: true });
    try {
      if (context.signal.aborted) { await cancel(); throw abortError(); }
      // A replay may only inspect this ID. It never submits a second command after an uncertain dispatch.
      const previous = await call(descriptor, 'lookup', owner, args, context.signal);
      if (!previous.error) {
        permissionPending = true;
        await permission(ctx, context, 'shizuku_result', [operationId]);
        permissionPending = false;
        checkAbort(context);
        submitted = true; // The earlier attempt may already be in flight; only inspect its result.
        return await watch(previous);
      }
      if (previous.error !== 'operation_not_found') return result(previous);
      const ready = await call(descriptor, 'prepare', owner, args, context.signal);
      if (ready.error) return result(ready);
      if (ready.executionReady !== true || ![0, 2000].includes(ready.uid) || typeof ready.serviceInstance !== 'string') {
        return result(failure('execution_handshake_required', operationId));
      }
      // Core permission rules are independent of the Android safety overlay. Saved allows never bypass the latter.
      permissionPending = true;
      await permission(ctx, context, 'shizuku', [input.command], { environment: 'android', uid: ready.uid,
        backend: ready.backend, risk: ready.risk, operationType: ready.operationType });
      permissionPending = false;
      if (context.signal.aborted) { await cancel(); throw abortError(); }
      await context.progress({ status: 'Sending Android command', android: { operationId, state: 'queued',
        uid: ready.uid, backend: ready.backend, executionStage: 'not_dispatched' } });
      checkAbort(context);
      submitted = true; // A transport failure from this point cannot prove that nothing ran.
      let value;
      try {
        value = await call(descriptor, 'submit', owner, { ...args, brokerInstance: ready.brokerInstance,
          serviceInstance: ready.serviceInstance, uid: ready.uid }, context.signal);
      } catch (error) {
        if (context.signal.aborted) throw abortError();
        const d = await transport.describe();
        if (d.runtimeId !== descriptor.runtimeId) return result(failure('runtime_changed', operationId, true));
        value = await call(d, 'result', owner, { operationId }, context.signal);
        if (value.error) return result(failure('execution_result_unconfirmed', operationId, true));
      }
      return await watch(value);
    } catch (error) {
      if (context.signal.aborted || error.name === 'AbortError') { await cancel(); throw abortError(); }
      if (permissionPending) throw error;
      // Do not turn Core permission rejections into successful tool output.
      if (!submitted && !error.code) throw error;
      return result(failure(error.code ?? 'execution_result_unconfirmed', operationId, submitted));
    } finally { context.signal.removeEventListener('abort', onAbort); }
  };
  return [
    { name: 'shizuku_status', description: 'Read this phone\'s real Android Shizuku/Sui authorization, UserService handshake, and execution UID. Ubuntu root is not Android root. Does not grant permissions.',
      input: { type: 'object', properties: {}, additionalProperties: false }, options: { codemode: false, permission: 'shizuku_status' }, execute: status },
    { name: 'shizuku_exec', description: 'Execute a bare command on this phone\'s Android shell through authorized Shizuku/Sui, NOT Ubuntu or a remote server. Do not prepend adb shell. Actual UID is reported (2000 shell or 0 root). Checked reads may run directly; other commands follow the phone\'s risk policy and confirmation. Native refusal reports confirmation_user_denied, confirmation timeout reports confirmation_timeout: neither starts the command. Respect a refusal; do not repeat it or use another channel. No silent fallback. Non-interactive, finite commands only. Cancellation does not undo side effects; unknown or interrupted results are not evidence of refusal and must not be retried automatically. Use shizuku_result to inspect the original operation when its ID is available.',
      input: { type: 'object', properties: { command: { type: 'string', minLength: 1, maxLength: 16384 },
        timeout_ms: { type: 'integer', minimum: 1000, maximum: 120000 } }, required: ['command'], additionalProperties: false },
      options: { codemode: false, permission: 'shizuku' }, execute },
    { name: 'shizuku_result', description: 'Inspect a previous Android operation by the operation_id returned by shizuku_exec, in this same session and agent scope. Never executes or repeats the command. Old output may have expired while its dedup record remains.',
      input: { type: 'object', properties: { operation_id: { type: 'string', pattern: '^[A-Za-z0-9_-]{1,80}$' } }, required: ['operation_id'], additionalProperties: false },
      options: { codemode: false, permission: 'shizuku_result' }, execute: previousResult },
  ];
}

export default Plugin.define({ id: 'mobile-shizuku', async setup(ctx) {
  const registration = await ctx.tool.transform(editor => { for (const tool of makeTools(ctx)) editor.add(tool); });
  return () => registration.dispose();
} });
''';
