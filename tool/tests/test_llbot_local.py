import getpass
import os
import stat
import tempfile
import threading
import unittest
import warnings
from pathlib import Path
from unittest.mock import patch

from tool import llbot_local as launcher


class LauncherTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.state = self.root / 'deployment'

    def test_payload_digest_changes_with_content_and_rejects_links(self):
        runtime = self.root / 'runtime'
        runtime.mkdir()
        file = runtime / 'node'
        file.write_bytes(b'first')
        initial = launcher.tree_digest(runtime)
        self.assertEqual(launcher.tree_digest(runtime), initial)
        file.write_bytes(b'second')
        self.assertNotEqual(launcher.tree_digest(runtime), initial)
        (runtime / 'alias').symlink_to(file)
        with self.assertRaises(OSError):
            launcher.tree_digest(runtime)

    def test_private_state_fails_closed_on_existing_permissions_or_symlink(self):
        self.state.mkdir(mode=0o700)
        self.state.chmod(0o755)
        with self.assertRaises(launcher.DeploymentError):
            launcher.private_dir(self.state)
        self.assertEqual(stat.S_IMODE(self.state.stat().st_mode), 0o755)
        alias = self.root / 'alias'
        alias.symlink_to(self.state, target_is_directory=True)
        with self.assertRaises(launcher.DeploymentError):
            launcher.private_dir(alias)

    def test_status_ignores_stale_record_and_does_not_create_the_state(self):
        self.assertEqual(launcher.status(self.state), {'phase': 'stopped'})
        self.assertFalse(self.state.exists())
        launcher.private_dir(self.state)
        with launcher.run_lock(self.state):
            self.assertEqual(launcher.status(self.state), {'phase': 'busy'})
            launcher.write_record(self.state / 'status.json', {'phase': 'webui', 'generation': 'b' * 32})
            self.assertEqual(launcher.status(self.state), {'phase': 'webui', 'generation': 'b' * 32})
            with self.assertRaises(launcher.DeploymentError):
                with launcher.run_lock(self.state):
                    self.fail('A second exclusive operation acquired the lock')
        self.assertEqual(launcher.status(self.state), {'phase': 'stopped'})
        self.assertFalse(launcher.request_stop(self.state))

    def test_stop_request_targets_only_the_current_generation(self):
        launcher.private_dir(self.state)
        current = 'c' * 32
        with launcher.run_lock(self.state):
            launcher.write_record(self.state / 'status.json', {'phase': 'starting', 'generation': current})
            outcomes = []
            recorded = threading.Event()
            write_record = launcher.write_record

            def record_stop(path, record):
                write_record(path, record)
                recorded.set()

            with patch.object(launcher, 'write_record', side_effect=record_stop):
                thread = threading.Thread(target=lambda: outcomes.append(launcher.request_stop(self.state)))
                thread.start()
                self.addCleanup(thread.join, 9)
                self.assertTrue(recorded.wait(1))
                self.assertTrue(launcher.stop_requested(self.state, current))
                self.assertFalse(launcher.stop_requested(self.state, 'd' * 32))
        thread.join(2)
        self.assertEqual(outcomes, [True])

    def test_webui_password_must_be_private_strong_and_never_overwritten(self):
        launcher.private_dir(self.state)
        launcher.private_dir(self.state / 'data')
        path = self.state / 'data/webui_token.txt'
        with self.assertRaises(launcher.DeploymentError):
            launcher.require_webui_password(self.state)
        with self.assertRaises(launcher.DeploymentError):
            launcher.create_webui_password(path, 'too short')
        self.assertFalse(path.exists())
        launcher.create_webui_password(path, 'test-only-not-a-real-password')
        launcher.require_webui_password(self.state)
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        with self.assertRaises(launcher.DeploymentError):
            launcher.create_webui_password(path, 'test-only-replacement-password')
        self.assertEqual(path.read_text('ascii'), 'test-only-not-a-real-password\n')
        path.write_bytes(b' ' * 20)
        with self.assertRaises(launcher.DeploymentError):
            launcher.require_webui_password(self.state)

    def test_hidden_input_never_falls_back_to_echoing(self):
        def unsafe_input(_prompt):
            warnings.warn('test-terminal cannot hide input', getpass.GetPassWarning)
            self.fail('getpass warning was not converted to an error')

        with (patch.object(launcher.sys.stdin, 'isatty', return_value=True),
              patch.object(launcher.sys.stderr, 'isatty', return_value=True),
              patch.object(launcher.getpass, 'getpass', side_effect=unsafe_input)):
            with self.assertRaises(launcher.DeploymentError):
                launcher.init_webui(self.state)
        self.assertFalse((self.state / 'data/webui_token.txt').exists())

    def test_invocation_does_not_inherit_auth_or_node_options(self):
        runtime = self.root / 'runtime'
        with patch.dict(os.environ, {'AUTH_TOKEN': 'offline-fake', 'NODE_OPTIONS': '--require /extra'}):
            args, env = launcher.launch_spec(runtime, self.state, True)
            active_args, active_env = launcher.launch_spec(runtime, self.state, False)
        self.assertNotIn('AUTH_TOKEN', env)
        self.assertNotIn('NODE_OPTIONS', active_env)
        self.assertEqual(env['OC_LLBOT_MODE'], 'smoke')
        self.assertEqual(active_env['OC_LLBOT_MODE'], 'enroll')
        self.assertNotIn('--allow-addons', args)
        self.assertIn('--allow-addons', active_args)


if __name__ == '__main__':
    unittest.main()
