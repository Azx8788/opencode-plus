import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/channels/channel_capabilities.dart';
import 'package:opencode_mobile/channels/channel_identity.dart';
import 'package:opencode_mobile/channels/channel_message.dart';
import 'package:opencode_mobile/channels/providers/telegram_provider.dart';

void main() {
  group('normalisation', () {
    test('a private update becomes a direct message', () {
      final message = TelegramProvider.normalizeUpdate({
        'update_id': 10,
        'message': {
          'message_id': 5,
          'date': 1700000000,
          'text': '帮我修构建',
          'chat': {'id': 424242, 'type': 'private'},
          'from': {'id': 424242, 'is_bot': false, 'username': 'owner'},
        },
      }, accountId: 'profile-1');

      expect(message, isNotNull);
      expect(message!.conversationType, ChannelConversationKind.direct);
      expect(message.conversationId, '424242');
      expect(message.senderId, '424242');
      expect(message.promptText, '帮我修构建');
      expect(message.messageId, '5');
      expect(message.receivedAt.millisecondsSinceEpoch, 1700000000000);
    });

    test('a group update is a group conversation and notices a mention', () {
      final message = TelegramProvider.normalizeUpdate(
        {
          'update_id': 11,
          'message': {
            'message_id': 6,
            'date': 1700000000,
            'text': '@demo_bot 看一下',
            'chat': {'id': -1001, 'type': 'supergroup', 'title': '团队'},
            'from': {'id': 99, 'is_bot': false},
          },
        },
        accountId: 'profile-1',
        botUsername: 'demo_bot',
      );

      expect(message!.conversationType, ChannelConversationKind.group);
      expect(message.conversationId, '-1001');
      expect(message.mentionsAccount, isTrue);
      expect(message.conversationTitle, '团队');
    });

    test('a channel post is its own kind', () {
      final message = TelegramProvider.normalizeUpdate({
        'update_id': 12,
        'message': {
          'message_id': 7,
          'date': 1700000000,
          'text': 'post',
          'chat': {'id': -2002, 'type': 'channel'},
          'from': {'id': 1},
        },
      }, accountId: 'profile-1');
      expect(message!.conversationType, ChannelConversationKind.channel);
    });

    test('an update without a message is ignored', () {
      expect(
        TelegramProvider.normalizeUpdate({
          'update_id': 13,
          'edited_message': {},
        }, accountId: 'profile-1'),
        isNull,
      );
    });

    test('media without text still arrives, so the bot can answer', () {
      final message = TelegramProvider.normalizeUpdate({
        'update_id': 14,
        'message': {
          'message_id': 8,
          'date': 1700000000,
          'photo': [
            {'file_id': 'x'},
          ],
          'chat': {'id': 424242, 'type': 'private'},
          'from': {'id': 424242},
        },
      }, accountId: 'profile-1');
      expect(message, isNotNull);
      expect(message!.promptText, isEmpty);
    });
  });

  group('policy on the telegram channel', () {
    test('only the configured private owner is admitted', () {
      const policy = ChannelPolicy(
        allowedUsers: {'424242'},
        allowDirectMessages: true,
        allowGroupMessages: false,
      );
      final owner = TelegramProvider.normalizeUpdate({
        'update_id': 1,
        'message': {
          'message_id': 1,
          'date': 1700000000,
          'text': 'hi',
          'chat': {'id': 424242, 'type': 'private'},
          'from': {'id': 424242},
        },
      }, accountId: 'profile-1')!;
      final stranger = TelegramProvider.normalizeUpdate({
        'update_id': 2,
        'message': {
          'message_id': 2,
          'date': 1700000000,
          'text': 'hi',
          'chat': {'id': 999, 'type': 'private'},
          'from': {'id': 999},
        },
      }, accountId: 'profile-1')!;
      expect(policy.evaluate(owner, botAccountId: 'profile-1').allowed, isTrue);
      expect(
        policy.evaluate(stranger, botAccountId: 'profile-1').denial,
        PolicyDenial.userNotAllowed,
      );
    });
  });

  group('capabilities', () {
    test('Telegram declares text, replies and chunked long text', () {
      const capabilities = TelegramProvider.declaredCapabilities;
      expect(capabilities.supports(ChannelCapability.directMessage), isTrue);
      expect(capabilities.supports(ChannelCapability.longText), isTrue);
      expect(capabilities.supports(ChannelCapability.messageEdit), isFalse);
      expect(
        capabilities.spec(ChannelCapability.longText).limit,
        contains('3500'),
      );
      expect(
        capabilities.statusOf(ChannelCapability.activeMessage),
        CapabilityStatus.unsupported,
      );
    });
  });
}
