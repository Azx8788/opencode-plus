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
