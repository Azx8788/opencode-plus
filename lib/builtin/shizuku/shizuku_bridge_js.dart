/// App-owned, byte-framed transport to the Android broker. No HTTP/ADB fallback.
const shizukuBridgeJs = r'''
import fs from 'node:fs/promises';
import { constants } from 'node:fs';
import net from 'node:net';

export const descriptorPath = '/root/.oc-builtin/shizuku-bridge.json';
const socketPath = '/tmp/.oc-shizuku/s';
const maxRequest = 131072, maxResponse = 786432;
const decoder = new TextDecoder('utf-8', { fatal: true });
export class BridgeError extends Error {
  constructor(code) { super(code); this.code = code; }
}
export const abortError = () => Object.assign(new Error('Android command cancelled'), { name: 'AbortError' });

export async function describe(path = descriptorPath) {
  let handle;
  try {
    handle = await fs.open(path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
    const stat = await handle.stat();
    if (!stat.isFile() || stat.nlink !== 1 || stat.size < 1 || stat.size > 1024 || (stat.mode & 0o077) !== 0) throw 0;
    const bytes = Buffer.alloc(1025);
    const { bytesRead } = await handle.read(bytes, 0, bytes.length, 0);
    if (bytesRead !== stat.size) throw 0;
    const value = JSON.parse(decoder.decode(bytes.subarray(0, bytesRead)));
    if (value.protocolVersion !== 1 || value.socketPath !== socketPath
        || !/^[a-f0-9-]{36}$/.test(value.runtimeId) || !/^[a-f0-9-]{36}$/.test(value.bridgeInstance)) throw 0;
    return value;
  } catch (_) { throw new BridgeError('android_bridge_unavailable'); }
  finally { if (handle) await handle.close(); }
}

export function exchange(descriptor, request, { signal, timeoutMs = 15000, connect = net.createConnection } = {}) {
  if (signal?.aborted) return Promise.reject(abortError());
  const body = Buffer.from(JSON.stringify({ ...request, protocolVersion: 1, bridgeInstance: descriptor.bridgeInstance }));
  if (body.length > maxRequest) return Promise.reject(new BridgeError('bridge_request_too_large'));
  const frame = Buffer.alloc(4 + body.length); frame.writeUInt32BE(body.length); body.copy(frame, 4);
  return new Promise((resolve, reject) => {
    let settled = false, size, received = 0, chunks = [];
    let socket;
    const finish = (error, value) => {
      if (settled) return;
      settled = true;
      signal?.removeEventListener('abort', cancelled);
      socket?.destroy();
      error ? reject(error) : resolve(value);
    };
    const cancelled = () => finish(abortError());
    try { socket = connect({ path: descriptor.socketPath }); }
    catch (_) { finish(new BridgeError('android_bridge_unavailable')); return; }
    signal?.addEventListener('abort', cancelled, { once: true });
    if (signal?.aborted) { cancelled(); return; }
    socket.setTimeout(timeoutMs, () => finish(new BridgeError('bridge_reply_timeout')));
    socket.once('connect', () => { if (!settled) socket.end(frame); });
    socket.on('data', chunk => {
      if (settled) return;
      received += chunk.length;
      if (received > maxResponse + 4) { finish(new BridgeError('invalid_bridge_reply')); return; }
      chunks.push(chunk);
      if (size === undefined && received >= 4) {
        size = Buffer.concat(chunks, received).readUInt32BE(0);
        if (size < 1 || size > maxResponse) { finish(new BridgeError('invalid_bridge_reply')); return; }
      }
      if (size !== undefined && received >= size + 4) {
        try {
          if (received !== size + 4) throw 0;
          const value = JSON.parse(decoder.decode(Buffer.concat(chunks, received).subarray(4)));
          if (value.protocolVersion !== 1 || value.bridgeInstance !== descriptor.bridgeInstance || value.runtimeId !== descriptor.runtimeId) throw 0;
          finish(null, value);
        } catch (_) { finish(new BridgeError('invalid_bridge_reply')); }
      }
    });
    socket.once('error', () => finish(new BridgeError('android_bridge_unavailable')));
    socket.once('end', () => { if (!settled) finish(new BridgeError('bridge_reply_lost')); });
    socket.once('close', () => { if (!settled) finish(new BridgeError('bridge_reply_lost')); });
  });
}

export const nativeTransport = { describe, exchange };
''';
