import 'dart:async';

import 'package:flutter/material.dart';

import '../../../platform/shizuku.dart';

/// Shizuku status, explicit enablement and real command checks.
///
/// [ShizukuPlatform.execute] and [ShizukuPlatform.diagnostic] only return after
/// the Android safety overlay was accepted. This screen never bypasses it.
class ShizukuScreen extends StatefulWidget {
  const ShizukuScreen({super.key});

  @override
  State<ShizukuScreen> createState() => _ShizukuScreenState();
}

class _ShizukuScreenState extends State<ShizukuScreen> {
  StreamSubscription<Map<String, Object?>>? _subscription;
  Map<String, Object?> _state = const {};
  Map<String, Object?>? _result;
  Object? _error;
  bool _busy = false;
  String? _activeOperationId;

  bool get _zh => Localizations.localeOf(context).languageCode == 'zh';
  String text(String en, String zh) => _zh ? zh : en;

  @override
  void initState() {
    super.initState();
    _subscription = ShizukuPlatform.changes.listen(_update);
    _refresh();
  }

  void _update(Map<String, Object?> value) {
    if (mounted) setState(() => _state = value);
  }

  Future<void> _refresh() async {
    try {
      final value = await ShizukuPlatform.status();
      if (mounted) {
        setState(() {
          _state = value;
          _error = null;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => _error = error);
    }
    if (mounted) setState(() => _busy = false);
    await _refresh();
  }

  Future<void> _execute(String command, {required String prefix}) async {
    final id = '$prefix-${DateTime.now().microsecondsSinceEpoch}';
    setState(() {
      _activeOperationId = id;
      _result = null;
    });
    try {
      final value = await ShizukuPlatform.execute(
        operationId: id,
        command: command,
        timeout: const Duration(seconds: 30),
      );
      if (mounted) setState(() => _result = value);
    } finally {
      if (mounted) setState(() => _activeOperationId = null);
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final uid = _state['uid'];
    final backend = switch (_state['backend']) {
      'root' => 'ROOT (UID 0)',
      'adb' => 'ADB (UID 2000)',
      'unsupported' => text('Unsupported identity', '不支持的身份'),
      _ => text('Unknown', '未知'),
    };
    final permission = switch (_state['permission']) {
      'granted' => text('Granted', '已授权'),
      'denied' => text('Denied', '已拒绝'),
      'requestable' => text('Not requested', '未申请'),
      _ => text('Unknown', '未知'),
    };
    final ready = _state['enabled'] == true &&
        _state['overlayAllowed'] == true &&
        _state['binding'] == 'connected';
    return Scaffold(
      appBar: AppBar(title: Text(text('Shizuku', 'Shizuku'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _status(
            text('Shizuku manager installed (Sui may not need it)',
                'Shizuku 管理器已安装（Sui 可能无需管理器）'),
            _state['managerInstalled'],
          ),
          _status(text('Service running', '服务正在运行'), _state['binderAlive']),
          _status(text('Safety overlay allowed', '已允许安全警告悬浮窗'),
              _state['overlayAllowed']),
          ListTile(
            title: Text(text('Provider', '权限提供方')),
            subtitle: Text('${_state['provider'] ?? 'unknown'}'),
          ),
          ListTile(
            title: Text(text('Permission', '授权')),
            subtitle: Text(permission),
          ),
          ListTile(
            title: Text(text('Execution identity', '执行身份')),
            subtitle: Text('$backend${uid == null ? '' : ' · UID $uid'}'),
          ),
          ListTile(
            title: Text(text('UserService', '用户服务')),
            subtitle: Text(
              '${_state['binding'] ?? text('disconnected', '未连接')}',
            ),
          ),
          SwitchListTile(
            title: Text(text('Enable Shizuku commands', '启用 Shizuku 命令')),
            subtitle: Text(
              text(
                'Separate from Shizuku permission and from the safety overlay.',
                '与 Shizuku 系统授权、悬浮窗授权分开控制。',
              ),
            ),
            value: _state['enabled'] == true,
            onChanged: _busy
                ? null
                : (value) => _run(() async {
                      _update(await ShizukuPlatform.setEnabled(value));
                    }),
          ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              text(
                'Every command opens a forced system overlay: risk colour, full '
                'command text, and a 10-second wait before “Allow once” becomes '
                'tappable. A 30-second timeout, denial, or a missing overlay '
                'permission means the command does not run.',
                '每条命令都会强制弹出系统悬浮窗：风险底色、完整命令文本，'
                '并且“仅允许本次”需要等待 10 秒才可点击。30 秒超时、拒绝或缺少悬浮窗权限，'
                '都表示命令不会执行。',
              ),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton(
                onPressed: _busy
                    ? null
                    : () => _run(ShizukuPlatform.requestPermission),
                child: Text(text('Request permission', '申请授权')),
              ),
              OutlinedButton(
                onPressed: _busy
                    ? null
                    : () => _run(() async {
                          await ShizukuPlatform.openManager();
                        }),
                child: Text(text('Open manager / setup', '打开管理器 / 安装说明')),
              ),
              OutlinedButton(
                onPressed: _busy ? null : () => _run(ShizukuPlatform.overlaySettings),
                child: Text(
                  text('Allow safety overlay', '授权安全警告悬浮窗'),
                ),
              ),
              OutlinedButton(
                onPressed: _busy ? null : _refresh,
                child: Text(text('Refresh', '刷新')),
              ),
              FilledButton(
                onPressed: _busy || !ready
                    ? null
                    : () => _run(() => _execute(
                          'id; getprop ro.build.version.release',
                          prefix: 'shz-diag',
                        )),
                child: Text(text('Run read-only check', '运行只读诊断')),
              ),
              OutlinedButton(
                onPressed: _busy || !ready
                    ? null
                    : () => _run(() => _execute('sleep 10', prefix: 'shz-wait')),
                child: Text(text('Run 10s cancellation test', '运行 10 秒取消测试')),
              ),
              if (_activeOperationId != null)
                OutlinedButton(
                  onPressed: () =>
                      ShizukuPlatform.cancel(_activeOperationId!),
                  child: Text(text('Stop current command', '停止当前命令')),
                ),
            ],
          ),
          if (!ready && _state['enabled'] == true)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                text(
                  'Commands stay unavailable until Shizuku is running, '
                  'permission is granted, the overlay is allowed and the '
                  'UserService is connected.',
                  '在 Shizuku 运行、获得授权、允许悬浮窗并连接用户服务之前，命令保持不可用。',
                ),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                '$_error',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          if (_result != null) _resultCard(context, _result!),
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Text(
              text(
                'Shizuku must be started by its manager. Enabling this feature '
                'does not grant system permission, and no command bypasses the '
                'safety overlay.',
                'Shizuku 需要由管理器启动。启用此功能不会自动获得系统授权，'
                '任何命令都不会绕过安全悬浮窗。',
              ),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }

  Widget _resultCard(BuildContext context, Map<String, Object?> value) {
    final state = '${value['state'] ?? 'unknown'}';
    final lines = <String>[
      '${text('State', '状态')}: $state',
      if (value['reason'] != null) '${text('Reason', '原因')}: ${value['reason']}',
      '${text('Exit code', '退出码')}: ${value['exitCode']}',
      '${text('Elapsed', '耗时')}: ${value['elapsedMs']} ms',
      if (value['truncated'] == true)
        text('Output truncated.', '输出已截断。'),
    ];
    final stdout = '${value['stdout'] ?? ''}';
    final stderr = '${value['stderr'] ?? ''}';
    return Card(
      margin: const EdgeInsets.only(top: 16),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(lines.join('\n')),
            if (stdout.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: SelectableText(stdout),
              ),
            if (stderr.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: SelectableText(
                  stderr,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _status(String title, Object? value) => ListTile(
        title: Text(title),
        trailing: Text(
          value == true
              ? text('Yes', '是')
              : value == false
                  ? text('No', '否')
                  : text('Unknown', '未知'),
        ),
      );
}