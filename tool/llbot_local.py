"""Manual, on-phone enrollment launcher for the verified LLBot local copy."""

import argparse
import fcntl
import getpass
import hashlib
import http.client
import json
import os
import re
import secrets
import selectors
import signal
import socket
import stat
import subprocess
import sys
import tempfile
import time
import warnings
from contextlib import contextmanager
from pathlib import Path


HOST = '127.0.0.1'
PORT = 3080
WEBUI = f'http://{HOST}:{PORT}/'
BUNDLE_SHA256 = 'f911f08ccaf8ea2edb916a8ecc63c15fa8afee557269f1e0e06dacbe72e2d245'
GUARD = Path(__file__).resolve().with_name('llbot_local_guard.mjs')
OPEN_SAFE = os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK
GENERATION = re.compile(r'[0-9a-f]{32}\Z')


class DeploymentError(Exception):
    pass


def base_path():
    return Path.home() / '.local/share/oc-plus/qq-onebot-poc/llbot/v8.3.2'


def tree_digest(root):
    if not stat.S_ISDIR(root.lstat().st_mode):
        raise DeploymentError('运行包目录不是普通目录。')
    files = []

    def fail(error):
        raise error

    for directory, dirs, names in os.walk(root, onerror=fail, followlinks=False):
        parent = Path(directory)
        for name in dirs:
            if not stat.S_ISDIR((parent / name).lstat().st_mode):
                raise DeploymentError('运行包含有符号链接。')
        files.extend(parent / name for name in names)
    digest = hashlib.sha256()
    for path in sorted(files, key=lambda p: p.relative_to(root).as_posix()):
        with os.fdopen(os.open(path, os.O_RDONLY | OPEN_SAFE), 'rb') as source:
            if not stat.S_ISREG(os.fstat(source.fileno()).st_mode):
                raise DeploymentError('运行包含有非常规文件。')
            digest.update(path.relative_to(root).as_posix().encode('utf-8') + b'\0')
            digest.update(hashlib.file_digest(source, 'sha256').digest())
    return digest.hexdigest()


def check_runtime(runtime):
    if os.uname().sysname != 'Linux' or os.uname().machine not in ('aarch64', 'arm64'):
        raise DeploymentError('此运行副本仅支持 Linux ARM64。')
    for name in ('node', 'llbot.js', 'default_config.json'):
        path = runtime / name
        if not path.exists() or not stat.S_ISREG(path.lstat().st_mode):
            raise DeploymentError('未找到准备好的 LLBot v8.3.2 本地运行副本。')
    if not os.access(runtime / 'node', os.X_OK) or tree_digest(runtime) != BUNDLE_SHA256:
        raise DeploymentError('本地运行副本未通过完整性校验，已拒绝启动。')


def private_dir(path, *, create=True):
    if create:
        path.mkdir(mode=0o700, exist_ok=True)
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise DeploymentError(f'目录必须由当前用户独占且不能是链接：{path.name}')


def file_info(fd):
    info = os.fstat(fd)
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise DeploymentError('状态文件或凭据文件不是私有普通文件。')
    return info


@contextmanager
def run_lock(state):
    lock = os.open(state / 'run.lock', os.O_RDWR | os.O_CREAT | OPEN_SAFE, 0o600)
    try:
        file_info(lock)
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise DeploymentError('已有一个 LLBot 操作在运行。') from error
        yield lock
    finally:
        os.close(lock)


def read_record(path):
    try:
        with os.fdopen(os.open(path, os.O_RDONLY | OPEN_SAFE), 'rb') as record:
            file_info(record.fileno())
            decoded = json.loads(record.read(2048))
            return decoded if isinstance(decoded, dict) else {}
    except (FileNotFoundError, ValueError):
        return {}


def write_record(path, record):
    fd, name = tempfile.mkstemp(prefix='.record-', dir=path.parent)
    temp = Path(name)
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as out:
            json.dump(record, out)
        temp.replace(path)
    finally:
        temp.unlink(missing_ok=True)


def status(state):
    try:
        private_dir(state, create=False)
        lock = os.open(state / 'run.lock', os.O_RDONLY | OPEN_SAFE)
    except FileNotFoundError:
        return {'phase': 'stopped'}
    try:
        file_info(lock)
        try:
            fcntl.flock(lock, fcntl.LOCK_SH | fcntl.LOCK_NB)
        except BlockingIOError:
            record = read_record(state / 'status.json')
            generation = record.get('generation')
            phase = record.get('phase')
            if isinstance(generation, str) and GENERATION.fullmatch(generation) and phase in ('starting', 'webui'):
                return {'phase': phase, 'generation': generation}
            return {'phase': 'busy'}
        return {'phase': 'stopped'}
    finally:
        os.close(lock)


