"""CI-only CJK fallback for Flutter's headless screenshot tests.

Android supplies CJK fallback fonts; Linux flutter_test does not. The OFL
font stays in build/ and is never added to app assets or font preferences.
"""
import hashlib
from pathlib import Path
import urllib.request

root = Path('build/qa-fonts')
root.mkdir(parents=True, exist_ok=True)
sources = [
    ('NotoSansSC%5Bwght%5D.ttf', 'NotoSansSC.ttf',
     'fb0637bafbcd804fe32152370a1225990745b4bc', 17772300),
    ('OFL.txt', 'OFL.txt', '1c9f43281b8f216c5461fe9ac729afbade7724e4', 4388),
]
for source, name, sha, size in sources:
    path = root / name
    body = path.read_bytes() if path.exists() else b''
    def valid(data):
        return len(data) == size and hashlib.sha1(
            b'blob ' + str(len(data)).encode() + b'\0' + data).hexdigest() == sha
    if not valid(body):
        url = 'https://raw.githubusercontent.com/google/fonts/main/ofl/notosanssc/' + source
        with urllib.request.urlopen(url, timeout=90) as response:
            body = response.read(size + 1)
        if not valid(body):
            raise RuntimeError('The pinned QA font changed; refusing unverified bytes')
        path.write_bytes(body)
    print('Verified CI-only font resource:', name, size, 'bytes')
