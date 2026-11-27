"""App-owned LLBot deployment; stdlib only, fixed-code output, no shell installer.

Downloads the hash-pinned LuckyLilliaBot v8.3.2 Linux ARM64 release from
https://github.com/LuckyLilliaDev/LuckyLilliaBot/releases/tag/v8.3.2 .
Pinned source commit: dc2b2b90092ef0f571b5546878288b83fff1e436.
The archive digest/size are from that release's GitHub asset metadata. Upstream
and dependency notices remain in the extracted archive. The exact-match source
excerpts in patch_bundle derive from LuckyLilliaBot contributors' GPL-2.0 code
at the pinned revision (see tool/llbot_deploy_NOTICES.txt and LICENSES/GPL-2.0.txt).
They retain GPL-2.0; the independently written deployment orchestration and
preload are separate. Before publication, patch_bundle applies the managed
delta to the exact pinned llbot.js; every anchor and the derived hash are checked.
The managed Node preload is independently authored in this repo.

The manual qq-onebot-poc runtime is deliberately outside this helper's root.
Only the app starts/stops the foreground `run` command, via BuiltinLinux services.
"""

import argparse
import fcntl
import hashlib
import http.client
import json
import os
import platform
import re
import secrets
import selectors
import shutil
import signal
import socket
import stat
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from contextlib import contextmanager
from pathlib import Path, PurePosixPath


VERSION = '8.3.2'
SOURCE_COMMIT = 'dc2b2b90092ef0f571b5546878288b83fff1e436'
URL = ('https://github.com/LuckyLilliaDev/LuckyLilliaBot/releases/download/'
       'v8.3.2/LuckyLillia-CLI-linux-arm64.zip')
ARCHIVE_SHA256 = 'dd7e6bb405ed44a7120e767ac3b3ab169fe343386008c5017729804baa4a4c0f'
ARCHIVE_BYTES = 88741224
BUNDLE_SHA256 = '83707ca9764d5fba040db52cdfaf5ec91735e40bbb0857c41dd44dcb5c73e81c'
PATCH_ID = 'oc-managed-v2'
# Filled from the deterministic delta below; independent of runtime secrets.
MANAGED_BUNDLE_SHA256 = 'a578d1d333795de38d14336a21dd47539d3aeff91e90ba9648fe4941ecfce122'
MAX_UNPACKED = 240 * 1024 * 1024
ROOT = Path('/root/.oc-builtin/llbot')
GUARD = Path(__file__).resolve().with_name('llbot_deploy_guard.mjs')
HOST = '127.0.0.1'
CONSOLE_PORT = 3080
ONEBOT_PORT = 3001
SAFE_OPEN = os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK
ID = re.compile(r'[a-f0-9]{32}\Z')
HASH = re.compile(r'[a-f0-9]{64}\Z')
STAGES = {'checking', 'download', 'verify', 'install', 'configure', 'start'}
FAILURES = {'unsupported', 'storage', 'busy', 'download_failed', 'download_timeout',
            'integrity', 'archive_invalid', 'credentials', 'not_installed',
            'port_busy', 'start_failed', 'start_timeout', 'listener_refused',
            'runtime_exited', 'install_failed'}


class DeploymentError(Exception):
    def __init__(self, code):
        self.code = code if code in FAILURES else 'install_failed'
        super().__init__(self.code)


def private_dir(path):
    path.mkdir(mode=0o700, exist_ok=True)
    info = path.lstat()
    if (not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid()
            or info.st_mode & 0o077):
        raise DeploymentError('storage')


def private_file(fd):
    info = os.fstat(fd)
    if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
            or info.st_mode & 0o077):
        raise DeploymentError('storage')
    return info


def read_bytes(path, limit=8192):
    with os.fdopen(os.open(path, os.O_RDONLY | SAFE_OPEN), 'rb') as source:
        if private_file(source.fileno()).st_size > limit:
            raise DeploymentError('storage')
        return source.read(limit + 1)


def read_record(path):
    value = json.loads(read_bytes(path))
    if not isinstance(value, dict):
        raise DeploymentError('storage')
    return value


def atomic_bytes(path, content):
    fd, name = tempfile.mkstemp(prefix='.write-', dir=path.parent)
    temp = Path(name)
    try:
        with os.fdopen(fd, 'wb') as dest:
            dest.write(content)
            dest.flush()
            os.fsync(dest.fileno())
        os.replace(temp, path)
        directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        temp.unlink(missing_ok=True)


def write_record(path, value):
    atomic_bytes(path, json.dumps(value, separators=(',', ':')).encode('utf-8'))


