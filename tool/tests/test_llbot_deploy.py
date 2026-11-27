import hashlib
import io
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

from tool import llbot_deploy as deploy


class DeploymentTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.work = Path(temporary.name)
        self.root = self.work / 'managed'
        self.job = 'a' * 32
        data = io.BytesIO()
        with zipfile.ZipFile(data, 'w') as bundle:
            for name, content in {
                'node': b'not executed by fixture', 'llbot.js': b'fixture',
                'default_config.json': b'{}', 'package.json': b'{"type":"module"}',
                'webui/index.html': b'<html></html>', 'node_modules/example/LICENSE': b'license fixture',
            }.items():
                bundle.writestr(f'bin/llbot/{name}', content)
        self.archive = data.getvalue()
        for target, value in [('ARCHIVE_BYTES', len(self.archive)),
                              ('ARCHIVE_SHA256', hashlib.sha256(self.archive).hexdigest()),
                              ('MANAGED_BUNDLE_SHA256', hashlib.sha256(b'fixture').hexdigest())]:
            mock = patch.object(deploy, target, value)
            mock.start()
            self.addCleanup(mock.stop)
        # Tiny archive fixtures exercise transactions. The opt-in pinned
        # artifact tests below exercise the real, hash-checked source delta.
        patcher = patch.object(deploy, 'patch_bundle', side_effect=lambda original: original)
        patcher.start()
        self.addCleanup(patcher.stop)
        platform = patch.object(deploy, 'require_platform')
        platform.start()
        self.addCleanup(platform.stop)
        self.downloads = 0

    def download(self, path, _deadline):
        self.downloads += 1
        path.write_bytes(self.archive)

    def install(self):
        deploy.install(self.root, self.job, downloader=self.download)

    def test_success_is_verified_published_and_idempotent_preserving_login(self):
        stages = []
        write = deploy.write_record
        def record(path, value):
            if path.name == 'job.json':
                stages.append((value['stage'], value['phase']))
            return write(path, value)
        with patch.object(deploy, 'write_record', side_effect=record):
            self.install()
        self.assertEqual(stages, [('checking', 'installing'), ('download', 'installing'),
                                 ('verify', 'installing'), ('install', 'installing'),
                                 ('configure', 'installing'), ('configure', 'installed')])
        runtime = deploy.current(self.root, verify=True)
        self.assertEqual((runtime / 'node_modules/example/LICENSE').read_bytes(), b'license fixture')
        credentials = deploy.read_record(self.root / 'state/connection.json')
        password = deploy.read_bytes(self.root / 'state/data/webui_token.txt')
        self.assertRegex(credentials['accessToken'], r'^[a-f0-9]{64}$')
        self.assertNotEqual(password.strip().decode(), credentials['accessToken'])
        login = self.root / 'state/data/qq-session-fixture.json'
        login.write_bytes(b'untouched test fixture')
        self.install()
        self.assertEqual(self.downloads, 1)
        self.assertEqual(deploy.current(self.root), runtime)
        self.assertEqual(deploy.read_record(self.root / 'state/connection.json'), credentials)
        self.assertEqual(deploy.read_bytes(self.root / 'state/data/webui_token.txt'), password)
        self.assertEqual(login.read_bytes(), b'untouched test fixture')
        self.assertEqual(stat.S_IMODE((runtime / 'node').stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE((self.root / 'state/connection.json').stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE((self.root / 'state/data').stat().st_mode), 0o700)
        self.assertFalse(list((self.root / 'staging').iterdir()))

    def test_bad_digest_never_publishes_and_retry_recovers(self):
        def corrupt(path, _deadline):
            path.write_bytes(b'?' * len(self.archive))
        with self.assertRaisesRegex(deploy.DeploymentError, '^integrity$'):
            deploy.install(self.root, self.job, downloader=corrupt)
        self.assertFalse((self.root / 'current.json').exists())
        self.assertEqual(deploy.read_record(self.root / 'job.json')['phase'], 'failed')
        self.assertFalse(list((self.root / 'staging').iterdir()))
        self.install()
        self.assertEqual(deploy.read_record(self.root / 'job.json')['phase'], 'installed')

    def test_failed_repair_preserves_published_tree_and_credentials(self):
        self.install()
        old = (self.root / 'current.json').read_bytes()
        runtime = deploy.current(self.root)
        (runtime / 'llbot.js').write_bytes(b'corrupted fixture')
        password = (self.root / 'state/data/webui_token.txt').read_bytes()
        def fail(_path, _deadline):
            raise RuntimeError('fake secret should never be projected')
        with self.assertRaisesRegex(deploy.DeploymentError, '^install_failed$'):
            deploy.install(self.root, self.job, downloader=fail)
        self.assertEqual((self.root / 'current.json').read_bytes(), old)
        self.assertEqual((self.root / 'state/data/webui_token.txt').read_bytes(), password)
        self.assertNotIn('secret', (self.root / 'job.json').read_text())
        self.install()
        self.assertNotEqual(deploy.current(self.root), runtime)
        self.assertTrue(runtime.exists())
        deploy.current(self.root, verify=True)

    def test_atomic_publication_failure_keeps_old_pointer(self):
        self.install()
        old = (self.root / 'current.json').read_bytes()
        (deploy.current(self.root) / 'llbot.js').write_text('corrupt')
        replace = os.replace
        def refuse(source, target):
            if Path(target) == self.root / 'current.json':
                raise OSError('fixture')
            return replace(source, target)
        with patch.object(deploy.os, 'replace', side_effect=refuse):
            with self.assertRaisesRegex(deploy.DeploymentError, '^install_failed$'):
                self.install()
        self.assertEqual((self.root / 'current.json').read_bytes(), old)

    def test_malformed_receipt_is_integrity_and_repairs_without_changing_account_state(self):
        self.install()
        account = self.root / 'state/data/qq-session-fixture.json'
        account.write_bytes(b'untouched fixture, not a real session')
        account_bytes = account.read_bytes()
        credentials = (self.root / 'state/connection.json').read_bytes()
        password = (self.root / 'state/data/webui_token.txt').read_bytes()
        good = deploy.read_record(self.root / 'current.json')
        bad = [b'{', b'null', b'[]', b'1', b'"text"', b'\xff', b' ' * 8193]
        for key in ('directory', 'tree', 'version', 'archive', 'patch', 'bundle'):
            for value in (None, 123, [], {}):
                bad.append(json.dumps({**good, key: value}).encode())
        bad.append(json.dumps({key: value for key, value in good.items() if key != 'patch'}).encode())
        for damaged in bad:
            with self.subTest(receipt=damaged[:80]):
                deploy.atomic_bytes(self.root / 'current.json', damaged)
                with self.assertRaisesRegex(deploy.DeploymentError, '^integrity$'):
                    deploy.current(self.root, verify=True)
                self.install()
                deploy.current(self.root, verify=True)
                self.assertEqual(account.read_bytes(), account_bytes)
                self.assertEqual((self.root / 'state/connection.json').read_bytes(), credentials)
                self.assertEqual((self.root / 'state/data/webui_token.txt').read_bytes(), password)

    def test_running_lock_blocks_repair_but_not_valid_idempotence(self):
        self.install()
        with deploy.lock(self.root / 'run.lock'):
            self.install()
            (deploy.current(self.root) / 'llbot.js').write_text('corrupt')
            with self.assertRaisesRegex(deploy.DeploymentError, '^busy$'):
                self.install()
        self.assertEqual(self.downloads, 1)

    def test_credentials_fail_closed_and_never_enter_argv_or_environment(self):
        self.install()
        record = deploy.read_record(self.root / 'state/connection.json')
        args, env = deploy.launch_spec(deploy.current(self.root), self.root / 'state')
        self.assertNotIn(record['accessToken'], repr((args, env)))
        with patch.dict(os.environ, {'AUTH_TOKEN': 'private', 'NODE_OPTIONS': 'private'}):
            _, clean = deploy.launch_spec(deploy.current(self.root), self.root / 'state')
        self.assertNotIn('AUTH_TOKEN', clean)
        self.assertNotIn('NODE_OPTIONS', clean)
        credentials = self.root / 'state/connection.json'
        credentials.chmod(0o644)
        with self.assertRaisesRegex(deploy.DeploymentError, '^storage$'):
            deploy.configure(self.root)
        self.assertEqual(stat.S_IMODE(credentials.stat().st_mode), 0o644)

    def test_symlink_tree_or_private_directory_rejected(self):
        self.install()
        runtime = deploy.current(self.root)
        (runtime / 'alias').symlink_to(runtime / 'llbot.js')
        with self.assertRaises((deploy.DeploymentError, OSError)):
            deploy.current(self.root, verify=True)
        link = self.work / 'link'
        link.symlink_to(self.root)
        with self.assertRaisesRegex(deploy.DeploymentError, '^storage$'):
            deploy.private_dir(link)

    def test_archive_rejects_traversal_links_devices_duplicates_and_bombs(self):
        for name, mode in [('../escape', 0), ('bin/llbot/../../escape', 0),
                           ('bin/llbot/a\\b', 0), ('bin/llbot/a//b', 0),
                           ('bin/llbot/link', stat.S_IFLNK | 0o777),
                           ('bin/llbot/device', stat.S_IFCHR | 0o600)]:
            with self.subTest(name=name):
                archive = self.work / 'unsafe.zip'
                with zipfile.ZipFile(archive, 'w') as z:
                    item = zipfile.ZipInfo(name)
                    item.external_attr = mode << 16
                    z.writestr(item, b'data')
                with self.assertRaisesRegex(deploy.DeploymentError, '^archive_invalid$'):
                    deploy.unpack(archive, self.work / 'unpacked', time.monotonic() + 10)
        self.assertFalse((self.work / 'escape').exists())
        archive.write_bytes(self.archive)
        with patch.object(deploy, 'MAX_UNPACKED', 1):
            with self.assertRaisesRegex(deploy.DeploymentError, '^archive_invalid$'):
                deploy.unpack(archive, self.work / 'unpacked', time.monotonic() + 10)

    def test_download_deadline_and_https_redirect_are_enforced(self):
        with self.assertRaisesRegex(deploy.DeploymentError, '^download_timeout$'):
            deploy.deadline_check(time.monotonic() - 1)
        with self.assertRaisesRegex(deploy.DeploymentError, '^download_failed$'):
            deploy.HttpsRedirect().redirect_request(None, None, 302, '', {}, 'http://example.test/file')

    @unittest.skipUnless(shutil.which('node'), 'Node is needed only for the preload contract fixture')
    def test_preload_forces_loopback_and_private_config_without_listening(self):
        self.install()
        runtime = deploy.current(self.root)
        fixture = runtime / 'fixture.mjs'
        fixture.write_text(r'''
import assert from 'node:assert/strict';
import fs from 'node:fs';
import net from 'node:net';
import dgram from 'node:dgram';
import path from 'node:path';
const observed = [];
net.Server.prototype.listen = function (options) { observed.push(options); return this; };
await import(process.env.GUARD);
const cfg = JSON.parse(fs.readFileSync(path.join(import.meta.dirname, 'default_config.json'), 'utf8'));
assert.deepEqual(cfg, {}); // The preload no longer replaces Node's file reader.
const policy = globalThis[Symbol.for('oc.llbot.managedConfig.v2')];
assert.equal(policy(cfg), cfg);
assert.equal(cfg.webui.host, '127.0.0.1');
assert.equal(cfg.webui.port, 3080);
assert.equal(cfg.ob11.connect.length, 1);
assert.equal(cfg.ob11.connect[0].port, 3001);
assert.equal(cfg.ob11.connect[0].token, JSON.parse(fs.readFileSync('connection.json', 'utf8')).accessToken);
assert.equal(cfg.log, false);
net.createServer().listen(3080, '0.0.0.0');
net.createServer().listen({port: 3001, host: '::'});
assert.deepEqual(observed.map(x => x.host), ['127.0.0.1', '127.0.0.1']);
assert.throws(() => net.createServer().listen(4000, '127.0.0.1'));
assert.throws(() => net.createServer().listen('/tmp/not-allowed'));
assert.throws(() => dgram.createSocket('udp4').bind(3001));
const log = path.resolve('data/logs/test.log');
fs.appendFileSync(log, 'test-only-sensitive');
await new Promise((resolve, reject) => fs.appendFile(log, 'test-only-sensitive', e => e ? reject(e) : resolve()));
await fs.promises.appendFile(log, 'test-only-sensitive');
assert.equal(fs.existsSync(log), false);
console.log('guard_ok');
''')
        result = subprocess.run(['node', str(fixture)], cwd=self.root / 'state',
                                env={'PATH': os.environ['PATH'], 'GUARD': str(deploy.GUARD),
                                     'OC_LLBOT_SUPERVISOR_PID': str(os.getpid())},
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10)
        self.assertEqual(result.returncode, 0, 'preload fixture failed (raw output withheld)')
        self.assertEqual(result.stdout, b'guard_ok\n')


@unittest.skipUnless(os.environ.get('LLBOT_TEST_ARCHIVE'), 'Set LLBOT_TEST_ARCHIVE for pinned offline artifact tests')
class PinnedRuntimeTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix='llbot-pinned-test-',
                                                   dir='/tmp/opencode' if Path('/tmp/opencode').is_dir() else None)
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.root = Path(cls.temporary.name) / 'managed'
        archive = Path(os.environ['LLBOT_TEST_ARCHIVE'])
        deploy.install(cls.root, 'a' * 32,
                       downloader=lambda target, _deadline: shutil.copyfile(archive, target))
        cls.runtime = deploy.current(cls.root, verify=True)
        with zipfile.ZipFile(archive) as bundle:
            cls.original = bundle.read('bin/llbot/llbot.js')

    def test_exact_source_patch_rejects_modified_input_and_repatch(self):
        derived = deploy.patch_bundle(self.original)
        self.assertEqual(hashlib.sha256(derived).hexdigest(), deploy.MANAGED_BUNDLE_SHA256)
        self.assertEqual((self.runtime / 'llbot.js').read_bytes(), derived)
        self.assertIn(b'Modified by OpenCode Plus on 2026-11-27', derived[:1024])
        self.assertIn(b'GPL-2.0', derived[:1024])
        for untrusted in (self.original + b' ', self.original[:-1], derived):
            with self.assertRaisesRegex(deploy.DeploymentError, '^integrity$'):
                deploy.patch_bundle(untrusted)
        # A wrong patch anchor also fails closed, even behind the input digest.
        with patch.object(deploy, 'BUNDLE_SHA256', hashlib.sha256(b'fixture').hexdigest()):
            with self.assertRaisesRegex(deploy.DeploymentError, '^integrity$'):
                deploy.patch_bundle(b'fixture')

    def test_actual_config_save_reload_and_log_paths_offline(self):
        root = self.root / 'fixture-root'
        deploy.private_dir(root)
        deploy.configure(root)
        source = (self.runtime / 'llbot.js').read_text()
        bootstrap = 'onLoad().catch((e) => getLogger("main").error(e));'
        self.assertEqual(source.count(bootstrap), 1)
        exposed = ('export { Config, Log, Hono, selfInfo, getLogCache, createConfigRoutes, '
                   'createLogsRoutes, authMiddleware, OB11WebSocket, OB11Http, SetConfigAction, '
                   'Context$1 as TestContext, browser_default as LoggerPlugin };')
        instrumented = self.runtime / 'policy-test-bundle.mjs'
        instrumented.write_text(source.replace(bootstrap, exposed, 1))
        self.addCleanup(instrumented.unlink, missing_ok=True)
        fixture = Path(__file__).with_name('llbot_deploy_policy.mjs').resolve()
        _, environment = deploy.launch_spec(self.runtime, root / 'state')
        environment.update({'OC_LLBOT_OFFLINE_TEST': '1', 'TEST_MODULE': str(instrumented)})
        result = subprocess.run([str(self.runtime / 'node'), '--permission',
                                 f'--allow-fs-read={self.root}', f'--allow-fs-read={deploy.GUARD}',
                                 f'--allow-fs-read={fixture}', f'--allow-fs-write={root / "state"}',
                                 '--import', str(deploy.GUARD), str(fixture)],
                                cwd=root / 'state', env=environment,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=15)
        # Only a fixed test stage is allowed into a failure report, never raw output.
        import re
        stages = re.findall(rb'pinned_policy_failed:[a-z-]+', result.stderr)
        self.assertEqual(result.returncode, 0, stages[-1].decode() if stages else 'offline fixture failed')
        self.assertIn(b'pinned_policy_ok\n', result.stdout)

    def test_managed_runtime_starts_no_login_offline_and_stops(self):
        try:
            deploy.ports_free()
        except deploy.DeploymentError:
            self.skipTest('Loopback test ports are in use')
        script = '''from tool import llbot_deploy as d
from pathlib import Path
import os, sys
os.umask(0o077)
original = d.launch_spec
def offline(runtime, state):
    args, env = original(runtime, state)
    args.remove('--allow-addons')
    env['OC_LLBOT_OFFLINE_TEST'] = '1'
    return args, env
d.launch_spec = offline
d.run(Path(sys.argv[1]), 'c' * 32)
'''
        child = subprocess.Popen([sys.executable, '-c', script, str(self.root)],
                                 env={'PATH': os.environ['PATH'],
                                      'PYTHONPATH': str(Path(__file__).resolve().parents[2])},
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        ready = False
        code = 'test_deadline'
        try:
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline:
                try:
                    record = deploy.read_record(self.root / 'run.json')
                except FileNotFoundError:
                    record = {}
                if record.get('phase') == 'running':
                    ready = deploy.console_ready()
                    break
                if record.get('phase') == 'failed' or child.poll() is not None:
                    code = record.get('failure', 'test_process_exited')
                    break
                time.sleep(0.1)
        finally:
            child.terminate()
            try:
                child.communicate(timeout=10)
            except subprocess.TimeoutExpired:
                child.kill()
                child.communicate(timeout=5)
        self.assertTrue(ready, code if code in deploy.FAILURES else 'offline start failed')
        self.assertIsNotNone(child.poll())
        deploy.ports_free()
        self.assertFalse((self.root / 'state/data/auth_token.txt').exists())
        self.assertFalse(list((self.root / 'state/data').glob('qq-session-*')))
        self.assertFalse(any(p.is_file() and p.stat().st_size
                             for p in (self.root / 'state/data/logs').rglob('*')))


if __name__ == '__main__':
    unittest.main()
