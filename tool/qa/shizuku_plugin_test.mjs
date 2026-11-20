import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import net from 'node:net';
import { pathToFileURL } from 'node:url';

const directory = process.argv[2];
const { default: plugin, makeTools } = await import(pathToFileURL(path.join(directory, 'index.js')));
const { describe, exchange, BridgeError } = await import(pathToFileURL(path.join(directory, 'bridge.js')));
const descriptor = { protocolVersion: 1, socketPath: '/tmp/.oc-shizuku/s',
  runtimeId: '11111111-1111-1111-1111-111111111111', bridgeInstance: '22222222-2222-2222-2222-222222222222' };
const envelope = data => ({ ...descriptor, environment: 'android', fallback: false, ...data });

function fixture(options = {}) {
  const requests = [], permissions = [], records = new Map();
  const ctx = { location: { directory: '/project' }, permission: { assert: async value => {
    permissions.push(value); if (options.permission) await options.permission(value);
  } } };
  const transport = { describe: async () => descriptor, exchange: async (_d, request, _opts) => {
    requests.push(structuredClone(request));
    const existing = records.get(request.operationId);
    switch (request.method) {
      case 'lookup':
        if (existing && existing.command !== undefined && existing.command !== request.command) return envelope({ error: 'operation_conflict', state: 'not_executed' });
        return envelope(existing ?? { error: 'operation_not_found', state: 'not_executed' });
      case 'prepare': return envelope(options.ready ?? { executionReady: true, serviceInstance: 'fixture-service', uid: 2000,
        backend: 'adb', risk: 'green', operationType: 'read_only', automatic: true, brokerInstance: 'fixture-broker' });
      case 'submit': {
        if (existing?.state === 'cancelled') return envelope(existing);
        const value = { command: request.command, operationId: request.operationId, serviceInstance: 'fixture-service', uid: 2000,
          backend: 'adb', state: options.waiting?.(request) ? 'waiting' : 'succeeded', stdout: 'fixture Android output', stderr: '', exitCode: 0,
          elapsedMs: 11, termination: 'not_requested' };
        records.set(request.operationId, value);
        if (options.lostReply) throw new BridgeError('bridge_reply_lost');
        return envelope(value);
      }
      case 'result': return envelope(existing ?? { error: 'operation_not_found', state: 'not_executed' });
      case 'cancel': {
        const value = { ...existing, operationId: request.operationId, state: 'cancelled', termination: 'confirmed' };
        records.set(request.operationId, value); return envelope(value);
      }
      case 'status': return envelope({ executionReady: false, serverUid: 0, uid: null, binding: 'connecting' });
      default: throw new Error('Unexpected native method');
    }
  } };
  const tools = makeTools(ctx, transport);
  const context = (id = 'call1', controller = new AbortController(), onProgress) => ({ sessionID: 'ses1', messageID: 'msg1', id,
    agent: 'build', signal: controller.signal, progress: async data => { if (onProgress) onProgress(data); } });
  return { ctx, tools, context, requests, permissions, records, exec: tools.find(t => t.name === 'shizuku_exec').execute };
}
const output = value => JSON.parse(value.content);

