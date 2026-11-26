import 'dart:async';

import 'package:flutter/material.dart';

import '../../../channels/channel_hub.dart';
import '../../../channels/channel_tasks.dart';
import '../../../channels/manager/manager_config.dart';
import '../../../state/connection.dart';
import '../../app_iconography.dart';
import '../../app_theme.dart' show AppStatusTone;
import '../../kit/kit.dart';

/// The manager model's settings, and what the channels have been doing.
///
/// Kept apart from the executor's model on purpose: the manager decides what
/// the person reads, the executor writes the code, and a phone can reasonably
/// want a small fast model for one and a large one for the other.
class ManagerAgentScreen extends StatefulWidget {
  const ManagerAgentScreen({super.key, required this.controller});

  final ConnectionController controller;

  @override
  State<ManagerAgentScreen> createState() => _ManagerAgentScreenState();
}

class _ManagerAgentScreenState extends State<ManagerAgentScreen> {
  late final ChannelHub _hub = widget.controller.channels;
  late final TextEditingController _url = TextEditingController();
  late final TextEditingController _model = TextEditingController();
  late final TextEditingController _key = TextEditingController();
  late final TextEditingController _steps = TextEditingController(text: '6');

  bool _enabled = false;
  bool _hasKey = false;
  bool _replacingKey = false;
  bool _busy = false;
  String? _notice;
  String? _error;

  bool get _zh => Localizations.localeOf(context).languageCode == 'zh';
  String _text(String en, String zh) => _zh ? zh : en;

