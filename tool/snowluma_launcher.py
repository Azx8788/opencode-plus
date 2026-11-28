"""Starts SnowLuma from the official archive a person selected themselves.

The app never downloads SnowLuma. It copies the exact file the person picked
into ROOT/import; this helper checks its size and SHA-256 against the published
v2.4.2 Linux ARM64 assets, extracts it under ROOT/releases and runs the
included launcher. Vendor output (QR codes, account data, stack traces) is
discarded, never stored or passed back to the app.

SnowLuma's EULA section 5.4 requires prior written authorization before a
Proprietary Component is deployed through an automated script. Running this
helper is therefore the person's decision, not a licence granted by this repo;
see docs/SNOWLUMA_SETUP.md. Only stdlib is used.
"""

import argparse
import fcntl
import hashlib
import http.client
import json
import os
import re
import selectors
import shutil
import signal
import socket
import stat
import subprocess
import sys
import tarfile
import time
from contextlib import contextmanager
from pathlib import Path, PurePosixPath

VERSION = '2.4.2'
ROOT = Path('/root/.oc-builtin/snowluma')
RELEASES = {
    'full': ('SnowLuma-v2.4.2-linux-arm64.tar.gz', 52545976,
             'c4bcff22828fb465d6fbd8caa375e82432fd3af684b297c43f2c428a2de2200c'),
    'lite': ('SnowLuma-v2.4.2-linux-arm64-lite.tar.gz', 8064625,
             'f3bc5cdc660fc23701d64e16082aead3159bf24968f7c08cff49933cba7b5753'),
}
HOST = '127.0.0.1'
WEBUI_PORT = 5099
MAX_EXTRACTED = 400 * 1024 * 1024
MAX_MEMBERS = 40000
SAFE_OPEN = os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK
ID = re.compile(r'[a-f0-9]{32}\Z')
HASH = re.compile(r'[a-f0-9]{64}\Z')
DIRECTORY = re.compile(r'release-[a-f0-9]{16}\Z')
STAGES = {'verify', 'install', 'start'}
FAILURES = {
    'unsupported', 'storage', 'integrity', 'archive_invalid', 'not_installed',
    'node_missing', 'node_incompatible', 'port_busy', 'start_failed',
    'start_timeout', 'runtime_exited', 'install_failed', 'install_timeout',
    'stop_failed',
}


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
    if os.path.realpath(path) != str(path):
        raise DeploymentError('storage')
    return path


def atomic_bytes(path, content):
    temporary = path.with_name(f'{path.name}.{os.getpid()}.tmp')
    try:
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | SAFE_OPEN, 0o600)
        try:
            os.write(fd, content)
            os.fsync(fd)
        finally:
            os.close(fd)
        os.replace(temporary, path)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def write_record(path, value):
    atomic_bytes(path, json.dumps(value, ensure_ascii=False).encode('utf-8'))


def read_record(path):
    try:
        fd = os.open(path, os.O_RDONLY | SAFE_OPEN)
    except FileNotFoundError:
        return None
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_size > 65536:
            raise DeploymentError('storage')
        data = os.read(fd, 65536)
    finally:
        os.close(fd)
    try:
        value = json.loads(data)
    except ValueError:
        raise DeploymentError('storage') from None
    if not isinstance(value, dict):
        raise DeploymentError('storage')
    return value


@contextmanager
def lock(path):
    fd = os.open(path, os.O_RDWR | os.O_CREAT | SAFE_OPEN, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield fd
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)


def digest_file(path):
    digest = hashlib.sha256()
    size = 0
    with open(path, 'rb') as source:
        while True:
            chunk = source.read(1024 * 1024)
            if not chunk:
                break
            size += len(chunk)
            if size > 200 * 1024 * 1024:
                raise DeploymentError('integrity')
            digest.update(chunk)
    return size, digest.hexdigest()


def verify_archive(path, expected_size, expected_digest):
    try:
        info = path.lstat()
    except FileNotFoundError:
        raise DeploymentError('integrity') from None
    if not stat.S_ISREG(info.st_mode) or info.st_size != expected_size:
        raise DeploymentError('integrity')
    size, digest = digest_file(path)
    if size != expected_size or digest != expected_digest:
        raise DeploymentError('integrity')


def member_path(name):
    pure = PurePosixPath(name)
    parts = [part for part in pure.parts if part not in ('', '.')]
    if pure.is_absolute() or any(part == '..' for part in parts):
        raise DeploymentError('archive_invalid')
    if not parts:
        return None
    return PurePosixPath(*parts)


