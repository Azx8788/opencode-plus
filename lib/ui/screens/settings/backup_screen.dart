import 'dart:async';

import 'package:flutter/material.dart';

import '../../../backup/app_backup.dart';
import '../../../backup/backup_controller.dart';
import '../../../backup/backup_wiring.dart';
import '../../../builtin/project_export.dart' show ProjectExportFailure;
import '../../../state/connection.dart';
import '../../app_theme.dart' show AppStatusTone;
import '../../kit/kit.dart';

/// "Backup and export": one zip with the settings, the credentials and the
/// conversations of a window the person chooses.
///
/// This half only builds the controller (it needs plugins and the connection);
/// [BackupPage] draws it, so the page itself can be tested with fakes.
class BackupScreen extends StatefulWidget {
  const BackupScreen({super.key, required this.controller});

  final ConnectionController controller;

  @override
  State<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends State<BackupScreen> {
  BackupController? _backup;
  Object? _openError;

  @override
  void initState() {
    super.initState();
    unawaited(_open());
  }

  Future<void> _open() async {
    try {
      final backup = await createBackupController(widget.controller);
      if (!mounted) {
        backup.dispose();
        return;
      }
      setState(() => _backup = backup);
    } on Object catch (error) {
      if (mounted) setState(() => _openError = error);
    }
  }

  @override
  void dispose() {
    _backup?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final backup = _backup;
    if (backup == null) {
      return KitScreen(
        topBar: KitTopBar(title: _text(context, 'Backup and export', '备份与导出')),
        width: KitScreenWidth.reading,
        body: Center(
          child: _openError == null
              ? const CircularProgressIndicator()
              : KitText(
                  _text(
                    context,
                    'The backup page could not start on this build.',
                    '此版本无法启动备份页面。',
                  ),
                  role: KitTextRole.body,
                ),
        ),
      );
    }
    return ListenableBuilder(
      listenable: backup,
      builder: (context, _) => BackupPage(backup: backup),
    );
  }
}

bool _isZh(BuildContext context) =>
    Localizations.localeOf(context).languageCode == 'zh';

String _text(BuildContext context, String en, String zh) =>
    _isZh(context) ? zh : en;

/// The page, drawn from one controller's state.
class BackupPage extends StatelessWidget {
  const BackupPage({super.key, required this.backup});

  final BackupController backup;

  String _daysLabel(BuildContext context, int days) => days <= 0
      ? _text(context, 'All', '全部')
      : _text(context, '$days days', '$days 天');

  String _size(int bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1024) return '${(bytes / 1024).round()} KB';
    return '$bytes B';
  }

  String _failure(BuildContext context, ProjectExportFailure? failure) =>
      switch (failure) {
        ProjectExportFailure.destination => _text(
          context,
          'The chosen place refused the file or went away. Try another folder.',
          '所选位置拒绝了文件或已断开，请换一个文件夹。',
        ),
        ProjectExportFailure.space => _text(
          context,
          'The chosen place is full. Free some room and try again.',
          '所选位置空间不足，请清理后重试。',
        ),
        ProjectExportFailure.source => _text(
          context,
          'A file could not be read. Try again, or choose fewer days.',
          '有文件读取失败，请重试或减少天数。',
        ),
        ProjectExportFailure.cancelled => _text(context, 'Stopped.', '已停止。'),
        ProjectExportFailure.failed => _text(
          context,
          'The export did not finish. Try again, or pick another folder.',
          '导出未完成，请重试或换一个文件夹。',
        ),
        null => '',
      };

