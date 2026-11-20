import 'dart:async';

import 'package:flutter/material.dart';

import '../../../platform/shizuku.dart';

/// Shizuku status and controls.
///
/// Every fact is shown separately and with the reason behind it: the manager,
/// this package's listing conditions, the binder, the authorization and its
/// evidence, the request, the execution identity, the UserService, the
/// operation store, the AI bridge and the overlay. "Ready" is only shown when
/// the native side admits execution; this screen never infers it.
class ShizukuScreen extends StatefulWidget {
  const ShizukuScreen({super.key});

  @override
  State<ShizukuScreen> createState() => _ShizukuScreenState();
}

class _ShizukuScreenState extends State<ShizukuScreen> {
  StreamSubscription<ShizukuSnapshot>? _subscription;
  ShizukuSnapshot? _snapshot;
  ShizukuPolicy? _policy;
  Map<String, Object?>? _result;
  Object? _error;
  bool _busy = false;
  bool _saving = false;
  bool _cancelling = false;
  bool _cancelRequested = false;
  String? _activeOperationId;

  bool get _zh => Localizations.localeOf(context).languageCode == 'zh';
  String text(String en, String zh) => _zh ? zh : en;
  bool get _canEditPolicy => _policy != null && !_saving && !_busy;

  @override
  void initState() {
    super.initState();
    _subscription = ShizukuPlatform.changes.listen(
      (value) {
        if (mounted) setState(() => _snapshot = value);
      },
      onError: (Object error) {
        if (mounted) setState(() => _error = error);
      },
    );
    _refresh();
    _loadPolicy();
  }