@contextmanager
def lock(path):
    fd = os.open(path, os.O_RDWR | os.O_CREAT | SAFE_OPEN, 0o600)
    try:
        private_file(fd)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise DeploymentError('busy') from error
        yield fd
    finally:
        os.close(fd)


def require_platform():
    if platform.system() != 'Linux' or platform.machine() not in ('arm64', 'aarch64'):
        raise DeploymentError('unsupported')


def deadline_check(deadline):
    if time.monotonic() >= deadline:
        raise DeploymentError('download_timeout')


class HttpsRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, msg, headers, newurl):
        parsed = urllib.parse.urlparse(newurl)
        if parsed.scheme != 'https' or parsed.username or parsed.password:
            raise DeploymentError('download_failed')
        return super().redirect_request(request, fp, code, msg, headers, newurl)


def download(destination, deadline):
    """One bounded attempt. A retry starts fresh and never trusts a partial zip."""
    opener = urllib.request.build_opener(HttpsRedirect())
    request = urllib.request.Request(URL, headers={'User-Agent': 'OpenCode-Plus-LLBot/1'})
    try:
        deadline_check(deadline)
        with opener.open(request, timeout=25) as response, destination.open('xb') as out:
            if response.status != 200:
                raise DeploymentError('download_failed')
            total = 0
            while True:
                deadline_check(deadline)
                chunk = response.read(256 * 1024)
                if not chunk:
                    break
                total += len(chunk)
                if total > ARCHIVE_BYTES:
                    raise DeploymentError('integrity')
                out.write(chunk)
            out.flush()
            os.fsync(out.fileno())
        if total != ARCHIVE_BYTES:
            raise DeploymentError('integrity')
    except (urllib.error.URLError, TimeoutError, http.client.HTTPException) as error:
        raise DeploymentError('download_failed') from error