def request_stop(state):
    current = status(state)
    generation = current.get('generation')
    if not generation:
        if current['phase'] == 'busy':
            raise DeploymentError('操作还未登记，请稍后再查状态。')
        return False
    # Never signal an externally supplied PID. A newer run ignores old requests.
    write_record(state / f'stop-{generation}.json', {'generation': generation})
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline:
        observed = status(state)
        if observed['phase'] == 'stopped' or observed.get('generation') not in (None, generation):
            return True
        time.sleep(0.1)
    raise DeploymentError('已请求停止，但未确认退出。请检查运行终端。')


def stop_requested(state, generation):
    return read_record(state / f'stop-{generation}.json').get('generation') == generation


def create_webui_password(path, password):
    if not re.fullmatch(r'[!-~]{16,128}', password):
        raise DeploymentError('WebUI 密码需为 16–128 个不含空白的 ASCII 字符。')
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | OPEN_SAFE, 0o600)
    except FileExistsError as error:
        raise DeploymentError('WebUI 密码文件已存在，不覆盖。') from error
    with os.fdopen(fd, 'w', encoding='ascii') as out:
        out.write(password + '\n')


def init_webui(state):
    if not sys.stdin.isatty() or not sys.stderr.isatty():
        raise DeploymentError('请在你自己的交互终端运行 init-webui，不要把密码发到聊天里。')
    private_dir(state)
    with run_lock(state):
        private_dir(state / 'data')
        path = state / 'data/webui_token.txt'
        if os.path.lexists(path):
            raise DeploymentError('WebUI 密码文件已存在，不覆盖。')
        with warnings.catch_warnings():
            warnings.simplefilter('error', getpass.GetPassWarning)
            try:
                password = getpass.getpass('WebUI 密码（不回显）：')
                if password != getpass.getpass('再输入一次：'):
                    raise DeploymentError('两次输入不一致，未保存。')
            except getpass.GetPassWarning as error:
                raise DeploymentError('终端不能隐藏输入，未保存密码。') from error
        create_webui_password(path, password)


def require_webui_password(state):
    try:
        with os.fdopen(os.open(state / 'data/webui_token.txt', os.O_RDONLY | OPEN_SAFE), 'rb') as password:
            if (not 16 <= file_info(password.fileno()).st_size <= 129
                    or not re.fullmatch(rb'[!-~]{16,128}\n?', password.read(130))):
                raise DeploymentError('WebUI 密码文件格式异常，请先核对。')
    except FileNotFoundError as error:
        raise DeploymentError('请先在自己的交互终端运行 init-webui。') from error


def ensure_free_port():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
        probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            probe.bind((HOST, PORT))
        except OSError as error:
            raise DeploymentError(f'不能使用环回端口 {PORT}，不尝试其他地址或端口。') from error


def webui_ready():
    conn = http.client.HTTPConnection(HOST, PORT, timeout=0.6)
    try:
        conn.request('GET', '/', headers={'Connection': 'close'})
        response = conn.getresponse()
        return (response.status == 200 and 'text/html' in response.getheader('Content-Type', '').lower()
                and b'<html' in response.read(4096).lower())
    except (OSError, http.client.HTTPException):
        return False
    finally:
        conn.close()


def launch_spec(runtime, state, smoke):
    args = [str(runtime / 'node'), '--permission', f'--allow-fs-read={runtime}',
            f'--allow-fs-read={GUARD}', f'--allow-fs-read={state}', f'--allow-fs-write={state}']
    if not smoke:
        args.append('--allow-addons')
    args.extend(('--import', str(GUARD), str(runtime / 'llbot.js')))
    env = {'PATH': '/usr/bin:/bin', 'HOME': str(state / 'home'), 'TMPDIR': str(state / 'tmp'),
           'LANG': 'C.UTF-8', 'TZ': 'UTC', 'NODE_ENV': 'production',
           'OC_LLBOT_MODE': 'smoke' if smoke else 'enroll', 'OC_LLBOT_SUPERVISOR_PID': str(os.getpid())}
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