def extracted_root(directory):
    if (directory / 'index.mjs').is_file():
        return directory
    children = [entry for entry in directory.iterdir() if entry.is_dir()]
    if len(children) == 1 and (children[0] / 'index.mjs').is_file():
        return children[0]
    raise DeploymentError('archive_invalid')


def validate_tree(directory):
    root = extracted_root(directory)
    try:
        manifest = json.loads((root / 'release.json').read_text('utf-8'))
    except (OSError, ValueError):
        raise DeploymentError('archive_invalid') from None
    entries = manifest.get('entries') if isinstance(manifest, dict) else None
    if (manifest.get('version') != VERSION or manifest.get('target') != 'linux-arm64'
            or not isinstance(entries, list) or 'index.mjs' not in entries
            or 'launcher.sh' not in entries):
        raise DeploymentError('archive_invalid')
    launcher = root / 'launcher.sh'
    if not launcher.is_file():
        raise DeploymentError('archive_invalid')
    os.chmod(launcher, launcher.stat().st_mode | 0o500)
    return root


def safe_extract(archive, destination):
    with tarfile.open(archive, 'r:gz') as bundle:
        members = bundle.getmembers()
        if not members or len(members) > MAX_MEMBERS:
            raise DeploymentError('archive_invalid')
        total = 0
        for member in members:
            path = member_path(member.name)
            total += max(member.size, 0)
            if total > MAX_EXTRACTED:
                raise DeploymentError('archive_invalid')
            if path is None:
                if not member.isdir():
                    raise DeploymentError('archive_invalid')
                continue
            if member.isdir():
                continue
            if member.issym():
                target = PurePosixPath(member.linkname)
                if target.is_absolute() or any(part == '..' for part in target.parts):
                    raise DeploymentError('archive_invalid')
                continue
            if member.islnk():
                if member_path(member.linkname) is None:
                    raise DeploymentError('archive_invalid')
                continue
            if not member.isfile():
                raise DeploymentError('archive_invalid')
        destination.mkdir(mode=0o700, parents=False, exist_ok=False)
        try:
            try:
                bundle.extractall(destination, members=members, filter='data')
            except TypeError:
                bundle.extractall(destination, members=members)
        except (tarfile.TarError, OSError):
            raise DeploymentError('archive_invalid') from None
    return extraction_root(destination)


def extraction_root(directory):
    root = extracted_root(directory)
    if root != directory:
        for item in list(root.iterdir()):
            os.replace(item, directory / item.name)
        root.rmdir()
    return directory


def current(root):
    record = read_record(root / 'current.json')
    if record is None:
        return None
    directory = record.get('directory')
    digest = record.get('sha256')
    release = record.get('release')
    if (record.get('version') != VERSION or release not in RELEASES
            or not isinstance(digest, str) or not HASH.fullmatch(digest)
            or digest != RELEASES[release][2]
            or not isinstance(directory, str) or not DIRECTORY.fullmatch(directory)
            or not (root / 'releases' / directory / 'index.mjs').is_file()):
        raise DeploymentError('not_installed')
    return root / 'releases' / directory


def port_busy():
    probe = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        probe.bind((HOST, WEBUI_PORT))
        return False
    except OSError:
        return True
    finally:
        probe.close()


def webui_ready():
    connection = http.client.HTTPConnection(HOST, WEBUI_PORT, timeout=1.5)
    try:
        connection.request('GET', '/', headers={'Connection': 'close'})
        response = connection.getresponse()
        body = response.read(8192).lower()
        return (response.status == 200 and b'<title>' in body
                and b'snowluma' in body)
    except (OSError, http.client.HTTPException):
        return False
    finally:
        connection.close()


def find_node(root):
    bundled = root / 'node'
    if bundled.is_file() and os.access(bundled, os.X_OK):
        return str(bundled)
    for directory in ('/usr/local/bin', '/usr/bin', '/bin'):
        candidate = Path(directory) / 'node'
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return str(candidate)
    found = shutil.which('node', path='/usr/local/bin:/usr/bin:/bin')
    if found:
        return found
    raise DeploymentError('node_missing')


def check_node(root, node):
    checker = root / 'check-node-version.cjs'
    if not checker.is_file():
        return
    try:
        result = subprocess.run(
            [node, str(checker)], cwd=root, env=launch_env(),
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL, timeout=30)
    except (OSError, subprocess.TimeoutExpired):
        raise DeploymentError('node_incompatible') from None
    if result.returncode != 0:
        raise DeploymentError('node_incompatible')


