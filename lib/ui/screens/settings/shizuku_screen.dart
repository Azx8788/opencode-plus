import 'dart:async';

import 'package:flutter/material.dart';

import '../../../platform/shizuku.dart';

/// Shizuku status, explicit enablement and a real read-only identity check.
class ShizukuScreen extends StatefulWidget {
  const ShizukuScreen({super.key});

  @override
  State<ShizukuScreen> createState() => _ShizukuScreenState();
}

class _ShizukuScreenState extends State<ShizukuScreen> {
  StreamSubscription<Map<String, Object?>>? _subscription;
  Map<String, Object?> _state = const {};
  String? _diagnostic;
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
      if (mounted) setState(() { _state = value; _error = null; });
    } catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() { _busy = true; _error = null; });
    try { await action(); } catch (error) { if (mounted) setState(() => _error = error); }
    if (mounted) setState(() => _busy = false);
    await _refresh();
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
      _ => text('Unknown', '未知'),
    };
    return Scaffold(
      appBar: AppBar(title: Text(text('Shizuku', 'Shizuku'))),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        _status(text('Shizuku manager installed (Sui may not need it)', 'Shizuku 管理器已安装（Sui 可能无需管理器）'), _state['managerInstalled']),
        _status(text('Service running', '服务正在运行'), _state['binderAlive']),
        _status(text('Safety overlay allowed', '已允许安全警告悬浮窗'), _state['overlayAllowed']),
        ListTile(title: Text(text('Provider', '权限提供方')), subtitle: Text('${_state['provider'] ?? 'unknown'}')),
        _status(text('Permission granted', '已获得授权'), _state['permission'] == 'granted'),
        ListTile(title: Text(text('Execution identity', '执行身份')), subtitle: Text('$backend${uid == null ? '' : ' · UID $uid'}')),
        ListTile(title: Text(text('UserService', '用户服务')), subtitle: Text('${_state['binding'] ?? text('disconnected', '未连接')}')),
        SwitchListTile(
          title: Text(text('Enable Shizuku commands', '启用 Shizuku 命令')),
          subtitle: Text(text('Separate from Shizuku permission.', '与 Shizuku 系统授权分开控制。')),
          value: _state['enabled'] == true,
          onChanged: _busy ? null : (value) => _run(() async { _update(await ShizukuPlatform.setEnabled(value)); }),
        ),
        const Divider(),
        Wrap(spacing: 8, runSpacing: 8, children: [
          OutlinedButton(onPressed: _busy ? null : () => _run(ShizukuPlatform.requestPermission), child: Text(text('Request permission', '申请授权'))),
          OutlinedButton(onPressed: _busy ? null : () => _run(() async { await ShizukuPlatform.openManager(); }), child: Text(text('Open manager / setup', '打开管理器 / 安装说明'))),
          OutlinedButton(onPressed: _busy ? null : _refresh, child: Text(text('Refresh', '刷新'))),
          OutlinedButton(onPressed: _busy ? null : () => _run(ShizukuPlatform.overlaySettings), child: Text(text('Allow safety overlay', '授权安全警告悬浮窗'))),
          FilledButton(onPressed: _busy || _state['enabled'] != true ? null : () => _run(() async {
            final id = 'shz-${DateTime.now().microsecondsSinceEpoch}';
            setState(() => _activeOperationId = id);
            try {
              final value = await ShizukuPlatform.diagnostic(id);
              if (mounted) setState(() => _diagnostic = '${value['stdout'] ?? ''}${value['stderr'] ?? ''}\n${text('Exit code', '退出码')}: ${value['exitCode']}');
            } finally {
              if (mounted) setState(() => _activeOperationId = null);
            }
          }), child: Text(text('Run read-only check', '运行只读诊断'))),
          if (_activeOperationId != null) OutlinedButton(
            onPressed: () => ShizukuPlatform.cancel(_activeOperationId!),
            child: Text(text('Stop check', '停止诊断')),
          ),
        ]),
        if (_error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text('$_error', style: TextStyle(color: Theme.of(context).colorScheme.error))),
        if (_diagnostic != null) Card(margin: const EdgeInsets.only(top: 16), child: Padding(padding: const EdgeInsets.all(12), child: SelectableText(_diagnostic!))),
        Padding(padding: const EdgeInsets.only(top: 16), child: Text(text('Shizuku must be started by its manager. Enabling this feature does not grant system permission.', 'Shizuku 需要由管理器启动。启用此功能不会自动获得系统授权。'), style: Theme.of(context).textTheme.bodySmall)),
      ]),
    );
  }

  Widget _status(String title, Object? value) => ListTile(
    title: Text(title),
    trailing: Text(value == true ? text('Yes', '是') : value == false ? text('No', '否') : text('Unknown', '未知')),
  );
}
