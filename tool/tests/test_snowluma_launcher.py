"""SnowLuma launcher tests with synthetic credentials and no vendor runtime."""

import hashlib
import json
import stat
import tempfile
import unittest
from pathlib import Path

from tool import snowluma_launcher as launcher


PASSWORD = b'0123456789abcdef'
LINE = b'12:00:00 INFO              [WebUI] initial credentials: user=admin password=' + PASSWORD


class BootstrapTest(unittest.TestCase):
    def test_parser_only_retains_the_scoped_line_across_reads(self):
        reader = launcher.BootstrapOutput()
        self.assertIsNone(reader.feed(b'QR code\n' + LINE[:40]))
        self.assertEqual(reader.feed(LINE[40:] + b'\r\nother log\n'), PASSWORD)

    def test_unrelated_or_overlong_lines_cannot_supply_the_token(self):
        reader = launcher.BootstrapOutput()
        self.assertIsNone(reader.feed(LINE.replace(b'[WebUI]', b'[Plugin]') + b'\n'))
        self.assertIsNone(reader.feed(b'x' * 300))
        self.assertIsNone(reader.feed(LINE + b'\n'))
        self.assertEqual(reader.feed(LINE + b'\n'), PASSWORD)

    def test_publish_matches_vendor_auth_and_loses_validity_on_rotation(self):
        with tempfile.TemporaryDirectory(prefix='snowluma-bootstrap-') as tmp:
            root = Path(tmp)
            release = root / 'release'
            config = release / 'config'
            config.mkdir(parents=True)
            auth = config / 'webui.json'
            salt = b'fixture-salt-123'
            state = {
                'mustChangePassword': True,
                'passwordSalt': salt.hex(),
                'passwordHash': hashlib.scrypt(
                    PASSWORD, salt=salt, n=16384, r=8, p=1, dklen=64).hex(),
            }
            auth.write_text(json.dumps(state), encoding='utf-8')
            record = root / launcher.BOOTSTRAP_RECORD
            self.assertIsNone(launcher.publish_bootstrap(root, release, 'f' * 32, b'f' * 16))
            self.assertFalse(record.exists())
            digest = launcher.publish_bootstrap(root, release, 'a' * 32, PASSWORD)
            self.assertIsNotNone(digest)
            self.assertEqual(stat.S_IMODE(record.stat().st_mode), 0o600)
            self.assertEqual(json.loads(record.read_bytes())['generation'], 'a' * 32)
            self.assertTrue(launcher.bootstrap_unchanged(release, digest))

            state['mustChangePassword'] = False
            auth.write_text(json.dumps(state), encoding='utf-8')
            self.assertFalse(launcher.bootstrap_unchanged(release, digest))
            launcher.forget_bootstrap(root)
            self.assertFalse(record.exists())
            self.assertIsNone(launcher.publish_bootstrap(root, release, 'b' * 32, PASSWORD))


if __name__ == '__main__':
    unittest.main()