def launch_env():
    state = ROOT / 'state'
    return {
        'PATH': '/usr/local/bin:/usr/bin:/bin',
        'HOME': str(state / 'home'),
        'TMPDIR': str(state / 'tmp'),
        'LANG': 'C.UTF-8',
        'TZ': 'UTC',
        'XDG_RUNTIME_DIR': str(state / 'run'),
        'SNOWLUMA_HOOK_RUNTIME_DIR': str(state / 'run'),
        'SNOWLUMA_STREAM_DIR': str(state / 'stream'),
        'SNOWLUMA_WEBUI_HOST': HOST,
        'SNOWLUMA_WEBUI_PORT': str(WEBUI_PORT),
    }


def prepare_state():
    private_dir(ROOT / 'state')
    for name in ('home', 'tmp', 'run', 'stream'):
        private_dir(ROOT / 'state' / name)


def stop_child(child):
    if child is None:
        return
    if child.poll() is None:
        try:
            os.killpg(child.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            child.wait(timeout=4)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
    try:
        child.wait(timeout=3)
    except subprocess.TimeoutExpired:
        pass


def install(root, job, release):
    filename, expected_size, expected_digest = RELEASES[release]
    report = lambda phase, stage=None, failure=None: write_record(  # noqa: E731
        root / 'job.json',
        {'job': job, 'phase': phase, 'stage': stage, 'failure': failure})
    report('installing', 'verify')
    archive = root / 'import' / filename
    verify_archive(archive, expected_size, expected_digest)
    directory = f'release-{expected_digest[:16]}'
    target = root / 'releases' / directory
    if not (target / 'index.mjs').is_file():
        report('installing', 'install')
        staging = root / 'releases' / f'.staging-{job}'
        if staging.exists():
            shutil.rmtree(staging)
        extracted = safe_extract(archive, staging)
        validate_tree(extracted)
        if target.exists():
            shutil.rmtree(target)
        os.replace(extracted, target)
    validate_tree(target)
    write_record(root / 'current.json', {
        'version': VERSION,
        'release': release,
        'sha256': expected_digest,
        'directory': directory,
    })
    report('installed', 'install')


def run(root, generation):
    private_dir(root)
    prepare_state()

    def report(phase, failure=None):
        write_record(root / 'run.json',
                     {'generation': generation, 'phase': phase, 'failure': failure})

    with lock(root / 'run.lock'):
        report('starting')
        release_dir = current(root)
        if release_dir is None:
            raise DeploymentError('not_installed')
        if port_busy():
            raise DeploymentError('port_busy')
        node = find_node(release_dir)
        check_node(release_dir, node)
        launcher = release_dir / 'launcher.sh'
        args = ([str(launcher)] if launcher.is_file()
                else [node, str(release_dir / 'index.mjs')])
        child = None
        interrupted = False

        def interrupt(_number, _frame):
            nonlocal interrupted
            interrupted = True

        handlers = {sig: signal.signal(sig, interrupt)
                    for sig in (signal.SIGTERM, signal.SIGINT)}
        try:
            child = subprocess.Popen(
                args, cwd=release_dir, env=launch_env(), stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                start_new_session=True)
            ready = False
            deadline = time.monotonic() + 150
            with child.stdout, selectors.DefaultSelector() as selector:
                selector.register(child.stdout, selectors.EVENT_READ)
                os.set_blocking(child.stdout.fileno(), False)
                while not interrupted:
                    if child.poll() is not None:
                        raise DeploymentError('runtime_exited')
                    for key, _ in selector.select(0.25):
                        try:
                            if not os.read(key.fd, 65536):
                                selector.unregister(key.fileobj)
                        except BlockingIOError:
                            continue
                    if not ready and webui_ready():
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
            stop_child(child)
            for sig, handler in handlers.items():
                signal.signal(sig, handler)


def main(argv=None):
    parser = argparse.ArgumentParser(description='Start SnowLuma from a selected release')
    parser.add_argument('action', choices=('install', 'run'))
    parser.add_argument('--job', required=True)
    parser.add_argument('--release', choices=sorted(RELEASES))
    args = parser.parse_args(argv)
    if not ID.fullmatch(args.job):
        return 2
    os.umask(0o077)
    try:
        if args.action == 'install':
            if args.release is None:
                return 2
            install(ROOT, args.job, args.release)
        else:
            run(ROOT, args.job)
    except Exception as error:
        code = (error.code if isinstance(error, DeploymentError)
                else 'install_failed' if args.action == 'install' else 'start_failed')
        if args.action == 'install':
            write_record(ROOT / 'job.json', {
                'job': args.job, 'phase': 'failed', 'stage': None, 'failure': code})
        else:
            write_record(ROOT / 'run.json', {
                'generation': args.job, 'phase': 'failed', 'failure': code})
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())