def monitor(child, state, generation, smoke, interrupted):
    bound = False
    ready_at = None
    awaiting_auth = False
    deadline = time.monotonic() + 18
    pending = b''
    with selectors.DefaultSelector() as selector:
        selector.register(child.stdout, selectors.EVENT_READ)
        os.set_blocking(child.stdout.fileno(), False)
        while True:
            if interrupted() or stop_requested(state, generation):
                if smoke and ready_at is None:
                    raise DeploymentError('未完成 WebUI 自检。')
                return
            if child.poll() is not None:
                raise DeploymentError(f'LLBot 已退出（状态 {child.returncode}）。')
            for key, _ in selector.select(0.25):
                try:
                    chunk = os.read(key.fd, 8192)
                except BlockingIOError:
                    continue
                if not chunk:
                    selector.unregister(key.fileobj)
                    continue
                lines = (pending + chunk).split(b'\n')
                pending = lines.pop()[-16384:]
                # Never pass through raw output, including WebUI or QQ credentials.
                for line in lines:
                    if line == b'OC_LLBOT_HTTP_READY':
                        bound = True
                    elif line.startswith(b'OC_LLBOT_REFUSED '):
                        raise DeploymentError('已阻止不允许的监听地址、端口或离线网络请求。')
                    elif b'auth_token' in line.lower() and '未配置'.encode() in line:
                        awaiting_auth = True
            now = time.monotonic()
            if bound and ready_at is None and webui_ready():
                ready_at = now
                write_record(state / 'status.json', {'generation': generation, 'phase': 'webui'})
                print(f'WebUI 已就绪：{WEBUI}（不代表 QQ 已上线）', flush=True)
            if now >= deadline and (ready_at is None or smoke and not awaiting_auth):
                raise DeploymentError('未能确认本机 WebUI 启动。原始日志未输出。')
            if smoke and awaiting_auth and ready_at is not None and now - ready_at >= 1:
                return


def serve(runtime, state, *, smoke=False):
    private_dir(state)
    with run_lock(state) as lock:
        for name in ('home', 'tmp', 'data'):
            private_dir(state / name)
        if not smoke:
            require_webui_password(state)
        ensure_free_port()
        generation = secrets.token_hex(16)
        write_record(state / 'status.json', {'generation': generation, 'phase': 'starting'})
        args, env = launch_spec(runtime, state, smoke)
        interrupted = False

        def interrupt(_number, _frame):
            nonlocal interrupted
            interrupted = True

        handlers = {sig: signal.signal(sig, interrupt) for sig in (signal.SIGINT, signal.SIGTERM)}
        try:
            child = subprocess.Popen(args, cwd=state, env=env, start_new_session=True,
                                     stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                     pass_fds=(lock,))
            with child.stdout:
                try:
                    monitor(child, state, generation, smoke, lambda: interrupted)
                finally:
                    stop_child(child)
        finally:
            for sig, handler in handlers.items():
                signal.signal(sig, handler)
            write_record(state / 'status.json', {'generation': generation, 'phase': 'stopped'})
            (state / f'stop-{generation}.json').unlink(missing_ok=True)


def main(argv=None):
    parser = argparse.ArgumentParser(description='手机 Ubuntu 的 LLBot v8.3.2 手动部署入口（只开放本机 WebUI）')
    parser.add_argument('action', choices=('check', 'smoke', 'init-webui', 'run', 'status', 'stop'))
    action = parser.parse_args(argv).action
    os.umask(0o077)
    base = base_path()
    runtime, state = base / 'runtime-local-v1', base / 'deployment'
    try:
        if action == 'status':
            phase = status(state)['phase']
            if phase == 'webui' and not webui_ready():
                phase = 'unreachable'
            print({'starting': '启动中。', 'webui': f'WebUI 已就绪：{WEBUI}',
                   'stopped': '未运行。', 'busy': '有本地操作，但尚无运行状态。',
                   'unreachable': '持有运行锁，但 WebUI 暂不可达。'}[phase])
        elif action == 'stop':
            print('已停止。' if request_stop(state) else '未运行。')
        else:
            check_runtime(runtime)
            if action == 'check':
                print('LLBot v8.3.2 ARM64 本地运行副本完整性校验通过。')
            elif action == 'init-webui':
                init_webui(state)
                print('WebUI 密码已保存在本机私有目录。')
            elif action == 'smoke':
                with tempfile.TemporaryDirectory(prefix='launcher-smoke-', dir=base) as temp:
                    serve(runtime, Path(temp), smoke=True)
                print('离线自检通过；进程已停止，未使用账号数据。')
            elif action == 'run':
                serve(runtime, state)
                print('LLBot 已停止。')
    except (DeploymentError, OSError, subprocess.TimeoutExpired, EOFError, KeyboardInterrupt) as error:
        print(str(error) if isinstance(error, DeploymentError) else f'本地操作未完成（{type(error).__name__}）。',
              file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