  String? _status(BuildContext context) {
    switch (backup.phase) {
      case BackupPhase.collecting:
        if (backup.chatsTotal > 0) {
          return _text(
            context,
            'Reading conversations ${backup.chatsDone} of ${backup.chatsTotal}…',
            '正在读取对话 ${backup.chatsDone}/${backup.chatsTotal}…',
          );
        }
        return _text(
          context,
          'Reading settings and conversations…',
          '正在读取设置与对话…',
        );
      case BackupPhase.staging:
        return _text(context, 'Packing the archive…', '正在整理备份内容…');
      case BackupPhase.picking:
        return _text(context, 'Choose where to save it.', '请选择保存位置。');
      case BackupPhase.writing:
        final percent = (backup.progress * 100).round();
        return _text(
          context,
          'Writing… $percent% of ${_size(backup.bytesTotal)}',
          '正在写入… $percent%（共 ${_size(backup.bytesTotal)}）',
        );
      case BackupPhase.done:
        final bundle = backup.bundle;
        if (bundle == null) return _text(context, 'Done.', '已完成。');
        final parts = <String>[
          if (bundle.sessions > 0)
            _text(
              context,
              '${bundle.sessions} conversations (${bundle.messages} messages)',
              '${bundle.sessions} 个对话（${bundle.messages} 条消息）',
            ),
          _text(
            context,
            '${bundle.settings} settings',
            '${bundle.settings} 项设置',
          ),
          if (bundle.secrets > 0)
            _text(
              context,
              '${bundle.secrets} credentials',
              '${bundle.secrets} 个密钥',
            ),
        ];
        return _text(
          context,
          'Saved: ${parts.join(', ')} · ${_size(backup.result?.bytes ?? bundle.bytes)}',
          '已保存：${parts.join('、')} · ${_size(backup.result?.bytes ?? bundle.bytes)}',
        );
      case BackupPhase.failed:
        return _failure(context, backup.result?.failure);
      case BackupPhase.idle:
        return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = KitTokens.of(context);
    final options = backup.options;
    final busy = backup.busy;
    final status = _status(context);
    final failed = backup.phase == BackupPhase.failed;
    final done = backup.phase == BackupPhase.done;

    return KitScreen(
      topBar: KitTopBar(title: _text(context, 'Backup and export', '备份与导出')),
      width: KitScreenWidth.reading,
      body: ListView(
        padding: KitScreen.padding(context),
        children: [
          KitText(
            _text(
              context,
              'One zip with this app’s settings, its credentials and the conversations you choose to keep. Save it somewhere outside the phone; Android’s “Clear storage” deletes everything this archive holds.',
              '把 App 的设置、密钥和你选择保留的对话打成一个压缩包。请存到手机之外；Android 的“清除存储”会删掉这个包里的全部内容。',
            ),
            role: KitTextRole.body,
          ),
          SizedBox(height: tokens.space5),
          KitSectionLabel(_text(context, 'Conversation history', '对话记录范围')),
          KitSegmented<int>(
            key: const ValueKey('backup-days'),
            semanticsLabel: _text(
              context,
              'How many days of conversation',
              '导出多少天的对话',
            ),
            selected: options.days,
            segments: [
              for (final days in BackupOptions.dayChoices)
                KitSegment(value: days, label: _daysLabel(context, days)),
            ],
            onChanged: busy
                ? null
                : (days) =>
                      backup.setOptions(backup.options.copyWith(days: days)),
            disabledReason: _text(context, 'Working', '正在处理'),
          ),
          SizedBox(height: tokens.space2),
          KitText(
            _text(
              context,
              'A conversation counts if it was used inside the window, even if it started earlier. Whole conversations are kept, so a long chat stays readable.',
              '只要在范围内有过活动就算（即使更早开始），并保留整段对话，读起来才连贯。',
            ),
            role: KitTextRole.caption,
            tone: KitTextTone.secondary,
          ),
          SizedBox(height: tokens.space4),
          KitSectionLabel(_text(context, 'What goes in', '包含内容')),
          KitSwitchRow(
            key: const ValueKey('backup-chat'),
            title: _text(context, 'Conversations', '对话记录'),
            supporting: _text(
              context,
              'Every message of the conversations in the window.',
              '范围内对话的全部消息。',
            ),
            value: options.includeChat,
            onChanged: busy
                ? null
                : (value) => backup.setOptions(
                    backup.options.copyWith(includeChat: value),
                  ),
          ),
          KitSwitchRow(
            key: const ValueKey('backup-text-only'),
            title: _text(context, 'Text only', '只保留文字'),
            supporting: _text(
              context,
              'Drops tool calls, their output and attachments. Much smaller on agent-heavy chats, and no longer a full record.',
              '去掉工具调用、输出和附件。对 Agent 用得多的对话能小很多，但不再是完整记录。',
            ),
            value: options.textOnly && options.includeChat,
            onChanged: busy || !options.includeChat
                ? null
                : (value) => backup.setOptions(
                    backup.options.copyWith(textOnly: value),
                  ),
            disabledReason: options.includeChat
                ? null
                : _text(context, 'Conversations are off', '未包含对话'),
          ),
          KitSwitchRow(
            key: const ValueKey('backup-secrets'),
            title: _text(context, 'Credentials', '密钥与登录信息'),
            supporting: _text(
              context,
              'Bot token, provider keys and saved server passwords, in plain text inside the zip.',
              'Bot Token、供应商密钥和已保存的服务器密码，在压缩包里是明文。',
            ),
            value: options.includeSecrets,
            onChanged: busy
                ? null
                : (value) => backup.setOptions(
                    backup.options.copyWith(includeSecrets: value),
                  ),
          ),
          if (options.includeSecrets)
            Padding(
              padding: EdgeInsets.only(top: tokens.space2),
              child: KitText(
                _text(
                  context,
                  'Anyone who opens the archive can use these credentials.',
                  '任何拿到压缩包的人都能使用这些密钥。',
                ),
                role: KitTextRole.caption,
                tone: KitTextTone.attention,
              ),
            ),
          SizedBox(height: tokens.space4),
          if (status != null)
            KitNotice(
              message: status,
              tone: failed
                  ? AppStatusTone.failure
                  : done
                  ? AppStatusTone.ok
                  : AppStatusTone.neutral,
            ),
          if (backup.chatNote != null && done)
            KitText(
              backup.chatNote == 'unsupported'
                  ? _text(
                      context,
                      'This connection cannot be read for conversations, so only settings and credentials were saved.',
                      '当前连接无法读取对话，只导出了设置与密钥。',
                    )
                  : _text(
                      context,
                      'Some conversations could not be read and were left out.',
                      '部分对话读取失败，已跳过。',
                    ),
              role: KitTextRole.caption,
              tone: KitTextTone.attention,
            ),
          KitButton.primary(
            key: const ValueKey('backup-export'),
            label: done
                ? _text(context, 'Export again', '再导出一份')
                : _text(context, 'Export backup', '导出备份'),
            onPressed: busy ? null : backup.export,
            working: busy,
          ),
          if (busy) ...[
            SizedBox(height: tokens.space2),
            KitButton.secondary(
              key: const ValueKey('backup-cancel'),
              label: _text(context, 'Stop', '停止'),
              onPressed: backup.cancel,
            ),
          ],
          SizedBox(height: tokens.space4),
          KitGroupNote(
            message: _text(
              context,
              'Save the zip somewhere you would keep a password: a computer, a drive, or a mail to yourself. The app cannot import it back yet — settings and credentials can be copied by hand, conversations stay readable as JSON.',
              '请把压缩包存到你保存密码的地方：电脑、网盘或发给自己。App 暂时不支持导入，设置和密钥可手动填回，对话以 JSON 形式保留可读。',
            ),
          ),
        ],
      ),
    );
  }
}
