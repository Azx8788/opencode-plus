import 'dart:async';

import 'package:flutter/material.dart';

import '../../../platform/shizuku.dart';

/// Shizuku status, explicit enablement, command checks and policy controls.
///
/// The Android side enforces every setting again: this screen only edits
/// bounded values and never gets an execution code path of its own.
class ShizukuScreen extends StatefulWidget {
  const ShizukuScreen({super.key});

  @override
  State<ShizukuScreen> createState() => _ShizukuScreenState();
}

class _ShizukuScreenState extends State<ShizukuScreen> {
  StreamSubscription<Map<String, Object?>>? _subscription;
  Map<String, Object?> _state = const {};
  Map<String, Object?> _settings = const {};
  Map<String, Object?>? _result;
  Object? _error;
  bool _busy = false;
  bool _saving = false;
  bool _settingsLoaded = false;
  bool _cancelling = false;
  bool _cancelRequested = false;
  String? _activeOperationId;

  bool get _zh => Localizations.localeOf(context).languageCode == 'zh';
  String text(String en, String zh) => _zh ? zh : en;
  bool get _canEditSettings => _settingsLoaded && !_saving && !_busy;

  @override
  void initState() {
    super.initState();
    _subscription = ShizukuPlatform.changes.listen(
      _update,
      onError: (Object error) {
        if (mounted) setState(() => _error = error);
      },
    );
    _refresh();
    _loadSettings();
  }

  void _update(Map<String, Object?> value) {
    if (mounted) setState(() => _state = value);
  }

  Future<void> _loadSettings() async {
    try {
      final value = await ShizukuPlatform.settings();
      if (value.isEmpty) {
        throw const FormatException('Shizuku settings unavailable');
      }
      if (mounted) {
        setState(() {
          _settings = Map<String, Object?>.from(value);
          _settingsLoaded = true;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _settingsLoaded = false;
          _error = error;
        });
      }
    }
  }

  int _getInt(String key, int fallback) {
    final raw = _settings[key];
    if (raw is int) return raw;
    if (raw is String) return int.tryParse(raw) ?? fallback;
    return fallback;
  }

