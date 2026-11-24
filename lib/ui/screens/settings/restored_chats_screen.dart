import 'package:flutter/material.dart';

import '../../../backup/app_restore.dart';
import '../../../backup/backup_restore_controller.dart';
import '../../kit/kit.dart';

/// The read-only shelf a restored backup leaves behind: archives, then their
/// conversations, then one conversation's words.
///
/// This is deliberately not the chat screen. OpenCode owns the live store and
/// its schema; these are the messages an archive held, shown as they were
/// written, with nothing that could be sent.
class RestoredChatsScreen extends StatelessWidget {
  const RestoredChatsScreen({super.key, required this.controller});

  final RestoreController controller;

  @override
  Widget build(BuildContext context) {
    final archives = controller.restored;
    return KitScreen(
      topBar: KitTopBar(
        title: _text(context, 'Restored conversations', '已恢复的对话'),
      ),
      width: KitScreenWidth.reading,
      body: archives.isEmpty
          ? Padding(
              padding: KitScreen.padding(context),
              child: KitText(
                _text(
                  context,
                  'No restored conversations yet. Restore a backup and its conversations appear here.',
                  '还没有恢复的对话。恢复一份备份后，其中的对话会出现在这里。',
                ),
                role: KitTextRole.body,
                tone: KitTextTone.secondary,
              ),
            )
          : ListView(
              padding: KitScreen.padding(context),
              children: [
                for (final archive in archives)
                  KitRow(
                    key: ValueKey('restored-archive-${archive.folder}'),
                    title: archive.createdAt == null
                        ? _text(context, 'Undated backup', '无日期备份')
                        : _day(archive.createdAt!),
                    supporting: TextSpan(
                      text: _text(
                        context,
                        [
                          '${archive.chats} conversations',
                          '${archive.messages} messages',
                          if (archive.appVersion != null)
                            'app ${archive.appVersion}',
                        ].join(' · '),
                        [
                          '${archive.chats} 个对话',
                          '${archive.messages} 条消息',
                          if (archive.appVersion != null)
                            'App ${archive.appVersion}',
                        ].join(' · '),
                      ),
                    ),
                    trailing: const KitChevron(),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => _ArchiveChatsScreen(archive: archive),
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}

class _ArchiveChatsScreen extends StatefulWidget {
  const _ArchiveChatsScreen({required this.archive});

  final RestoredArchive archive;

  @override
  State<_ArchiveChatsScreen> createState() => _ArchiveChatsScreenState();
}

class _ArchiveChatsScreenState extends State<_ArchiveChatsScreen> {
  late Future<List<RestoredChat>> _chats;

  @override
  void initState() {
    super.initState();
    _chats = readRestoredArchive(widget.archive.path);
  }

  @override
  Widget build(BuildContext context) {
    return KitScreen(
      topBar: KitTopBar(title: _text(context, 'Conversations', '对话')),
      width: KitScreenWidth.reading,
      body: FutureBuilder<List<RestoredChat>>(
        future: _chats,
        builder: (context, snapshot) {
          final chats = snapshot.data;
          if (chats == null) {
            return const Center(child: CircularProgressIndicator());
          }
          if (chats.isEmpty) {
            return Padding(
              padding: KitScreen.padding(context),
              child: KitText(
                _text(
                  context,
                  'This archive holds no conversations.',
                  '这份备份里没有对话。',
                ),
                role: KitTextRole.body,
                tone: KitTextTone.secondary,
              ),
            );
          }
          return ListView(
            padding: KitScreen.padding(context),
            children: [
              for (final chat in chats)
                KitRow(
                  key: ValueKey('restored-chat-${chat.id}'),
                  title: (chat.title ?? '').trim().isEmpty
                      ? _text(context, 'Untitled conversation', '未命名对话')
                      : chat.title!.trim(),
                  supporting: TextSpan(
                    text: _text(
                      context,
                      [
                        if (chat.updated != null)
                          _day(
                            DateTime.fromMillisecondsSinceEpoch(chat.updated!),
                          ),
                        '${chat.messages.length} messages',
                      ].join(' · '),
                      [
                        if (chat.updated != null)
                          _day(
                            DateTime.fromMillisecondsSinceEpoch(chat.updated!),
                          ),
                        '${chat.messages.length} 条消息',
                      ].join(' · '),
                    ),
                  ),
                  titleMaxLines: 2,
                  trailing: const KitChevron(),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => _TranscriptScreen(chat: chat),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _TranscriptScreen extends StatelessWidget {
  const _TranscriptScreen({required this.chat});

  final RestoredChat chat;

  @override
  Widget build(BuildContext context) {
    final tokens = KitTokens.of(context);
    final messages = [
      for (final message in chat.messages)
        if (messageText(message).isNotEmpty) message,
    ];
    return KitScreen(
      topBar: KitTopBar(
        title: (chat.title ?? '').trim().isEmpty
            ? _text(context, 'Conversation', '对话')
            : chat.title!.trim(),
      ),
      width: KitScreenWidth.reading,
      body: ListView(
        padding: KitScreen.padding(context),
        children: [
          KitText(
            _text(
              context,
              'A record from a backup. Nothing here can be sent to an agent.',
              '来自备份的记录，这里的内容无法发送给 Agent。',
            ),
            role: KitTextRole.caption,
            tone: KitTextTone.secondary,
          ),
          SizedBox(height: tokens.space4),
          for (final message in messages)
            Padding(
              padding: EdgeInsets.only(bottom: tokens.space4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  KitText(
                    _speaker(context, messageRole(message)),
                    role: KitTextRole.caption,
                    tone: KitTextTone.secondary,
                  ),
                  SizedBox(height: tokens.space1),
                  KitSelectable(
                    child: KitText(
                      messageText(message),
                      role: KitTextRole.body,
                    ),
                  ),
                ],
              ),
            ),
          if (messages.isEmpty)
            KitText(
              _text(
                context,
                'This conversation holds no text — only tool calls and output, which the archive kept without their words.',
                '这个对话没有文字内容——只有工具调用和输出，备份里没有可读的文字。',
              ),
              role: KitTextRole.body,
              tone: KitTextTone.secondary,
            ),
        ],
      ),
    );
  }
}

String _speaker(BuildContext context, String role) => switch (role) {
  'user' => _text(context, 'You', '你'),
  'assistant' => _text(context, 'Agent', 'Agent'),
  'system' => _text(context, 'System', '系统'),
  _ => role,
};

String _day(DateTime at) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${at.year}-${two(at.month)}-${two(at.day)} '
      '${two(at.hour)}:${two(at.minute)}';
}

bool _isZh(BuildContext context) =>
    Localizations.localeOf(context).languageCode == 'zh';

String _text(BuildContext context, String en, String zh) =>
    _isZh(context) ? zh : en;