  Future<void> _loadPolicy() async {
    try {
      final value = await ShizukuPlatform.readPolicy();
      if (mounted) setState(() => _policy = value);
    } catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  Future<void> _refresh() async {
    try {
      final value = await ShizukuPlatform.snapshot();
      if (mounted) setState(() => _snapshot = value);
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

  Future<void> _save(ShizukuPolicy policy) async {
    if (!_canEditPolicy) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final value = await ShizukuPlatform.writePolicy(policy);
      if (mounted) setState(() => _policy = value);
    } catch (error) {
      if (mounted) setState(() => _error = error);
      await _loadPolicy();
    }
    if (mounted) setState(() => _saving = false);
  }

  Future<void> _toggleAdvanced(bool value) async {
    final policy = _policy;
    if (policy == null) return;
    if (!value) {
      await _save(policy.copyWith(advancedMode: false));
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(text('I am an advanced user', '我是高级用户')),
        content: Text(
          text(
            'YELLOW, BLUE and GREEN commands run without an overlay. RED '
                'commands still open the warning overlay with a fixed 3-second '
                'wait before “Allow once”. A timeout still denies.',
            '开启后，黄色、蓝色和绿色等级的命令不再弹窗，直接自动执行。'
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
    if (mounted && confirmed == true) {
      await _save(policy.copyWith(advancedMode: true));
    }
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
        timeout: Duration(seconds: _policy?.commandTimeoutSeconds ?? 30),
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

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  // ------------------------------------------------------------- explanations

  String _blockedExplanation(String? reason) => switch (reason) {
    'feature_disabled' => text(
      'The command switch is off. Nothing is requested or executed.',
      '命令开关未开启，不会申请授权也不会执行。',
    ),
    'shizuku_not_running' => text(
      'No Shizuku Binder was received. Start Shizuku from its manager (or '
          'start Sui), then return here. Starting it needs adb or root; this '
          'app cannot and will not start it for you.',
      '没有收到 Shizuku 的 Binder。请先从管理器启动 Shizuku（或启动 Sui）再回到这里。'
          '启动它需要 adb 或 root，本应用不会也无法代你启动。',
    ),
    'shizuku_binder_dead' => text(
      'The Shizuku server died. Restart it and reopen this app.',
      'Shizuku 服务已断开。请重新启动服务并重新打开本应用。',
    ),
    'app_not_listed' => text(
      "This installed package does not meet the conditions Shizuku uses to "
          'build its app list: it must request moe.shizuku.manager.permission.'
          'API_V23, declare moe.shizuku.client.V3_SUPPORT=true and register the '
          'app-scoped ShizukuProvider. Check the three rows above.',
      '当前安装包不满足 Shizuku 生成应用列表的条件：必须申请 '
          'moe.shizuku.manager.permission.API_V23、声明 '
          'moe.shizuku.client.V3_SUPPORT=true，并注册应用专属的 ShizukuProvider。'
          '请对照上方三行检查。',
    ),
    'authorization_pending' => text(
      'A request is waiting for an answer. Check the Shizuku manager: if no '
          'dialog is visible, open the manager and answer it there.',
      '授权申请正在等待你的选择。请查看 Shizuku 管理器；若没有弹窗，请打开管理器处理。',
    ),
    'authorization_unknown' => text(
      'The server did not give a usable answer, so this app does not treat '
          'you as authorized and will not execute. The reason is shown above.',
      '服务端没有给出可用答复，因此不会视为已授权，也不会执行。原因见上方。',
    ),
    'authorization_denied' => text(
      'The server reports this app is not allowed. Request authorization '
          'again, or allow it in the Shizuku manager list.',
      '服务端表示本应用未被允许。可重新申请授权，或在 Shizuku 管理器列表中允许。',
    ),
    'identity_unsupported' => text(
      'The execution identity is not root (0) or shell (2000), or the server '
          'API is older than 13. UserService execution needs API 13 or newer.',
      '执行身份不是 root(0) 或 shell(2000)，或服务端 API 低于 13。'
          '用户服务执行需要 API 13 及以上。',
    ),
    'operation_storage_unavailable' => text(
      'Operation records cannot be read, so execution is disabled. Existing '
          'records were not overwritten.',
      '操作记录无法读取，已禁止执行；原有记录未被覆盖。',
    ),
    'user_service_not_ready' => text(
      'The UserService is not connected and handshaken. Use “Connect '
          'UserService” and read the reason below if it fails.',
      '用户服务尚未连接并通过握手。请点“连接用户服务”；失败原因见下方。',
    ),
    _ => text('Ready.', '已就绪。'),
  };

  String _authorizationReason(String? reason) => switch (reason) {
    'client_not_attached' => text(
      'This process has no Shizuku client record yet, so the server cannot '
          'answer. Bring the app to the foreground or restart Shizuku; the '
          'answer is not “denied”.',
      '本进程尚未在 Shizuku 服务端登记，服务端无法答复。请把应用切到前台或重启 Shizuku；'
          '这不等于“已拒绝”。',
    ),
    'binder_absent' => text(
      'No Binder yet, so authorization could not be checked.',
      '尚未收到 Binder，无法检查授权。',
    ),
    'binder_dead' => text(
      'The Binder died, so authorization could not be checked.',
      'Binder 已断开，无法检查授权。',
    ),
    'server_too_old' => text(
      'This Shizuku server is older than API 11 and has no app authorization.',
      '当前 Shizuku 服务低于 API 11，不支持应用授权。',
    ),
    'server_newer_than_sdk' => text(
      'The running server is newer than the pinned SDK, so this build does '
          'not guess its answer.',
      '运行中的服务端比固定的 SDK 更新，本版本不会猜测其结果。',
    ),
    'server_version_unknown' => text(
      'The server version could not be read.',
      '无法读取服务端版本。',
    ),
    'server_unreachable' || 'query_rejected' => text(
      'The permission query failed. No authorization is assumed.',
      '权限查询失败，不会推断为已授权。',
    ),
    _ => text('No reason reported.', '没有报告原因。'),
  };

  String _requestReason(String? reason) => switch (reason) {
    'permission_denied' => text(
      'Shizuku returned a denial. You can request again.',
      'Shizuku 返回了拒绝，可以再次申请。',
    ),
    'callback_missing' => text(
      'No decision came back and the server does not report a grant. This is '
          'not a denial: open the manager, check that this app is listed and '
          'that a dialog is waiting, then request again.',
      '没有收到你的选择，服务端也没有报告已授权。这不是拒绝：请打开管理器确认本应用在列表中、'
          '是否有待处理的弹窗，然后重新申请。',
    ),
    'client_not_attached' => text(
      'The server does not know this process, so the request never reached a '
          'dialog. Reopen the app (or restart Shizuku) and try again.',
      '服务端不认识本进程，申请没有到达任何弹窗。请重新打开应用（或重启 Shizuku）后重试。',
    ),
    'permission_request_failed' => text(
      'The request could not be handed to Shizuku. No permission was granted.',
      '申请未能送达 Shizuku，未获得任何授权。',
    ),
    'app_not_listed' => text(
      'The app cannot appear in the manager list, so there is nothing to '
          'answer. See the listing rows above.',
      '本应用无法出现在管理器列表中，没有可回答的弹窗。见上方登记条件。',
    ),
    'shizuku_not_running' => text(
      'Shizuku is not running, so nothing was asked.',
      'Shizuku 未运行，没有发出申请。',
    ),
    'request_too_soon' || 'too_many_attempts' || 'request_already_pending' => text(
      'The previous request is still in progress or was just sent. Wait a '
          'moment before asking again.',
      '上一次申请仍在进行或刚刚发出，请稍等再试。',
    ),
    'cancelled_by_user' => text(
      'You cancelled the wait. The dialog may still be open in the manager.',
      '你取消了等待；管理器中可能仍有弹窗。',
    ),
    'permission_revoked' => text(
      "The grant is gone from Shizuku's authorized list.",
      'Shizuku 授权列表中的授权已不存在。',
    ),
    _ => text('No reason reported.', '没有报告原因。'),
  };

  String _sessionReason(String? reason) => switch (reason) {
    'bind_timeout' => text(
      'No UserService callback arrived. Some ROMs cannot start a UserService; '
          'authorization alone is not execution readiness.',
      '用户服务没有返回连接回调。部分 ROM 无法启动用户服务；已授权不等于可以执行。',
    ),
    'handshake_timeout' || 'handshake_failed' || 'handshake_mismatch' => text(
      'The Binder arrived, but the service identity and protocol could not be '
          'verified. No command was started.',
      '已收到 Binder，但未能确认服务身份与协议。没有启动任何命令。',
    ),
    'identity_mismatch' => text(
      'The UserService UID differs from the server UID. No command was started.',
      '用户服务 UID 与服务端 UID 不一致，没有启动任何命令。',
    ),
    'protocol_mismatch' => text(
      'The UserService speaks a different protocol version than this app.',
      '用户服务的协议版本与本应用不一致。',
    ),
    'service_died' || 'binding_died' => text(
      'The UserService died or was disconnected. Reconnect to continue.',
      '用户服务已结束或断开，可重新连接。',
    ),
    _ => text('No reason reported.', '没有报告原因。'),
  };

  // --------------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final snapshot = _snapshot;
    final policy = _policy;
    final ready = snapshot?.executionAdmitted == true;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(text('Shizuku', 'Shizuku')),
        actions: [
          IconButton(
            tooltip: text('Refresh', '刷新'),
            onPressed: _busy
                ? null
                : () => _run(() async {
                    await _refresh();
                    await _loadPolicy();
                  }),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (snapshot == null)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator()),
            ),
          if (snapshot != null) ...[
            _summary(context, snapshot, ready),
            const Divider(height: 32),
            _section(context, text('Manager and registration', '管理器与登记')),
            _row(
              context,
              text('Shizuku manager installed', 'Shizuku 管理器已安装'),
              switch (snapshot.manager) {
                ShizukuManager.installed => text('Yes', '是'),
                ShizukuManager.notInstalled => text('No', '否'),
                ShizukuManager.unknown => text('Unknown', '未知'),
              },
            ),
            _row(
              context,
              text('Provider', '权限提供方'),
              snapshot.provider,
            ),
            _row(
              context,
              text('Installed app ID', '当前安装包 ID'),
              snapshot.registration.applicationId,
            ),
            _row(
              context,
              text('Requests API_V23', '已申请 API_V23'),
              _yesNo(snapshot.registration.permissionDeclared),
            ),
            _row(
              context,
              text('Declares V3_SUPPORT', '已声明 V3_SUPPORT'),
              _yesNo(snapshot.registration.v3Support),
            ),
            _row(
              context,
              text('ShizukuProvider configured', 'ShizukuProvider 配置正确'),
              _yesNo(snapshot.registration.providerConfigured),
            ),
            if (!snapshot.registration.listed)
              _warning(context, _blockedExplanation('app_not_listed')),
            const Divider(height: 32),
            _section(context, text('Service and authorization', '服务与授权')),
            _row(
              context,
              text('Shizuku Binder', 'Shizuku Binder'),
              switch (snapshot.binder) {
                ShizukuBinder.alive => text('Alive', '存活'),
                ShizukuBinder.dead => text('Dead', '已断开'),
                ShizukuBinder.absent => text('Not received', '未收到'),
              },
            ),
            ListTile(
              key: const ValueKey('shizuku-permission-status'),
              title: Text(text('Authorization', '授权')),
              subtitle: Text(
                '${_authorizationLabel(snapshot.authorization)} · '
                '${snapshot.authorizationEvidence}'
                '${snapshot.authorizationReason == null ? '' : ' · ${snapshot.authorizationReason}'}',
              ),
            ),
            if (snapshot.authorization == ShizukuAuthorization.unknown)
              _warning(
                context,
                _authorizationReason(snapshot.authorizationReason),
                key: const ValueKey('shizuku-permission-unverified'),
              ),
            ListTile(
              title: Text(text('Authorization request', '授权申请')),
              subtitle: Text(
                '${snapshot.request.phase.name}'
                '${snapshot.request.attempts == 0 ? '' : ' · ${snapshot.request.attempts}×'}'
                '${snapshot.request.reason == null ? '' : ' · ${snapshot.request.reason}'}',
              ),
            ),
            if (snapshot.request.reason != null)
              _warning(context, _requestReason(snapshot.request.reason)),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton(
                    key: const ValueKey('shizuku-request-permission'),
                    onPressed:
                        _busy ||
                            snapshot.request.phase == ShizukuRequestPhase.pending
                        ? null
                        : () => _run(ShizukuPlatform.requestAuthorization),
                    child: Text(
                      text('Request authorization', '申请授权'),
                    ),
                  ),
                  if (snapshot.request.phase == ShizukuRequestPhase.pending)
                    OutlinedButton(
                      onPressed: _busy
                          ? null
                          : () => _run(ShizukuPlatform.cancelAuthorization),
                      child: Text(text('Stop waiting', '停止等待')),
                    ),
                  OutlinedButton(
                    onPressed: _busy
                        ? null
                        : () => _run(() async {
                            await ShizukuPlatform.openManager();
                          }),
                    child: Text(text('Open manager', '打开管理器')),
                  ),
                ],
              ),
            ),
            const Divider(height: 32),
            _section(context, text('Execution identity', '执行身份')),
            _row(
              context,
              text('Server UID', '服务端 UID'),
              snapshot.identity.uid?.toString() ?? text('Unknown', '未知'),
            ),
            _row(
              context,
              text('Backend', '执行后端'),
              switch (snapshot.identity.backend) {
                'root' => 'ROOT (UID 0)',
                'adb' => 'ADB (UID 2000)',
                _ => text('Unknown', '未知'),
              },
            ),
            _row(
              context,
              text('Server API version', '服务端 API 版本'),
              snapshot.identity.apiVersion?.toString() ?? text('Unknown', '未知'),
            ),
            _row(
              context,
              text('UserService', '用户服务'),
              '${snapshot.session.phase.name}'
                  '${snapshot.session.reason == null ? '' : ' · ${snapshot.session.reason}'}',
            ),
            if (snapshot.session.reason != null)
              _warning(
                context,
                _sessionReason(snapshot.session.reason),
                key: const ValueKey('shizuku-binding-reason'),
              ),
            if (snapshot.session.phase == ShizukuSessionPhase.ready)
              _row(
                context,
                text('UserService instance', '用户服务实例'),
                snapshot.session.instance ?? '—',
              ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton(
                    key: const ValueKey('shizuku-reconnect'),
                    onPressed: _busy
                        ? null
                        : () => _run(ShizukuPlatform.connectService),
                    child: Text(text('Connect UserService', '连接用户服务')),
                  ),
                  OutlinedButton(
                    onPressed: _busy
                        ? null
                        : () => _run(ShizukuPlatform.disconnectService),
                    child: Text(text('Disconnect', '断开连接')),
                  ),
                ],
              ),
            ),
            const Divider(height: 32),
            _section(context, text('Execution prerequisites', '执行前提')),
            _row(
              context,
              text('Operation records readable', '操作记录可读取'),
              _yesNo(snapshot.storageReady),
            ),
            _row(
              context,
              text('AI → Android bridge', 'AI → Android 通道'),
              _yesNo(snapshot.bridgeReady),
            ),
            _row(
              context,
              text('Safety overlay allowed', '已允许安全警告悬浮窗'),
              _yesNo(snapshot.overlayAllowed),
            ),
            if (!snapshot.overlayAllowed)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton(
                    onPressed: _busy
                        ? null
                        : () => _run(ShizukuPlatform.openOverlaySettings),
                    child: Text(
                      text(
                        'Allow the safety overlay in system settings',
                        '在系统设置中允许安全警告悬浮窗',
                      ),
                    ),
                  ),
                ),
              ),
            const Divider(height: 32),
            SwitchListTile(
              title: Text(text('Enable Shizuku commands', '启用 Shizuku 命令')),
              subtitle: Text(
                text(
                  'This switch is this app’s own gate. Turning it on does not '
                      'grant Shizuku authorization and does not connect the '
                      'UserService; those are separate steps shown above.',
                  '这个开关只控制本应用是否启用。开启它不会获得 Shizuku 授权，也不会连接用户服务；'
                      '那是上面两个独立步骤。',
                ),
              ),
              value: snapshot.featureEnabled,
              onChanged: _busy
                  ? null
                  : (value) => _run(() async {
                      final updated = await ShizukuPlatform.setFeatureEnabled(
                        value,
                      );
                      if (mounted) setState(() => _snapshot = updated);
                    }),
            ),
            if (policy != null) ...[
              const Divider(height: 32),
              _section(context, text('Command policy', '命令策略')),
              SwitchListTile(
                key: const ValueKey('shizuku-advanced'),
                title: Text(text('I am an advanced user', '我是高级用户')),
                subtitle: Text(
                  text(
                    'YELLOW, BLUE and GREEN run automatically; RED still opens '
                        'the overlay with a 3-second wait. Unverified scripts '
                        'and sensitive reads are RED.',
                    '黄、蓝、绿等级自动执行；红色仍弹窗并等待 3 秒。'
                        '未验证的脚本和敏感读取属于红色。',
                  ),
                ),
                value: policy.advancedMode,
                onChanged: _canEditPolicy ? _toggleAdvanced : null,
              ),
              SwitchListTile(
                key: const ValueKey('shizuku-direct-read'),
                title: Text(text('Read-only commands run directly', '只读命令直接执行')),
                subtitle: Text(
                  text(
                    'Only a narrow, checked read-only grammar runs without an '
                        'overlay: single commands, no pipes, redirects or '
                        'operators.',
                    '只有经过校验的窄只读语法可以不弹窗：单条命令，不含管道、重定向和操作符。',
                  ),
                ),
                value: policy.directReadOnly,
                onChanged: !_canEditPolicy
                    ? null
                    : (value) => _save(policy.copyWith(directReadOnly: value)),
              ),
              _slider(
                context,
                text('Overlay allow delay (seconds)', '弹窗允许等待（秒）'),
                policy.allowDelaySeconds,
                0,
                (policy.overlayTimeoutSeconds - 1).clamp(0, 60),
                (policy, value) => policy.copyWith(allowDelaySeconds: value),
              ),
              _slider(
                context,
                text('Overlay timeout (seconds)', '弹窗超时自动拒绝（秒）'),
                policy.overlayTimeoutSeconds,
                (policy.allowDelaySeconds + 1).clamp(10, 120),
                120,
                (policy, value) => policy.copyWith(overlayTimeoutSeconds: value),
              ),
              _slider(
                context,
                text('Command timeout (seconds)', '命令执行超时（秒）'),
                policy.commandTimeoutSeconds,
                1,
                120,
                (policy, value) => policy.copyWith(commandTimeoutSeconds: value),
              ),
              _slider(
                context,
                text('Output limit (KiB)', '输出上限（KiB）'),
                policy.maxOutputKiB,
                4,
                256,
                (policy, value) => policy.copyWith(maxOutputKiB: value),
              ),
            ],
            const Divider(height: 32),
            _section(context, text('Checks', '检查')),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
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
                      : () => _run(
                          () => _execute('sleep 10', prefix: 'shz-wait'),
                        ),
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
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  text(
                    'Stop requested. Wait for the actual termination result; '
                        'side effects are not undone.',
                    '已请求停止，请等待实际终止结果；已经产生的副作用不会回滚。',
                  ),
                ),
              ),
            if (_result != null) _resultCard(context, _result!),
          ],
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                '$_error',
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Text(
              text(
                'Shizuku must be started by its own manager. This app never '
                    'grants itself authorization, never fakes a grant and never '
                    'falls back to another execution path.',
                'Shizuku 必须由它自己的管理器启动。本应用不会给自己授权、不会伪造授权，'
                    '也不会切换到其他执行路径。',
              ),
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }

  Widget _summary(
    BuildContext context,
    ShizukuSnapshot snapshot,
    bool ready,
  ) {
    final theme = Theme.of(context);
    final color = ready
        ? theme.colorScheme.primary
        : theme.colorScheme.error;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              ready
                  ? text('Ready to execute', '可以执行')
                  : text('Not ready to execute', '暂不可执行'),
              style: theme.textTheme.titleMedium?.copyWith(color: color),
            ),
            const SizedBox(height: 6),
            Text(_blockedExplanation(snapshot.blockedBy)),
            if (snapshot.blockedBy != null) ...[
              const SizedBox(height: 6),
              Text(
                '${text('Reason', '原因')}: ${snapshot.blockedBy}',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _section(BuildContext context, String title) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Text(title, style: Theme.of(context).textTheme.titleMedium),
  );

  Widget _row(BuildContext context, String title, String value) => ListTile(
    dense: true,
    title: Text(title),
    trailing: Text(value),
  );

  Widget _warning(
    BuildContext context,
    String message, {
    Key? key,
  }) => Padding(
    key: key,
    padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
    child: Text(
      message,
      style: TextStyle(color: Theme.of(context).colorScheme.error),
    ),
  );

  Widget _slider(
    BuildContext context,
    String title,
    int value,
    int min,
    int max,
    ShizukuPolicy Function(ShizukuPolicy policy, int value) update,
  ) {
    final bounded = max > min ? max : min + 1;
    return ListTile(
      title: Text(title),
      subtitle: Slider(
        value: value.clamp(min, bounded).toDouble(),
        min: min.toDouble(),
        max: bounded.toDouble(),
        divisions: (bounded - min).clamp(1, 120),
        label: '$value',
        onChanged: !_canEditPolicy
            ? null
            : (next) => setState(() {
                final policy = _policy;
                if (policy != null) _policy = update(policy, next.round());
              }),
        onChangeEnd: (_) {
          final policy = _policy;
          if (policy != null) _save(policy);
        },
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
          'Execution result is unconfirmed. Do not retry automatically.',
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

  String _yesNo(bool value) =>
      value ? text('Yes', '是') : text('No', '否');

  String _authorizationLabel(ShizukuAuthorization value) => switch (value) {
    ShizukuAuthorization.granted => text('Granted', '已授权'),
    ShizukuAuthorization.denied => text('Denied', '已拒绝'),
    ShizukuAuthorization.unknown => text('Unknown', '无法确认'),
  };
}
