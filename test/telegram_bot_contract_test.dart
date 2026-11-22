import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/telegram/telegram_bot.dart';

void main() {
  group('Telegram private-message allowlist', () {
    test('accepts only the configured human in a private chat', () {
      expect(
        telegramPrivateMessageAllowed(
          allowedUserID: '123456789',
          chatType: 'private',
          senderID: 123456789,
          chatID: 123456789,
          senderIsBot: false,
        ),
        isTrue,
      );
    });

    test('rejects another user, groups, bots, and malformed allowlists', () {
      bool allowed({
        String id = '123456789',
        Object? chatType = 'private',
        Object? sender = 123456789,
        Object? chat = 123456789,
        bool bot = false,
      }) => telegramPrivateMessageAllowed(
        allowedUserID: id,
        chatType: chatType,
        senderID: sender,
        chatID: chat,
        senderIsBot: bot,
      );

      expect(allowed(sender: 123456788), isFalse);
      expect(allowed(chatType: 'group'), isFalse);
      expect(allowed(bot: true), isFalse);
      expect(allowed(id: '-123456789'), isFalse);
      expect(allowed(chat: -123456789), isFalse);
    });

    test('accepts a username with or without @, ignoring case', () {
      for (final username in ['owner_name', '@Owner_Name', ' @OWNER_NAME ']) {
        expect(
          telegramPrivateMessageAllowed(
            allowedUsername: username,
            chatType: 'private',
            senderID: 123456789,
            senderUsername: 'Owner_Name',
            chatID: 123456789,
            senderIsBot: false,
          ),
          isTrue,
          reason: username,
        );
      }
    });

    test('username matching never bypasses private-chat checks', () {
      bool allowed({
        String username = 'owner_name',
        Object? senderUsername = 'owner_name',
        Object? chatType = 'private',
        Object? sender = 123456789,
        Object? chat = 123456789,
        bool bot = false,
      }) => telegramPrivateMessageAllowed(
        allowedUsername: username,
        chatType: chatType,
        senderID: sender,
        senderUsername: senderUsername,
        chatID: chat,
        senderIsBot: bot,
      );

      expect(allowed(senderUsername: 'other_name'), isFalse);
      expect(allowed(senderUsername: null), isFalse);
      expect(allowed(senderUsername: 123456789), isFalse);
      expect(allowed(chatType: 'group'), isFalse);
      expect(allowed(chatType: 'supergroup'), isFalse);
      expect(allowed(chatType: 'channel'), isFalse);
      expect(allowed(bot: true), isFalse);
      expect(allowed(chat: 987654321), isFalse);
      expect(allowed(sender: null, chat: null), isFalse);
      expect(allowed(sender: -1, chat: -1), isFalse);
      expect(allowed(username: 'Owner Name'), isFalse);
      expect(allowed(username: 'https://t.me/owner_name'), isFalse);
      expect(allowed(username: '@'), isFalse);
      expect(allowed(username: '@@owner_name'), isFalse);
      expect(allowed(username: List.filled(33, 'a').join()), isFalse);
      expect(allowed(username: ''), isFalse);
    });

    test('when both are configured, username and ID must both match', () {
      bool allowed({String id = '123456789', String username = 'owner_name'}) =>
          telegramPrivateMessageAllowed(
            allowedUserID: id,
            allowedUsername: username,
            chatType: 'private',
            senderID: 123456789,
            senderUsername: 'owner_name',
            chatID: 123456789,
            senderIsBot: false,
          );

      expect(allowed(), isTrue);
      expect(allowed(id: '987654321'), isFalse);
      expect(allowed(id: '-123456789'), isFalse);
      expect(allowed(username: 'other_name'), isFalse);
    });
  });

  test(
    'splits Telegram messages within the UTF-16 limit without splitting emoji',
    () {
      final prefix = List.filled(3499, 'a').join();
      final text = '$prefix😀b';
      final chunks = telegramMessageChunks(text);
      expect(chunks, hasLength(2));
      expect(chunks.first, prefix);
      expect(chunks.last, '😀b');
      expect(chunks.every((chunk) => chunk.length <= 3500), isTrue);
      expect(chunks.join(), text);
    },
  );
}
