import 'dart:convert';

import 'insights_core_js.dart';
import 'insights_plugin_js.dart';
import 'insights_rpc_js.dart';

/// Installs only app-owned files. Does not start/restart OpenCode, install a
/// CLI, change credentials, or overwrite an existing user plugin.
String insightsInstallScript() {
  final payload = base64Encode(
    utf8.encode(
      jsonEncode({
        'index.js': insightsPluginJs,
        'core.js': insightsCoreJs,
        'rpc.js': insightsRpcJs,
        'package.json': jsonEncode({
          'name': 'opencode-plus-mobile-insights',
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
python3 - '$payload' <<'OC_INSIGHTS'
import base64,json,os,pathlib,stat,tempfile,fcntl
root=pathlib.Path('/root/.oc-opencode2/config/opencode/plugins/mobile-insights')
for p in [*reversed(root.parents),root]:
    if not p.exists(): p.mkdir(mode=0o700)
    info=p.lstat()
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode): raise RuntimeError('Unsafe plugin path')
marker=root/'opencode-plus-owned'
if marker.is_symlink(): raise RuntimeError('Unsafe ownership marker')
if any(root.iterdir()) and not marker.is_file(): raise RuntimeError('Existing plugin is not app-owned')
for name,value in json.loads(base64.b64decode(__import__('sys').argv[1])).items():
    target=root/name
    if target.is_symlink(): raise RuntimeError('Unsafe plugin file')
    fd,tmp=tempfile.mkstemp(dir=root,prefix='.plus-')
    try:
        with os.fdopen(fd,'w') as f: f.write(value);f.flush();os.fsync(f.fileno())
        os.replace(tmp,target)
    finally:
        if os.path.exists(tmp): os.unlink(tmp)
marker.write_text('opencode-plus-mobile-insights-v1\\n')
# Explicit package registration; global plugin-directory auto-discovery is
# not assumed. Only the plugin array changes; credentials are never read.
config=root.parent.parent/'opencode.json'
if config.is_symlink(): raise RuntimeError('Unsafe configuration path')
lock=root.parent.parent/'.mobile-insights-install.lock'
fd=os.open(lock,os.O_CREAT|os.O_RDWR|os.O_NOFOLLOW,0o600)
with os.fdopen(fd,'w') as handle:
    fcntl.flock(handle,fcntl.LOCK_EX)
    value=json.loads(config.read_text()) if config.exists() else {}
    if not isinstance(value,dict): raise RuntimeError('Invalid configuration')
    plugins=value.get('plugins',[])
    if not isinstance(plugins,list): raise RuntimeError('Invalid plugin list')
    entry=str(root)
    if entry not in plugins:
        value['plugins']=[*plugins,entry]
        fd,tmp=tempfile.mkstemp(dir=config.parent,prefix='.plus-config-')
        try:
            with os.fdopen(fd,'w') as f: json.dump(value,f);f.flush();os.fsync(f.fileno())
            os.replace(tmp,config)
        finally:
            if os.path.exists(tmp): os.unlink(tmp)
print('installed; reload required')
OC_INSIGHTS
''';
}
