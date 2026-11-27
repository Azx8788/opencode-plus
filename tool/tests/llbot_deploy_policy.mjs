// Exercises exported test-only views of the actual pinned/patched bundle.
// Its main bootstrap is removed only in the temporary test copy. No QQ plugin,
// native addon, network connection or real account state is used here.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';

let stage = 'load';
try {
  const {
    TestContext, LoggerPlugin, Config, Log, Hono, selfInfo, getLogCache,
    createConfigRoutes, createLogsRoutes, authMiddleware,
    OB11WebSocket, OB11Http, SetConfigAction,
  } = await import(process.env.TEST_MODULE);
  stage = 'context';
  fs.mkdirSync('data/logs', { recursive: true });
  const ctx = new TestContext();
  ctx.plugin(LoggerPlugin);
  const logger = new Log(ctx);
  const raw = [];
  const live = [];
  ctx.logger.exporter({ export: (message) => raw.push(message) });
  ctx.on('llob/log', (message) => live.push(message));
  ctx.plugin(Config);
  await new Promise((resolve) => setTimeout(resolve, 20));
  assert.ok(ctx.config);
  const token = JSON.parse(fs.readFileSync('connection.json', 'utf8')).accessToken;
  const password = fs.readFileSync('data/webui_token.txt', 'utf8').trim();
  const authFixture = 'fixture-auth-token-not-for-login';
  const qqFixture = 'fixture-qq-info-not-a-session';
  fs.writeFileSync('data/auth_token.txt', authFixture);
  fs.writeFileSync('data/qq-session-fixture.json', qqFixture);
  const rawRead = (file) => JSON.parse(fs.readFileSync(file, 'utf8'));
  function managed(value) {
    assert.deepEqual(value.webui, { enable: true, host: '127.0.0.1', port: 3080 });
    assert.equal(value.ob11.enable, true);
    assert.equal(value.ob11.connect.length, 1);
    assert.equal(value.ob11.connect[0].type, 'ws');
    assert.equal(value.ob11.connect[0].enable, true);
    assert.equal(value.ob11.connect[0].host, '127.0.0.1');
    assert.equal(value.ob11.connect[0].port, 3001);
    assert.equal(value.ob11.connect[0].token, token);
    assert.equal(value.ob11.connect[0].debug, false);
    assert.equal(value.milky.enable, false);
    assert.equal(value.satori.enable, false);
    assert.equal(value.log, false);
    assert.equal(value.logLevel, 'info');
  }
  stage = 'defaults';
  // Default file location is the actual Config implementation's import.meta,
  // not the executable's argv or a readFileSync filename heuristic.
  selfInfo.uin = '';
  managed(ctx.config.get(false));
  assert.equal(rawRead(ctx.config.defaultConfigPath).ob11.connect[0].enable, false);
  selfInfo.uin = '10001';
  managed(ctx.config.get(false));
  const accountConfig = path.resolve('data/config_10001.json');
  assert.equal(ctx.config.configPath, accountConfig);
  managed(rawRead(accountConfig));
  let updated;
  const ws = new OB11WebSocket(ctx, { ...ctx.config.get().ob11.connect[0] });
  ctx.on('llob/config-updated', (value) => {
    updated = structuredClone(value);
    ws.updateConfig(value.ob11.connect[0]);
  });
  const app = new Hono();
  app.use('/api/*', authMiddleware);
  app.route('/api', createConfigRoutes(ctx));
  app.route('/api', createLogsRoutes(ctx));
  const auth = createHash('sha256').update(password).digest('hex');
  const env = { incoming: { socket: { remoteAddress: '127.0.0.1' } } };
  const request = (name, init = {}) => app.fetch(new Request(`http://127.0.0.1:3080/api/${name}`, {
    ...init, headers: { 'X-Webui-Token': auth, 'Content-Type': 'application/json' },
  }), env);
  const wanted = (value) => ({
    ...ctx.config.get(),
    webui: { enable: true, host: '127.0.0.1', port: 3081 },
    ob11: { enable: true, connect: [
      { type: 'ws', enable: true, host: '127.0.0.1', port: 3001, token: value, debug: true },
      { type: 'ws-reverse', enable: true, url: 'https://invalid.test', token: value },
    ] },
    satori: { enable: true, host: '127.0.0.1' },
    milky: { enable: true, http: { host: '127.0.0.1' } },
    log: true, logLevel: 'debug', autoDeleteFileSecond: 123,
  });
  stage = 'save-event';
  const replacement = 'fixture-attempted-token-replacement';
  for (const value of ['', replacement]) {
    const response = await request('config', { method: 'POST', body: JSON.stringify({ config: wanted(value) }) });
    assert.equal(response.status, 200);
    assert.equal((await response.json()).success, true);
    managed(ctx.config.get());
    managed(updated);
    managed(rawRead(accountConfig));
    assert.equal(ctx.config.get().autoDeleteFileSecond, 123);
    assert.equal(ctx.config.skipNextWatch, true);
    assert.equal(ws.authorize(null, { headers: {}, url: '/' }), false);
    assert.equal(ws.authorize(null, { headers: { authorization: `Bearer ${replacement}` }, url: '/' }), false);
    assert.equal(ws.authorize(null, { headers: { authorization: `Bearer ${token}` }, url: '/' }), true);
    const readback = await (await request('config')).json();
    managed(readback.data.config);
  }
  stage = 'reload';
  // A real external JSON5 edit goes through upstream parsing and the actual
  // reload callback. No test or production readFileSync interception is used.
  ctx.config.listenChange((value) => ctx.parallel('llob/config-updated', value));
  ctx.config.watching = true;
  ctx.config.watchFileListener(); // consumes the real save's skipNextWatch
  assert.equal(ctx.config.skipNextWatch, false);
  fs.writeFileSync(accountConfig, '// fixture JSON5 edit\n' + JSON.stringify(wanted('')));
  ctx.config.watchFileListener();
  managed(ctx.config.get());
  managed(updated);
  managed(rawRead(accountConfig));
  fs.unwatchFile(accountConfig, ctx.config.watchFileListener);

  stage = 'onebot-save';
  const action = new SetConfigAction({ ctx });
  ws.config.actionMap = new Map([[action.actionName, action]]);
  const replies = [];
  const socket = { readyState: 1, send: (text) => replies.push(JSON.parse(text)) };
  await ws.handleAction(socket, Buffer.from(JSON.stringify({
    action: action.actionName, params: wanted(replacement), echo: 'fixture',
  })));
  assert.equal(replies[0].status, 'ok');
  managed(ctx.config.get());
  managed(updated);
  managed(rawRead(accountConfig));

  stage = 'credential-logging';
  const invalid = 'fixture-invalid-client-token';
  for (const value of [token, invalid]) {
    const accepted = value === token;
    assert.equal(ws.authorize(null, { headers: { authorization: `Bearer ${value}` }, url: '/' }), accepted);
    assert.equal(ws.authorize(null, { headers: {}, url: `/?access_token=${value}` }), accepted);
    const http = new OB11Http(ctx, { token });
    for (const header of [true, false]) {
      let next = false;
      await http.authorize({
        req: { header: () => header ? `Bearer ${value}` : undefined, query: () => header ? undefined : value },
        json: (value, code) => ({ value, code }),
      }, () => { next = true; });
      assert.equal(next, accepted);
    }
  }
  for (const secret of [token, password, replacement, invalid, authFixture]) {
    assert.equal(JSON.stringify(raw).includes(secret), false, 'secret reached a logger exporter');
  }

  stage = 'cache-and-stream';
  assert.equal(logger.exportFile, false);
  assert.deepEqual(getLogCache(), []);
  assert.deepEqual(live, []);
  const abort = new AbortController();
  const response = await request('logs/stream', { signal: abort.signal });
  const reader = response.body.getReader();
  const first = await reader.read();
  assert.match(new TextDecoder().decode(first.value), /event: connected/);
  ctx.logger.info('fixture log containing secret that must not be cached', invalid);
  assert.deepEqual(getLogCache(), []);
  assert.deepEqual(live, []);
  // Cancel the actual route after observing its connected event; a regression
  // that broadcasts a credential would also be present in live/getLogCache.
  await reader.cancel();
  abort.abort();
  assert.equal(fs.readFileSync('data/auth_token.txt', 'utf8'), authFixture);
  assert.equal(fs.readFileSync('data/qq-session-fixture.json', 'utf8'), qqFixture);
  const logs = fs.readdirSync('data/logs').map((name) => fs.readFileSync(path.join('data/logs', name)));
  assert.ok(logs.every((bytes) => bytes.length === 0));
  process.stdout.write('pinned_policy_ok\n');
  process.exit(0);
} catch (error) {
  // Never print assertion values: some deliberately contain credential fixtures.
  const kind = error?.code === 'ERR_ACCESS_DENIED' ? '-permission' : error instanceof SyntaxError ? '-syntax' : '';
  process.stderr.write(`pinned_policy_failed:${stage}${kind}\n`);
  process.exit(1);
}
