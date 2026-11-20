import 'dart:convert';

import 'shizuku_bridge_js.dart';
import 'shizuku_plugin_js.dart';

/// Installs the app-owned V2 tool adapter in the built-in runtime only.
/// Feature enablement and Android authorization remain native, explicit controls.
String shizukuInstallScript() {
  final payload = base64Encode(
    utf8.encode(
      jsonEncode({
        'index.js': shizukuPluginJs,
        'bridge.js': shizukuBridgeJs,
        'package.json': jsonEncode({
          'name': 'opencode-plus-mobile-shizuku',
          'version': '1.0.0',
          'type': 'module',
          'exports': {'.': './index.js'},
          'dependencies': {'@opencode/plugin': '2.1.1'},
        }),
      }),
    ),
  );
  return '''
set -eu
umask 077
python3 - '$payload' <<'OC_SHIZUKU'
import base64,json,os,pathlib,stat,tempfile,fcntl,sys
root=pathlib.Path('/root/.oc-opencode2/config/opencode/plugins/mobile-shizuku')
for p in [*reversed(root.parents),root]:
    if not p.exists(): p.mkdir(mode=0o700)
    info=p.lstat()
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode): raise RuntimeError('Unsafe plugin path')
marker=root/'opencode-plus-owned'
if marker.is_symlink(): raise RuntimeError('Unsafe ownership marker')
if any(root.iterdir()) and (not marker.is_file() or marker.read_text() != 'opencode-plus-mobile-shizuku-v1\\n'):
    raise RuntimeError('Existing plugin is not app-owned')
def atomic(target,text):
    if target.is_symlink(): raise RuntimeError('Unsafe app-owned file')
    fd,tmp=tempfile.mkstemp(dir=target.parent,prefix='.plus-shizuku-')
    try:
        with os.fdopen(fd,'w') as f: f.write(text);f.flush();os.fsync(f.fileno())
        os.replace(tmp,target)
    finally:
        if os.path.exists(tmp): os.unlink(tmp)
for name,text in json.loads(base64.b64decode(sys.argv[1])).items(): atomic(root/name,text)
atomic(marker,'opencode-plus-mobile-shizuku-v1\\n')
config=root.parent.parent/'opencode.json'
if config.is_symlink(): raise RuntimeError('Unsafe configuration path')
# Serialize with the existing insights installer as well as another bridge install.
fd=os.open(root.parent.parent/'.mobile-insights-install.lock',os.O_CREAT|os.O_RDWR|os.O_NOFOLLOW,0o600)
with os.fdopen(fd,'w') as handle:
    fcntl.flock(handle,fcntl.LOCK_EX)
    value=json.loads(config.read_text()) if config.exists() else {}
    if not isinstance(value,dict): raise RuntimeError('Invalid configuration')
    plugins=value.get('plugins',[])
    if not isinstance(plugins,list): raise RuntimeError('Invalid plugin list')
    entry=str(root)
    if not any(p==entry or isinstance(p,dict) and p.get('package')==entry for p in plugins):
        value['plugins']=[*plugins,entry]
        atomic(config,json.dumps(value))
print('Android tool adapter installed; native authorization is unchanged')
OC_SHIZUKU
''';
}