  @override
  void initState() {
    super.initState();
    _hub.addListener(_changed);
    widget.controller.addListener(_changed);
    unawaited(_hub.initialize().then((_) => _load()));
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _load() {
    if (!mounted) return;
    final config = _hub.managerAgentConfig;
    _url.text = config.baseUrl;
    _model.text = config.model;
    _steps.text = '${config.maxSteps}';
    _enabled = config.enabled;
    setState(() {});
    unawaited(
      _hub.managerConfig.loadApiKey().then((value) {
        if (!mounted) return;
        setState(() => _hasKey = value.trim().isNotEmpty);
      }),
    );
  }

  @override
  void dispose() {
    _hub.removeListener(_changed);
    widget.controller.removeListener(_changed);
    _url.dispose();
    _model.dispose();
    _key.dispose();
    _steps.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      await _hub.saveManagerAgent(
        ManagerAgentConfig(
          enabled: _enabled,
          baseUrl: _url.text.trim(),
          model: _model.text.trim(),
          maxSteps: int.tryParse(_steps.text.trim()) ?? 6,
        ),
        apiKey: _key.text.trim().isEmpty ? null : _key.text.trim(),
      );
      if (!mounted) return;
      setState(() {
        _notice = _text('Saved.', '已保存。');
        _key.clear();
        _replacingKey = false;
        _hasKey = _hasKey || _hub.managerReady;
      });
    } on FormatException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } on Object {
      if (mounted) {
        setState(() {
          _error = _text(
            'Could not save the manager settings.',
            '无法保存管理代理设置。',
          );
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = KitTokens.of(context);
    final tasks = _hub.tasks.recent(limit: 12);

    return KitScreen(
      topBar: KitTopBar(title: _text('Manager agent', '管理代理')),
      width: KitScreenWidth.reading,
      body: ListView(
        padding: KitScreen.padding(context),
        children: [
          KitText(
            _text(
              'The manager reads each channel message, decides whether to hand it to the executor, and writes what the person sees. It is a separate model from the one the executor runs.',
              '管理代理阅读每条渠道消息，决定是否交给执行 Agent，并决定用户看到什么。它使用独立于执行 Agent 的模型。',
            ),
            role: KitTextRole.body,
          ),
          SizedBox(height: tokens.space4),
          KitSwitchRow(
            key: const ValueKey('manager-enabled'),
            title: _text('Use a manager agent', '启用管理代理'),
            supporting: _text(
              'Off: channels relay the executor\'s last message, as before.',
              '关闭时：渠道沿用原有方式，转发执行 Agent 的最后一条消息。',
            ),
            value: _enabled,
            onChanged: _busy
                ? null
                : (value) => setState(() => _enabled = value),
          ),
          SizedBox(height: tokens.space4),
          KitField(
            key: const ValueKey('manager-url'),
            label: _text('Endpoint', '接口地址'),
            controller: _url,
            enabled: !_busy,
            disabledReason: _busy ? _text('Saving', '正在保存') : null,
            hint: 'https://api.example.com/v1',
            helper: _text(
              'An OpenAI-compatible Chat Completions endpoint. `/v1` or the full `/chat/completions` URL.',
              '兼容 OpenAI Chat Completions 的接口。填到 `/v1` 或完整的 `/chat/completions` 均可。',
            ),
          ),
          SizedBox(height: tokens.space3),
          KitField(
            key: const ValueKey('manager-model'),
            label: _text('Model', '模型'),
            controller: _model,
            enabled: !_busy,
            disabledReason: _busy ? _text('Saving', '正在保存') : null,
            hint: 'gpt-4o-mini',
          ),
          SizedBox(height: tokens.space3),
          KitField.secret(
            key: const ValueKey('manager-key'),
            label: _text('API key', 'API Key'),
            controller: _key,
            saved: _hasKey && !_replacingKey,
            onReplace: () => setState(() => _replacingKey = true),
            enabled: !_busy,
            disabledReason: _busy ? _text('Saving', '正在保存') : null,
            helper: _hasKey
                ? _text(
                    'A key is stored. Leave blank to keep it.',
                    '已保存密钥，留空表示不修改。',
                  )
                : _text(
                    'Stored in Android secure storage, never in preferences.',
                    '保存在 Android 安全存储中，不写入偏好设置。',
                  ),
          ),
          SizedBox(height: tokens.space3),
          KitField(
            key: const ValueKey('manager-steps'),
            label: _text('Tool steps per request', '每次请求的工具步数上限'),
            kind: KitFieldKind.number,
            controller: _steps,
            enabled: !_busy,
            disabledReason: _busy ? _text('Saving', '正在保存') : null,
            hint: '6',
            helper: _text(
              'A manager that keeps calling tools is a bug, not a conversation.',
              '反复调用工具不收敛属于缺陷，不能让它一直循环。',
            ),
          ),
          if (_error != null) ...[
            SizedBox(height: tokens.space3),
            KitNotice(message: _error!, tone: AppStatusTone.failure),
          ],
          if (_notice != null) ...[
            SizedBox(height: tokens.space3),
            KitNotice(message: _notice!, tone: AppStatusTone.ok),
          ],
          SizedBox(height: tokens.space4),
          KitButton.primary(
            key: const ValueKey('manager-save'),
            label: _text('Save', '保存'),
            onPressed: _busy ? null : _save,
            working: _busy,
          ),
          SizedBox(height: tokens.space6),
          KitText(
            _text('What the channels have done', '渠道任务记录'),
            role: KitTextRole.label,
          ),
          SizedBox(height: tokens.space2),
          KitText(
            _text(
              'An answer that the agent produced but the platform refused is listed as "not delivered" — the two failures are different.',
              'Agent 已产出但平台拒绝发送的答复会标为「未送达」——两种失败不是一回事。',
            ),
            role: KitTextRole.caption,
          ),
          SizedBox(height: tokens.space3),
          if (tasks.isEmpty)
            KitGroupNote(
              message: _text(
                'No tasks recorded yet.',
                '还没有任务记录。',
              ),
            )
          else
            for (final task in tasks) ...[
              _TaskRow(task: task),
              SizedBox(height: tokens.space2),
            ],
          SizedBox(height: tokens.space5),
          KitGroupNote(
            message: _text(
              'The manager cannot approve permissions, cannot reach another conversation, and cannot send a file. Those stay in the app and in the channel\'s own limits.',
              '管理代理不能批准权限、不能联系其它会话、不能发送文件。这些仍由应用和渠道自身的限制决定。',
            ),
          ),
        ],
      ),
    );
  }
}

class _TaskRow extends StatelessWidget {
  const _TaskRow({required this.task});

  final ChannelTaskRecord task;

  @override
  Widget build(BuildContext context) {
    final tokens = KitTokens.of(context);
    final zh = Localizations.localeOf(context).languageCode == 'zh';
    String text(String en, String value) => zh ? value : en;

    final failed = task.answeredButUndelivered;
    return KitRow(
      key: ValueKey('manager-task-${task.id}'),
      title: task.prompt.isEmpty ? task.id : task.prompt,
      supporting: TextSpan(
        text:
            '${task.status.name} · ${task.delivery.name}'
            '${task.result != null && task.result!.isNotEmpty ? ' · ${_trim(task.result!)}' : ''}',
      ),
      leading: KitRow.icon(
        context,
        failed ? AppIconography.warning : AppIconography.chat,
      ),
      trailing: KitStatusTag(
        label: failed
            ? text('not delivered', '未送达')
            : task.status.name,
        tone: failed
            ? KitStatusTagTone.needsYou
            : task.status == ChannelTaskStatus.completed
            ? KitStatusTagTone.done
            : KitStatusTagTone.failed,
      ),
      onTap: null,
      padding: EdgeInsets.symmetric(vertical: tokens.space1),
    );
  }

  static String _trim(String value) =>
      value.length <= 40 ? value : '${value.substring(0, 40)}…';
}
