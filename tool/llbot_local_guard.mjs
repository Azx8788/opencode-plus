// The enrollment launcher exposes only the WebUI on the phone's loopback.
import { Server as HttpServer } from 'node:http';
import net from 'node:net';
import dns from 'node:dns';
import dgram from 'node:dgram';
import { syncBuiltinESMExports } from 'node:module';

const mode = process.env.OC_LLBOT_MODE;
if (mode !== 'smoke' && mode !== 'enroll') throw Error('LLBot launcher mode required');
const supervisor = Number(process.env.OC_LLBOT_SUPERVISOR_PID);
if (!Number.isSafeInteger(supervisor) || supervisor < 2 || process.ppid !== supervisor) {
  throw Error('LLBot supervisor is missing');
}
// The child retains the run lock and exits if its foreground owner disappears.
setInterval(() => { if (process.ppid !== supervisor) process.exit(1); }, 1000).unref();
const host = '127.0.0.1';
const port = 3080;

function deny(kind) {
  process.stderr.write(`OC_LLBOT_REFUSED ${kind}\n`);
  throw Error(`LLBot launcher policy: ${kind}`);
}

const listen = net.Server.prototype.listen;
net.Server.prototype.listen = function (...args) {
  const [options] = net._normalizeArgs(args);
  // This also covers get-port's temporary probes. No different port, wildcard,
  // or additional service is allowed in this enrollment stage.
  if (options.host !== host || Number(options.port) !== port
      || options.path != null || options.fd != null || options.handle != null) deny('listener');
  this.once('listening', () => {
    const address = this.address();
    if (address?.address !== host || address.port !== port) deny('address');
    if (this instanceof HttpServer) process.stderr.write('OC_LLBOT_HTTP_READY\n');
  });
  return Reflect.apply(listen, this, args);
};

if (mode === 'smoke') {
  net.Socket.prototype.connect = () => deny('outbound');
  dgram.createSocket = () => deny('outbound');
  for (const target of [dns, dns.promises, dns.Resolver.prototype, dns.promises.Resolver.prototype]) {
    for (const key of Object.getOwnPropertyNames(target)) {
      if ((key.startsWith('resolve') || key === 'reverse' || key === 'lookupService') && typeof target[key] === 'function') {
        target[key] = () => deny('outbound');
      }
    }
    if (typeof target.lookup === 'function') {
      const lookup = target.lookup;
      target.lookup = function (name, ...args) {
        if (name !== host) deny('outbound');
        return Reflect.apply(lookup, this, [name, ...args]);
      };
    }
  }
}
syncBuiltinESMExports();