{
  const f = fixture(); let registered;
  let disposed = false;
  f.ctx.tool = { transform: async callback => { registered = []; callback({ add: t => registered.push(t) }); return { dispose: async () => { disposed = true; } }; } };
  const dispose = await plugin.setup(f.ctx);
  assert.deepEqual(registered.map(t => t.name), ['shizuku_status', 'shizuku_exec', 'shizuku_result']);
  assert.ok(registered.every(t => t.options.codemode === false));
  assert.deepEqual(Object.keys(registered[1].input.properties), ['command', 'timeout_ms']);
  await dispose(); assert.equal(disposed, true);
}
{
  const f = fixture(); const value = output(await f.exec({ command: 'getprop ro.build.version.release' }, f.context()));
  assert.equal(value.stdout, 'fixture Android output'); assert.equal(value.uid, 2000); assert.equal(value.elapsedMs, 11);
  const submitted = f.requests.find(r => r.method === 'submit');
  assert.equal(submitted.command, 'getprop ro.build.version.release');
  assert.deepEqual(submitted.scope, { runtimeId: descriptor.runtimeId, directory: '/project', sessionID: 'ses1', messageID: 'msg1', callID: 'call1', agentID: 'build' });
  assert.equal(f.permissions[0].action, 'shizuku'); assert.deepEqual(f.permissions[0].source, { type: 'tool', messageID: 'msg1', id: 'call1' });
  assert.equal(f.requests.filter(r => r.method === 'submit').length, 1);
  assert.equal(output(await f.exec({ command: 'getprop ro.build.version.release' }, f.context())).state, 'succeeded');
  assert.equal(f.requests.filter(r => r.method === 'submit').length, 1);
  assert.equal(output(await f.exec({ command: 'different command' }, f.context())).error, 'operation_conflict');
  assert.equal(f.requests.filter(r => r.method === 'submit').length, 1);
}
{
  const f = fixture({ ready: { error: 'feature_disabled', state: 'not_executed' } });
  assert.equal(output(await f.exec({ command: 'id' }, f.context())).error, 'feature_disabled');
  assert.ok(!f.requests.some(r => r.method === 'submit'));
  const bad = fixture({ ready: { executionReady: true, uid: 10001, serviceInstance: 's' } });
  assert.equal(output(await bad.exec({ command: 'id' }, bad.context())).reason, 'execution_handshake_required');
}
{
  const denied = Object.assign(new Error('Core denied action'), { code: 77 });
  const f = fixture({ permission: async () => { throw denied; } });
  await assert.rejects(() => f.exec({ command: 'id' }, f.context()), error => error === denied);
  assert.ok(!f.requests.some(r => r.method === 'submit'));
}
{
  const f = fixture({ lostReply: true });
  assert.equal(output(await f.exec({ command: 'id' }, f.context())).state, 'succeeded');
  assert.equal(f.requests.filter(r => r.method === 'submit').length, 1);
  assert.ok(f.requests.some(r => r.method === 'result'));
}
{
  const controller = new AbortController();
  const f = fixture({ permission: async () => { controller.abort(); } });
  await assert.rejects(() => f.exec({ command: 'id' }, f.context('late-call', controller)), { name: 'AbortError' });
  assert.ok(!f.requests.some(r => r.method === 'submit'));
  assert.ok(f.requests.some(r => r.method === 'cancel'));
  assert.equal(output(await f.exec({ command: 'id' }, f.context('late-call'))).state, 'cancelled');
  assert.ok(!f.requests.some(r => r.method === 'submit'));
}
{
  const controller = new AbortController();
  const f = fixture({ waiting: request => request.command === 'write fixture' });
  const read = f.exec({ command: 'id' }, f.context('read-call'));
  const write = f.exec({ command: 'write fixture' }, f.context('write-call', controller, data => {
    if (data.android?.state === 'waiting') controller.abort();
  }));
  const settled = await Promise.allSettled([read, write]);
  assert.equal(output(settled[0].value).state, 'succeeded');
  assert.equal(settled[1].reason.name, 'AbortError');
  assert.equal(f.requests.filter(r => r.method === 'cancel').length, 1);
  assert.equal(output(await f.exec({ command: 'id' }, f.context('next-call'))).state, 'succeeded');
}
{
  const f = fixture();
  assert.equal(output(await f.exec({ command: 'id\0hidden' }, f.context())).reason, 'invalid_command');
  assert.equal(output(await f.exec({ command: 'id', timeout_ms: 120001 }, f.context())).reason, 'invalid_command');
  assert.equal(f.requests.length, 0);
  const status = output(await f.tools[0].execute({}, f.context()));
  assert.equal(status.uid, null); assert.equal(status.executionReady, false); // Server UID does not pretend to be a handshake.
}

// Exercise real byte framing and descriptor checks, but not a simulated Android privilege claim.
const descriptionFile = path.join(directory, 'descriptor.json');
await fs.writeFile(descriptionFile, JSON.stringify(descriptor), { mode: 0o600 });
assert.equal((await describe(descriptionFile)).runtimeId, descriptor.runtimeId);
await fs.chmod(descriptionFile, 0o644);
await assert.rejects(() => describe(descriptionFile), { code: 'android_bridge_unavailable' });
await fs.chmod(descriptionFile, 0o600);
const symlink = path.join(directory, 'descriptor-link');
await fs.symlink(descriptionFile, symlink);
await assert.rejects(() => describe(symlink), { code: 'android_bridge_unavailable' });

async function withSocket(send, test) {
  const socket = path.join(directory, 'fixture.sock');
  const clients = new Set();
  const server = net.createServer({ allowHalfOpen: true }, client => {
    clients.add(client); client.once('close', () => clients.delete(client)); client.on('error', () => {});
    const input = [];
    client.on('data', data => input.push(data));
    client.once('end', () => send(client, Buffer.concat(input)));
  });
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(socket, resolve); });
  try { await test(options => net.createConnection({ ...options, path: socket })); }
  finally { for (const client of clients) client.destroy(); await new Promise(resolve => server.close(resolve)); }
}
await withSocket((client, input) => {
  assert.equal(input.readUInt32BE(0), input.length - 4);
  assert.equal(JSON.parse(input.subarray(4)).method, 'status');
  const bytes = Buffer.from(JSON.stringify(envelope({ state: 'fixture' })));
  const frame = Buffer.alloc(bytes.length + 4); frame.writeUInt32BE(bytes.length); bytes.copy(frame, 4);
  client.write(frame.subarray(0, 2)); client.write(frame.subarray(2, 7)); client.end(frame.subarray(7));
}, async connect => assert.equal((await exchange(descriptor, { method: 'status' }, { connect })).state, 'fixture'));
await withSocket(client => {
  const header = Buffer.alloc(4); header.writeUInt32BE(786433); client.end(header);
}, async connect => await assert.rejects(() => exchange(descriptor, { method: 'status' }, { connect }), { code: 'invalid_bridge_reply' }));
await withSocket(client => {
  const header = Buffer.alloc(4); header.writeUInt32BE(100); client.write(header); client.end('{}');
}, async connect => await assert.rejects(() => exchange(descriptor, { method: 'status' }, { connect }), { code: 'bridge_reply_lost' }));
await withSocket(() => {}, async connect => {
  const controller = new AbortController();
  const promise = exchange(descriptor, { method: 'status' }, { connect, signal: controller.signal });
  controller.abort();
  await assert.rejects(() => promise, { name: 'AbortError' });
});
console.log('Android plugin registration, scope, permission, cancellation, dedup replay and private framing: passed (fixtures only)');