  Future<void> _save(Map<String, Object?> updates) async {
    if (!_canEditSettings) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final overlayTimeout =
          ((updates['overlay_timeout_seconds'] as int?) ??
                  _getInt('overlay_timeout_seconds', 30))
              .clamp(10, 120)
              .toInt();
      final allowDelay =
          ((updates['allow_delay_seconds'] as int?) ??
                  _getInt('allow_delay_seconds', 10))
              .clamp(0, overlayTimeout - 1)
              .toInt();
      final value = await ShizukuPlatform.saveSettings(
        directReadOnly:
            (updates['direct_read_only'] as bool?) ??
            (_settings['direct_read_only'] as bool?) ??
            true,
        advancedMode:
            (updates['advanced_mode'] as bool?) ??
            (_settings['advanced_mode'] as bool?) ??
            false,
        allowDelaySeconds: allowDelay,
        overlayTimeoutSeconds: overlayTimeout,
        commandTimeoutSeconds:
            (updates['command_timeout_seconds'] as int?) ??
            _getInt('command_timeout_seconds', 30),
        maxOutputKiB:
            (updates['max_output_kib'] as int?) ??
            _getInt('max_output_kib', 64),
      );
      if (mounted) setState(() => _settings = value);
    } catch (error) {
      if (mounted) setState(() => _error = error);
      await _loadSettings();
    }
    if (mounted) setState(() => _saving = false);
  }

  Future<void> _toggleAdvanced(bool value) async {
    if (!value) {
      await _save({'advanced_mode': false});
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(text('I am an advanced user', '我是高级用户')),
        content: Text(
          text(
            'YELLOW, BLUE and GREEN commands will run automatically without an '
                'overlay. RED commands still open the warning overlay, with a fixed '
                '3-second wait before “Allow once”. Timeout still denies.',
            '开启后，黄色、蓝色和绿色等级的命令将不再弹窗，直接自动执行。'
                '红色命令仍会弹出警告悬浮窗，“仅允许本次”固定等待 3 秒。超时仍然拒绝。',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(text('Cancel', '取消')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(text('Enable', '开启')),
          ),
        ],
      ),
    );
    if (mounted && confirmed == true) await _save({'advanced_mode': true});
  }

  Future<void> _refresh() async {
    try {
      final value = await ShizukuPlatform.status();
      if (mounted) {
        setState(() {
          _state = value;
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
      _cancelRequested = false;
    });
    try {
      final value = await ShizukuPlatform.execute(
        operationId: id,
        command: command,
        timeout: Duration(seconds: _getInt('command_timeout_seconds', 30)),
      );
      if (mounted) setState(() => _result = value);
    } finally {
      if (mounted) setState(() => _activeOperationId = null);
    }
  }

  Future<void> _cancel() async {
    final id = _activeOperationId;
    if (id == null || _cancelling) return;
    setState(() => _cancelling = true);
    try {
      await ShizukuPlatform.cancel(id);
      if (mounted) setState(() => _cancelRequested = true);
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _cancelling = false);
    }
  }

  String _bindingExplanation(String reason) => switch (reason) {
    'bind_timeout' => text(
      'No UserService callback arrived. Check whether Shizuku offers to restart an older running server; some ROMs cannot initialize UserService. Authorization alone is not execution readiness.',
      '用户服务没有返回连接回调。请检查 Shizuku 是否提示重启旧服务；部分 ROM 无法初始化用户服务。已授权不代表已经能执行。',
    ),
    'handshake_timeout' || 'handshake_failed' => text(
      'The Binder arrived, but execution identity and protocol could not be verified. No command was started.',
      '已收到 Binder，但未能确认执行身份和协议。没有启动命令。',
    ),
    _ => text(
      'UserService connection failed: $reason. Refresh or reconnect; no fallback is used.',
      '用户服务连接失败：$reason。可刷新或重新连接，不会切换执行后端。',
    ),
  };

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
    final overlayTimeout = _getInt(
      'overlay_timeout_seconds',
      30,
    ).clamp(10, 120).toInt();
    final allowDelay = _getInt(
      'allow_delay_seconds',
      10,
    ).clamp(0, overlayTimeout - 1).toInt();
    final minOverlayTimeout = (allowDelay + 1).clamp(10, 120).toInt();
    final overlayAllowed = _state['overlayAllowed'] == true;
    final readOnlyDirect = _settings['direct_read_only'] != false;
    final advanced = _settings['advanced_mode'] == true;
    final ready =
        _settingsLoaded &&
        _state['enabled'] == true &&
        _state['executionReady'] == true &&
        _state['operationStorageReady'] != false &&
        _state['binding'] == 'connected' &&
        (overlayAllowed || readOnlyDirect || advanced);
    return Scaffold(
      appBar: AppBar(title: Text(text('Shizuku', 'Shizuku'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _status(
            text(
              'Shizuku manager installed (Sui may not need it)',
              'Shizuku 管理器已安装（Sui 可能无需管理器）',
            ),
            _state['managerInstalled'],
          ),
          _status(text('Service running', '服务正在运行'), _state['binderAlive']),
          _status(
            text('Safety overlay allowed', '已允许安全警告悬浮窗'),
            _state['overlayAllowed'],
          ),
          ListTile(
            title: Text(text('Provider', '权限提供方')),
            subtitle: Text('${_state['provider'] ?? 'unknown'}'),
          ),
          ListTile(
            title: Text(text('Permission', '授权')),
            subtitle: Text(permission),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: FilledButton(
                key: const ValueKey('shizuku-request-permission'),
                onPressed:
                    _busy || _state['permissionRequestState'] == 'requesting'
                    ? null
                    : () => _run(ShizukuPlatform.requestPermission),
                child: Text(
                  text('Request Shizuku authorization', '申请 Shizuku 授权'),
                ),
              ),
            ),
          ),
          if (_state['permissionRequestState'] == 'requesting')
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                text(
                  'Authorization requested. Waiting for Shizuku to return your decision.',
                  '已发起授权申请，等待 Shizuku 返回你的选择。',
                ),
              ),
            ),
          if (_state['permissionRequestReason'] != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                text(
                  'Authorization request status: ${_state['permissionRequestReason']}. No permission has been inferred.',
                  '授权申请状态：${_state['permissionRequestReason']}。不会据此推断已获授权。',
                ),
              ),
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
          ListTile(
            title: Text(text('Running server API', '运行中的服务 API')),
            subtitle: Text(
              '${_state['serverVersion'] ?? text('Unknown', '未知')}',
            ),
          ),
          _status(
            text(
              'AI → Android bridge (built-in server)',
              'AI → Android 通道（内置服务器）',
            ),
            _state['aiBridgeReady'],
          ),
          if (_state['bindingReason'] != null)
            Padding(
              key: const ValueKey('shizuku-binding-reason'),
              padding: const EdgeInsets.all(12),
              child: Text(
                _bindingExplanation('${_state['bindingReason']}'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          if (_state['operationStorageReady'] == false)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                text(
                  'Operation records are unreadable. Execution is disabled; existing data has not been overwritten.',
                  '操作记录无法读取，已禁止执行；原有数据未被覆盖。',
                ),
              ),
            ),
          SwitchListTile(
            title: Text(text('Enable Shizuku commands', '启用 Shizuku 命令')),
            subtitle: Text(
              text(
                'Turning this on requests Shizuku authorization. The command switch and safety overlay permission remain separate.',
                '开启时立即申请 Shizuku 授权；命令开关和悬浮窗权限仍分别控制。',
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
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              text('Command policy', '命令策略'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          SwitchListTile(
            key: const ValueKey('shizuku-advanced'),
            title: Text(text('I am an advanced user', '我是高级用户')),
            value: _settings['advanced_mode'] == true,
            onChanged: _canEditSettings ? _toggleAdvanced : null,
            subtitle: Text(
              text(
                'YELLOW, BLUE and GREEN run automatically; RED still opens the '
                    'overlay with a 3-second wait. Unverified scripts and sensitive reads are RED.',
                '黄、蓝、绿等级自动执行；红色仍弹窗并等待 3 秒。未验证的脚本和敏感读取属于红色。',
              ),
            ),
          ),
          SwitchListTile(
            key: const ValueKey('shizuku-direct-read'),
            title: Text(text('Read-only commands run directly', '只读命令直接执行')),
            value: _settings['direct_read_only'] != false,
            onChanged: !_canEditSettings
                ? null
                : (value) => _save({'direct_read_only': value}),
            subtitle: Text(
              text(
                'Only a narrow, checked read-only grammar runs without an '
                    'overlay: single commands, no pipes, redirects or operators.',
                '只有经过校验的窄只读语法可以不弹窗：单条命令，不含管道、重定向和操作符。',
              ),
            ),
          ),
          ListTile(
            title: Text(text('Overlay allow delay (seconds)', '弹窗允许等待（秒）')),
            subtitle: Slider(
              value: allowDelay.toDouble(),
              min: 0,
              max: (overlayTimeout - 1).clamp(0, 60).toDouble(),
              divisions: (overlayTimeout - 1).clamp(1, 60).toInt(),
              label: '$allowDelay s',
              onChanged: !_canEditSettings
                  ? null
                  : (value) => setState(
                      () => _settings['allow_delay_seconds'] = value.round(),
                    ),
              onChangeEnd: (_) => _save(const {}),
            ),
          ),
          ListTile(
            title: Text(text('Overlay timeout (seconds)', '弹窗超时自动拒绝（秒）')),
            subtitle: Slider(
              value: overlayTimeout.toDouble(),
              min: minOverlayTimeout.toDouble(),
              max: 120,
              divisions: (120 - minOverlayTimeout).clamp(1, 110).toInt(),
              label: '$overlayTimeout s',
              onChanged: !_canEditSettings
                  ? null
                  : (value) => setState(
                      () =>
                          _settings['overlay_timeout_seconds'] = value.round(),
                    ),
              onChangeEnd: (_) => _save(const {}),
            ),
          ),
          ListTile(
            title: Text(text('Command timeout (seconds)', '命令执行超时（秒）')),
            subtitle: Slider(
              value: _getInt('command_timeout_seconds', 30).toDouble(),
              min: 1,
              max: 120,
              divisions: 119,
              label: '${_getInt('command_timeout_seconds', 30)} s',
              onChanged: !_canEditSettings
                  ? null
                  : (value) => setState(
                      () =>
                          _settings['command_timeout_seconds'] = value.round(),
                    ),
              onChangeEnd: (_) => _save(const {}),
            ),
          ),
          ListTile(
            title: Text(text('Output limit (KiB)', '输出上限（KiB）')),
            subtitle: Slider(
              value: _getInt('max_output_kib', 64).toDouble(),
              min: 4,
              max: 256,
              divisions: 63,
              label: '${_getInt('max_output_kib', 64)} KiB',
              onChanged: !_canEditSettings
                  ? null
                  : (value) => setState(
                      () => _settings['max_output_kib'] = value.round(),
                    ),
              onChangeEnd: (_) => _save(const {}),
            ),
          ),
          const Divider(),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton(
                key: const ValueKey('shizuku-reconnect'),
                onPressed: _busy ? null : () => _run(ShizukuPlatform.reconnect),
                child: Text(text('Reconnect UserService', '重新连接用户服务')),
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
                onPressed: _busy
                    ? null
                    : () => _run(ShizukuPlatform.overlaySettings),
                child: Text(text('Allow safety overlay', '授权安全警告悬浮窗')),
              ),
              OutlinedButton(
                onPressed: _busy
                    ? null
                    : () => _run(() async {
                        await _refresh();
                        await _loadSettings();
                      }),
                child: Text(text('Refresh', '刷新')),
              ),
              FilledButton(
                key: const ValueKey('shizuku-diagnostic'),
                onPressed: _busy || !ready
                    ? null
                    : () => _run(
                        () => _execute(
                          'id; getprop ro.build.version.release',
                          prefix: 'shz-diag',
                        ),
                      ),
                child: Text(text('Run read-only check', '运行只读诊断')),
              ),
              OutlinedButton(
                onPressed: _busy || !ready
                    ? null
                    : () =>
                          _run(() => _execute('sleep 10', prefix: 'shz-wait')),
                child: Text(text('Run 10s cancellation test', '运行 10 秒取消测试')),
              ),
              if (_activeOperationId != null)
                OutlinedButton(
                  onPressed: _cancelling ? null : _cancel,
                  child: Text(text('Stop current command', '停止当前命令')),
                ),
            ],
          ),
          if (_cancelRequested && _activeOperationId != null)
            Text(
              text(
                'Stop requested. Wait for the actual termination result; side effects are not undone.',
                '已请求停止，请等待实际终止结果；已经产生的副作用不会回滚。',
              ),
            ),
          if (!overlayAllowed &&
              _state['enabled'] == true &&
              !readOnlyDirect &&
              !advanced)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                text(
                  'Shizuku is not ready yet. Start it, grant app permission and '
                      'connect the UserService. Non-read-only commands also require '
                      'the system overlay permission.',
                  'Shizuku 尚未就绪。请启动服务、授予应用权限并连接用户服务。'
                      '非只读命令还需要系统悬浮窗权限。',
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
                    'does not grant system permission. Direct execution covers only '
                    'the checked read-only grammar (and, in advanced mode, commands '
                    'up to YELLOW risk); RED commands always ask first.',
                'Shizuku 需要由管理器启动。启用此功能不会自动获得系统授权。'
                    '直接执行仅覆盖已校验的只读语法（高级模式下扩大到黄色风险等级）；'
                    '红色命令始终先询问。',
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
      if (value['reason'] != null)
        '${text('Reason', '原因')}: ${value['reason']}',
      if (value['uid'] != null)
        '${text('Android UID', 'Android UID')}: ${value['uid']}',
      if (value['exitCode'] != null)
        '${text('Exit code', '退出码')}: ${value['exitCode']}',
      if (value['elapsedMs'] != null)
        '${text('Elapsed', '耗时')}: ${value['elapsedMs']} ms',
      if (value['termination'] != null)
        '${text('Termination', '终止确认')}: ${value['termination']}',
      if (state == 'unknown')
        text(
          'Execution result is unconfirmed. Do not automatically retry.',
          '执行结果尚未确认，不要自动重试。',
        ),
      if (value['truncated'] == true) text('Output truncated.', '输出已截断。'),
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
