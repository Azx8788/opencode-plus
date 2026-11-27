// OpenCode Plus's independently authored preload for the pinned LLBot runtime.
// Enforces managed config and loopback TCP listeners, including get-port probes.
// This is a compatibility/policy guard, not an OS sandbox for native addons.
import fs from 'node:fs';
import path from 'node:path';
import net from 'node:net';
import dgram from 'node:dgram';
import dns from 'node:dns';
import { Server as HttpServer } from 'node:http';
import { syncBuiltinESMExports } from 'node:module';

const supervisor = Number(process.env.OC_LLBOT_SUPERVISOR_PID);
if (!Number.isSafeInteger(supervisor) || supervisor < 2 || process.ppid !== supervisor) {
  throw Error('managed_supervisor_required');
}
setInterval(() => { if (process.ppid !== supervisor) process.exit(1); }, 1000).unref();
const state = process.cwd();
const read = fs.readFileSync;
const credentials = JSON.parse(read(path.join(state, 'connection.json'), 'utf8'));
if (!/^[a-f0-9]{64}$/.test(credentials.accessToken)) throw Error('credentials');

function managedConfig(original) {
  if (!original || typeof original !== 'object' || Array.isArray(original)) throw Error('managed_config');
  // Mutate the same object Config.set's caller publishes in config-updated.
  // Returning a replacement alone would leave the event payload unprotected.
  return Object.assign(original, {
    webui: { enable: true, host: '127.0.0.1', port: 3080 },
    ob11: { enable: true, connect: [{
      type: 'ws', enable: true, host: '127.0.0.1', port: 3001,
      token: credentials.accessToken, heartInterval: 60000,
      reportSelfMessage: false, reportOfflineMessage: false,
      messageFormat: 'array', debug: false,
    }] },
    milky: { ...original.milky, enable: false },
    satori: { ...original.satori, enable: false },
    enableLocalFile2Url: false, log: false, logLevel: 'info',
  });
}

// Only the exact hash-pinned Config implementation calls this hook, at its
// defaults/reload/set boundaries. Leave Node's file reader and JSON5 intact.
Object.defineProperty(globalThis, Symbol.for('oc.llbot.managedConfig.v2'), {
  value: managedConfig, writable: false, configurable: false,
});

// The pinned upstream logger writes before it loads config.log. Discard its
// file appends as well as the console output the Python supervisor consumes.
// This also suppresses webui_access.log, which can contain request URLs.
const logRoot = path.join(state, 'data', 'logs') + path.sep;
const isLog = (file) => typeof file === 'string' && path.resolve(file).startsWith(logRoot);
const append = fs.appendFile;
fs.appendFile = function (file, ...args) {
  if (!isLog(file)) return Reflect.apply(append, this, [file, ...args]);
  const callback = args.at(-1);
  if (typeof callback === 'function') queueMicrotask(() => callback(null));
};
const appendSync = fs.appendFileSync;
fs.appendFileSync = function (file, ...args) {
  if (!isLog(file)) return Reflect.apply(appendSync, this, [file, ...args]);
};
const appendAsync = fs.promises.appendFile;
fs.promises.appendFile = async function (file, ...args) {
  if (!isLog(file)) return Reflect.apply(appendAsync, this, [file, ...args]);
};

function deny() {
  process.stderr.write('OC_LLBOT_LISTENER_REFUSED\n');
  throw Error('listener_refused');
}
const listen = net.Server.prototype.listen;
net.Server.prototype.listen = function (...args) {
  const [options, callback] = net._normalizeArgs(args);
  const port = Number(options.port);
  if (![3080, 3001].includes(port) || options.path != null || options.fd != null || options.handle != null) deny();
  this.once('listening', () => {
    const address = this.address();
    if (address?.address !== '127.0.0.1' || address.port !== port) deny();
    if (this instanceof HttpServer && port === 3080) {
      process.stderr.write('OC_LLBOT_CONSOLE_BOUND\n');
      this.once('close', () => process.stderr.write('OC_LLBOT_CONSOLE_CLOSED\n'));
    }
  });
  return Reflect.apply(listen, this, [{ ...options, host: '127.0.0.1', port }, callback]);
};
dgram.Socket.prototype.bind = deny;

// Offline validation uses only fresh temporary state. The production launcher
// never sets this variable. Enabling it can only remove network access.
if (process.env.OC_LLBOT_OFFLINE_TEST === '1') {
  net.Socket.prototype.connect = () => { throw Error('offline_test'); };
  dgram.createSocket = () => { throw Error('offline_test'); };
  for (const target of [dns, dns.promises, dns.Resolver.prototype, dns.promises.Resolver.prototype]) {
    for (const key of Object.getOwnPropertyNames(target)) {
      if ((key.startsWith('resolve') || key === 'reverse' || key === 'lookupService') && typeof target[key] === 'function') {
        target[key] = () => { throw Error('offline_test'); };
      }
    }
    if (typeof target.lookup === 'function') {
      const lookup = target.lookup;
      target.lookup = function (name, ...args) {
        if (name !== '127.0.0.1') throw Error('offline_test');
        return Reflect.apply(lookup, this, [name, ...args]);
      };
    }
  }
}
syncBuiltinESMExports();