def digest_file(path):
    digest = hashlib.sha256()
    with os.fdopen(os.open(path, os.O_RDONLY | SAFE_OPEN), 'rb') as source:
        if not stat.S_ISREG(os.fstat(source.fileno()).st_mode):
            raise DeploymentError('integrity')
        for chunk in iter(lambda: source.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def tree_digest(root):
    if not stat.S_ISDIR(root.lstat().st_mode):
        raise DeploymentError('integrity')
    files = []
    def failed(error):
        raise error
    for directory, dirs, names in os.walk(root, followlinks=False, onerror=failed):
        parent = Path(directory)
        for name in dirs:
            if not stat.S_ISDIR((parent / name).lstat().st_mode):
                raise DeploymentError('integrity')
        files.extend(parent / name for name in names)
    digest = hashlib.sha256()
    for path in sorted(files, key=lambda p: p.relative_to(root).as_posix()):
        digest.update(path.relative_to(root).as_posix().encode('utf-8') + b'\0')
        digest.update(bytes.fromhex(digest_file(path)))
    return digest.hexdigest()


def patch_bundle(original):
    """Managed delta to one exact upstream file; never a best-effort rewrite.

    Config.getDefaultConfig/reloadConfig/set enforce the preload policy before
    the value can reach cached config, disk, or config-updated subscribers. set
    mutates its input, covering both POST /api/config and OneBot set_config.
    Logging starts disabled; log=false now gates cache/SSE before any export.
    Four credential logging calls and raw inbound request payload logging are
    removed at source, before the independent console exporter also sees them.
    Account data, Auth Token/QR APIs and all other runtime behavior stay upstream.
    """
    if hashlib.sha256(original).hexdigest() != BUNDLE_SHA256:
        raise DeploymentError('integrity')
    text = original.decode('utf-8')
    policy = 'globalThis[Symbol.for("oc.llbot.managedConfig.v2")]'

    def edit(region, changes):
        nonlocal text
        marker = f'//#region {region}\n'
        if text.count(marker) != 1:
            raise DeploymentError('integrity')
        begin = text.index(marker) + len(marker)
        end = text.index('//#endregion', begin)
        section = text[begin:end]
        for old, new in changes:
            if section.count(old) != 1:
                raise DeploymentError('integrity')
            section = section.replace(old, new, 1)
        text = text[:begin] + section + text[end:]

    edit('src/main/config/index.ts', [
        ('return _defaultConfig;', f'return {policy}(_defaultConfig);'),
        ('jsonData = this.cleanupConfig(defaultConfig, jsonData);',
         f'jsonData = {policy}(this.cleanupConfig(defaultConfig, jsonData));'),
        ('set(config) {\n\t\tthis.config = config;',
         f'set(config) {{\n\t\t{policy}(config);\n\t\tthis.config = config;'),
    ])
    edit('src/main/log.ts', [
        ('this.exportFile = true;', 'this.exportFile = false;'),
        ('export(message) {\n', 'export(message) {\n\t\tif (!this.exportFile) return;\n'),
        ('\n\t\tif (!this.exportFile) return;\n\t\tif (this.currentSize',
         '\n\t\tif (this.currentSize'),
    ])
    edit('src/onebot11/connect/ws.ts', [
        ('\t\t\t\tthis.ctx.logger.info("receive ws header token", clientToken);\n', ''),
        ('\t\t\t\t\tthis.ctx.logger.info("receive ws url token", clientToken);\n', ''),
        ('this.ctx.logger.info("收到正向 Websocket 消息", receive);',
         'this.ctx.logger.info("收到正向 Websocket 消息");'),
    ])
    edit('src/onebot11/connect/http.ts', [
        ('\t\t\tthis.ctx.logger.info("receive http header token", clientToken);\n', ''),
        ('\t\t\tthis.ctx.logger.info("receive http url token", clientToken);\n', ''),
        ('this.ctx.logger.info("收到 HTTP 请求", c.req.url, payload);',
         'this.ctx.logger.info("收到 HTTP 请求", c.req.method);'),
    ])
    header = ('/* LuckyLilliaBot v8.3.2, LuckyLilliaBot contributors (linyuchen et al.).\n'
              ' * LLBot portions: GPL-2.0; see ../../COPYING.LLBot and ../../NOTICES.txt.\n'
              ' * Bundled dependencies retain their respective upstream licenses.\n'
              f' * Source: https://github.com/LuckyLilliaDev/LuckyLilliaBot/tree/{SOURCE_COMMIT}\n'
              ' * Modified by OpenCode Plus on 2026-11-27: enforce managed config on\n'
              ' * default/load/save, suppress disabled file/cache/stream logs, and\n'
              ' * remove received credentials and raw request payloads from logging.\n'
              ' * This is a locally modified runtime, not an unmodified upstream build.\n'
              ' */\n')
    return (header + text).encode('utf-8')


def prepare_runtime(runtime):
    patched = patch_bundle((runtime / 'llbot.js').read_bytes())
    if hashlib.sha256(patched).hexdigest() != MANAGED_BUNDLE_SHA256:
        raise DeploymentError('integrity')
    atomic_bytes(runtime / 'llbot.js', patched)


def unpack(archive, destination, deadline):
    """No extractall: reject traversal, duplicates, links, devices and zip bombs."""
    seen = set()
    total = 0
    try:
        with zipfile.ZipFile(archive) as bundle:
            if len(bundle.infolist()) > 10000:
                raise DeploymentError('archive_invalid')
            for entry in bundle.infolist():
                deadline_check(deadline)
                name = entry.filename
                parts = PurePosixPath(name).parts
                kind = stat.S_IFMT(entry.external_attr >> 16)
                if (name.startswith('/') or '\\' in name or ':' in name
                        or any(ord(c) < 32 or ord(c) == 127 for c in name)
                        or '' in name.rstrip('/').split('/')
                        or any(p in ('.', '..') for p in name.split('/'))
                        or kind not in (0, stat.S_IFDIR, stat.S_IFREG)
                        or name in seen or entry.flag_bits & 1):
                    raise DeploymentError('archive_invalid')
                seen.add(name)
                total += entry.file_size
                if total > MAX_UNPACKED:
                    raise DeploymentError('archive_invalid')
                # Upstream also ships launch scripts next to bin/llbot. We use
                # only the runtime tree, with our tracked foreground launcher.
                if parts[:2] != ('bin', 'llbot') or len(parts) <= 2:
                    continue
                target = destination.joinpath(*parts[2:])
                if entry.is_dir():
                    target.mkdir(mode=0o700, parents=True, exist_ok=True)
                    continue
                target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
                with bundle.open(entry) as source, target.open('xb') as out:
                    copied = 0
                    while chunk := source.read(256 * 1024):
                        deadline_check(deadline)
                        copied += len(chunk)
                        if copied > entry.file_size:
                            raise DeploymentError('archive_invalid')
                        out.write(chunk)
                target.chmod(0o700 if parts[2:] == ('node',) else 0o600)
    except (zipfile.BadZipFile, ValueError) as error:
        raise DeploymentError('archive_invalid') from error
    for name in ('node', 'llbot.js', 'default_config.json', 'package.json', 'webui/index.html'):
        if not (destination / name).is_file():
            raise DeploymentError('archive_invalid')


def current(root, *, verify=False):
    try:
        record = read_record(root / 'current.json')
    except FileNotFoundError:
        return None
    except (DeploymentError, OSError, ValueError, TypeError):
        raise DeploymentError('integrity') from None
    directory = record.get('directory', '')
    tree = record.get('tree', '')
    if (record.get('version') != VERSION or record.get('archive') != ARCHIVE_SHA256
            or record.get('patch') != PATCH_ID
            or record.get('bundle') != MANAGED_BUNDLE_SHA256
            or not isinstance(directory, str)
            or not re.fullmatch(r'release-[a-f0-9]{32}', directory)
            or not isinstance(tree, str) or not HASH.fullmatch(tree)):
        raise DeploymentError('integrity')
    runtime = root / 'releases' / directory
    try:
        if not stat.S_ISDIR(runtime.lstat().st_mode):
            raise DeploymentError('integrity')
        if verify and (tree_digest(runtime) != tree
                       or digest_file(runtime / 'llbot.js') != MANAGED_BUNDLE_SHA256):
            raise DeploymentError('integrity')
    except (OSError, ValueError, TypeError):
        raise DeploymentError('integrity') from None
    return runtime


def configure(root):
    state = root / 'state'
    private_dir(state)
    for name in ('data', 'home', 'tmp'):
        private_dir(state / name)
    credentials = state / 'connection.json'
    try:
        record = read_record(credentials)
        if not HASH.fullmatch(record.get('accessToken', '')):
            raise DeploymentError('credentials')
    except FileNotFoundError:
        record = {'accessToken': secrets.token_hex(32)}
        write_record(credentials, record)
    password = state / 'data/webui_token.txt'
    try:
        value = read_bytes(password, 129).strip()
        if not re.fullmatch(rb'[!-~]{16,128}', value):
            raise DeploymentError('credentials')
    except FileNotFoundError:
        atomic_bytes(password, (secrets.token_hex(32) + '\n').encode('ascii'))
    # No auth_token / QQ session / account configuration is read or changed.


def install(root, job, *, downloader=download):
    require_platform()
    private_dir(root)
    with lock(root / 'install.lock'):
        def progress(stage, phase='installing', failure=None):
            write_record(root / 'job.json', {'job': job, 'phase': phase, 'stage': stage,
                                              'failure': failure})
        progress('checking')
        try:
            for name in ('releases', 'staging'):
                private_dir(root / name)
            try:
                runtime = current(root, verify=True)
            except (DeploymentError, FileNotFoundError):
                runtime = None
            if runtime is not None:
                progress('configure')
                configure(root)
                progress('configure', 'installed')
                return
            with lock(root / 'run.lock'):
                # Only this helper's failed staging directories are reclaimed.
                for old in (root / 'staging').iterdir():
                    if re.fullmatch(r'job-[a-f0-9]{32}', old.name) and not old.is_symlink():
                        shutil.rmtree(old)
                if shutil.disk_usage(root).free < ARCHIVE_BYTES + MAX_UNPACKED + 32 * 1024 * 1024:
                    raise DeploymentError('storage')
                stage = root / 'staging' / f'job-{job}'
                private_dir(stage)
                deadline = time.monotonic() + 12 * 60
                try:
                    archive = stage / 'bundle.zip'
                    progress('download')
                    downloader(archive, deadline)
                    progress('verify')
                    if archive.stat().st_size != ARCHIVE_BYTES or digest_file(archive) != ARCHIVE_SHA256:
                        raise DeploymentError('integrity')
                    progress('install')
                    payload = stage / 'runtime'
                    private_dir(payload)
                    unpack(archive, payload, deadline)
                    prepare_runtime(payload)
                    tree = tree_digest(payload)
                    progress('configure')
                    configure(root)
                    # The immutable tree is complete before publishing a single
                    # atomic pointer. Earlier runtime and login state survive.
                    directory = f'release-{secrets.token_hex(16)}'
                    os.replace(payload, root / 'releases' / directory)
                    write_record(root / 'current.json', {'version': VERSION, 'archive': ARCHIVE_SHA256,
                                                          'directory': directory, 'tree': tree,
                                                          'patch': PATCH_ID,
                                                          'bundle': MANAGED_BUNDLE_SHA256,
                                                          'download': URL,
                                                          'source': 'https://github.com/LuckyLilliaDev/'
                                                          f'LuckyLilliaBot/tree/{SOURCE_COMMIT}'})
                    progress('configure', 'installed')
                finally:
                    shutil.rmtree(stage, ignore_errors=True)
        except Exception as error:
            code = error.code if isinstance(error, DeploymentError) else 'install_failed'
            progress('checking', 'failed', code)
            raise DeploymentError(code) from None


def ports_free():
    for port in (CONSOLE_PORT, ONEBOT_PORT):
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
            probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            try:
                probe.bind((HOST, port))
            except OSError as error:
                raise DeploymentError('port_busy') from error


def console_ready():
    conn = http.client.HTTPConnection(HOST, CONSOLE_PORT, timeout=1)
    try:
        conn.request('GET', '/', headers={'Connection': 'close'})
        response = conn.getresponse()
        return (response.status == 200 and 'text/html' in response.getheader('Content-Type', '').lower()
                and b'<html' in response.read(4096).lower())
    except (OSError, http.client.HTTPException):
        return False
    finally:
        conn.close()


def launch_spec(runtime, state):
    args = [str(runtime / 'node'), '--permission', f'--allow-fs-read={runtime}',
            f'--allow-fs-read={GUARD}', f'--allow-fs-read={state}', f'--allow-fs-write={state}',
            '--allow-addons', '--import', str(GUARD), str(runtime / 'llbot.js')]
    env = {'PATH': '/usr/bin:/bin', 'HOME': str(state / 'home'), 'TMPDIR': str(state / 'tmp'),
           'LANG': 'C.UTF-8', 'TZ': 'UTC', 'NODE_ENV': 'production',
           'OC_LLBOT_SUPERVISOR_PID': str(os.getpid())}
    return args, env


def stop_child(child):
    if child.poll() is None:
        try:
            os.killpg(child.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            child.wait(timeout=3)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
    child.wait(timeout=3)


def run(root, generation):
    require_platform()
    private_dir(root)
    with lock(root / 'run.lock') as run_lock:
        def report(phase, failure=None):
            write_record(root / 'run.json', {'generation': generation, 'phase': phase, 'failure': failure})
        report('starting')
        child = None
        interrupted = False
        def interrupt(_number, _frame):
            nonlocal interrupted
            interrupted = True
        handlers = {sig: signal.signal(sig, interrupt) for sig in (signal.SIGTERM, signal.SIGINT)}
        try:
            runtime = current(root, verify=True)
            if runtime is None:
                raise DeploymentError('not_installed')
            configure(root)
            ports_free()
            args, env = launch_spec(runtime, root / 'state')
            child = subprocess.Popen(args, cwd=root / 'state', env=env, start_new_session=True,
                                     stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                     stderr=subprocess.STDOUT, pass_fds=(run_lock,))
            ready = False
            bound = False
            pending = b''
            deadline = time.monotonic() + 75
            with child.stdout, selectors.DefaultSelector() as selector:
                selector.register(child.stdout, selectors.EVENT_READ)
                os.set_blocking(child.stdout.fileno(), False)
                while not interrupted:
                    if child.poll() is not None:
                        raise DeploymentError('runtime_exited')
                    for key, _ in selector.select(0.25):
                        try:
                            chunk = os.read(key.fd, 16384)
                        except BlockingIOError:
                            continue
                        if not chunk:
                            selector.unregister(key.fileobj)
                            continue
                        lines = (pending + chunk).split(b'\n')
                        pending = lines.pop()[-16384:]
                        # Never store/pass through vendor output (QRs, passwords,
                        # account data and native stack traces may be present).
                        for line in lines:
                            if line == b'OC_LLBOT_CONSOLE_BOUND':
                                bound = True
                            elif line == b'OC_LLBOT_CONSOLE_CLOSED':
                                bound = ready = False
                                deadline = time.monotonic() + 75
                                report('starting')
                            elif line == b'OC_LLBOT_LISTENER_REFUSED':
                                raise DeploymentError('listener_refused')
                    if not ready and bound and console_ready():
                        ready = True
                        report('running')
                    if not ready and time.monotonic() > deadline:
                        raise DeploymentError('start_timeout')
            report('stopped')
        except Exception as error:
            code = error.code if isinstance(error, DeploymentError) else 'start_failed'
            report('failed', code)
            raise DeploymentError(code) from None
        finally:
            if child is not None:
                stop_child(child)
            for sig, handler in handlers.items():
                signal.signal(sig, handler)


def main(argv=None):
    parser = argparse.ArgumentParser(description='App-managed LLBot runtime')
    parser.add_argument('action', choices=('install', 'run'))
    parser.add_argument('--job', required=True)
    args = parser.parse_args(argv)
    if not ID.fullmatch(args.job):
        return 2
    os.umask(0o077)
    try:
        if args.action == 'install':
            install(ROOT, args.job)
        else:
            run(ROOT, args.job)
    except Exception as error:
        code = error.code if isinstance(error, DeploymentError) else 'install_failed'
        print(json.dumps({'failure': code}), flush=True)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
