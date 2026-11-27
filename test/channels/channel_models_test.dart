import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/channels/channel_capabilities.dart';
import 'package:opencode_mobile/channels/channel_identity.dart';
import 'package:opencode_mobile/channels/channel_inbox.dart';
import 'package:opencode_mobile/channels/channel_message.dart';
import 'package:opencode_mobile/channels/channel_outbox.dart';
import 'package:opencode_mobile/channels/channel_provider.dart';
import 'package:opencode_mobile/channels/channel_text.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('text', () {
    test('chunkText never splits a surrogate pair', () {
      final text = '😀' * 5;
      final chunks = chunkText(text, maxCodeUnits: 4);
      expect(chunks, ['😀😀', '😀😀', '😀']);
      expect(chunks.join(), text);
    });

    test('chunkText respects the exact limit', () {
      final chunks = chunkText('a' * 10, maxCodeUnits: 4);
      expect(chunks.map((chunk) => chunk.length), [4, 4, 2]);
    });

    test('chunkText returns nothing for empty text', () {
      expect(chunkText(''), isEmpty);
    });

    test('commands parse with target suffix and full-width slash', () {
      expect(ChannelCommand.parse('/status')?.name, 'status');
      expect(ChannelCommand.parse('/status@demo_bot')?.name, 'status');
      expect(ChannelCommand.parse('／stop')?.name, 'stop');
      expect(ChannelCommand.parse('/queue 跑测试')?.argument, '跑测试');
      expect(ChannelCommand.parse('hello'), isNull);
      expect(ChannelCommand.parse('/'), isNull);
    });

    test('a leading mention is removed from group text', () {
      expect(stripLeadingMention('@bot 看一下'), '看一下');
      expect(stripLeadingMention('@bot'), '');
      expect(stripLeadingMention('看一下'), '看一下');
    });

    test('known secrets are redacted', () {
      expect(
        redactSecrets('token=abc123456789 in the log', ['abc123456789']),
        'token=*** in the log',
      );
      // Short values are left alone: redacting every "abc" mangles messages.
      expect(redactSecrets('abc def', ['abc']), 'abc def');
    });

    test('a fingerprint is scoped by conversation, sender and time bucket', () {
      final at = DateTime(2026, 11, 24, 12, 0, 0);
      final base = messageFingerprint(
        conversationId: 'g1',
        senderId: 'u1',
        text: 'hi',
        receivedAt: at,
      );
      expect(
        messageFingerprint(
          conversationId: 'g2',
          senderId: 'u1',
          text: 'hi',
          receivedAt: at,
        ),
        isNot(base),
      );
      expect(
        messageFingerprint(
          conversationId: 'g1',
          senderId: 'u1',
          text: 'hi',
          receivedAt: at.add(const Duration(seconds: 10)),
        ),
        base,
      );
      expect(
        messageFingerprint(
          conversationId: 'g1',
          senderId: 'u1',
          text: 'hi',
          receivedAt: at.add(const Duration(minutes: 2)),
        ),
        isNot(base),
      );
    });
  });

  group('identity', () {
    test('actor keys are scoped by channel and account', () {
      const a = ActorKey(
        channel: 'onebot11',
        accountId: '10001',
        externalUserId: '20002',
      );
      const b = ActorKey(
        channel: 'qq-official',
        accountId: '10001',
        externalUserId: '20002',
      );
      expect(a.value, isNot(b.value));
      expect(a, isNot(b));
    });

    test('conversation keys cannot be forged by a colon in an id', () {
      final forged = ConversationKey(
        workspaceId: 'w',
        providerId: 'p',
        accountId: 'a',
        conversationType: ChannelConversationKind.group,
        conversationId: 'g:u2',
        ownerActorId: 'u1',
      );
      final honest = ConversationKey(
        workspaceId: 'w',
        providerId: 'p',
        accountId: 'a',
        conversationType: ChannelConversationKind.group,
        conversationId: 'g',
        ownerActorId: 'u2',
      );
      expect(forged.value, isNot(honest.value));
    });

    test('the same conversation id under two accounts is two keys', () {
      ConversationKey key(String account) => ConversationKey(
        workspaceId: 'w',
        providerId: 'onebot11',
        accountId: account,
        conversationType: ChannelConversationKind.direct,
        conversationId: '20002',
        ownerActorId: '20002',
      );
      expect(key('10001').value, isNot(key('10002').value));
    });
  });

  group('policy', () {
    ChannelMessage message({
      ChannelConversationKind kind = ChannelConversationKind.direct,
      String sender = 'u1',
      String conversation = 'c1',
      String text = 'hello',
      bool mentions = false,
    }) => ChannelMessage(
      providerId: 'p',
      accountId: 'bot',
      conversationId: conversation,
      conversationType: kind,
      senderId: sender,
      messageId: '1',
      text: text,
      segments: [ChannelSegment.text(text)],
      mentionsAccount: mentions,
      receivedAt: DateTime(2026, 11, 24),
    );

    test('an empty allowlist admits nobody', () {
      const policy = ChannelPolicy();
      expect(policy.evaluate(message(), botAccountId: 'bot').allowed, isFalse);
    });

    test('an allowlisted direct sender is admitted', () {
      const policy = ChannelPolicy(allowedUsers: {'u1'});
      expect(policy.evaluate(message(), botAccountId: 'bot').allowed, isTrue);
    });

    test('a group needs the group, the user and an address', () {
      const policy = ChannelPolicy(allowedUsers: {'u1'}, allowedGroups: {'g1'});
      expect(
        policy
            .evaluate(
              message(kind: ChannelConversationKind.group, conversation: 'g1'),
              botAccountId: 'bot',
            )
            .denial,
        PolicyDenial.mentionRequired,
      );
      expect(
        policy
            .evaluate(
              message(
                kind: ChannelConversationKind.group,
                conversation: 'g1',
                mentions: true,
              ),
              botAccountId: 'bot',
            )
            .allowed,
        isTrue,
      );
      expect(
        policy
            .evaluate(
              message(
                kind: ChannelConversationKind.group,
                conversation: 'g1',
                text: '/status',
              ),
              botAccountId: 'bot',
            )
            .allowed,
        isTrue,
        reason: 'a command prefix addresses the bot',
      );
      expect(
        policy
            .evaluate(
              message(
                kind: ChannelConversationKind.group,
                conversation: 'g2',
                mentions: true,
              ),
              botAccountId: 'bot',
            )
            .denial,
        PolicyDenial.groupNotAllowed,
      );
      expect(
        policy
            .evaluate(
              message(
                kind: ChannelConversationKind.group,
                conversation: 'g1',
                sender: 'stranger',
                mentions: true,
              ),
              botAccountId: 'bot',
            )
            .denial,
        PolicyDenial.userNotAllowed,
      );
    });

    test('the bot never answers itself', () {
      const policy = ChannelPolicy(allowedUsers: {'bot'});
      expect(
        policy.evaluate(message(sender: 'bot'), botAccountId: 'bot').denial,
        PolicyDenial.selfMessage,
      );
    });

    test('a media-only message is not empty for policy, but has no prompt', () {
      const policy = ChannelPolicy(allowedUsers: {'u1'});
      final media = ChannelMessage(
        providerId: 'p',
        accountId: 'bot',
        conversationId: 'c1',
        conversationType: ChannelConversationKind.direct,
        senderId: 'u1',
        messageId: '2',
        segments: const [
          ChannelSegment(type: ChannelSegmentType.image, targetId: 'f'),
        ],
        receivedAt: DateTime(2026, 11, 24),
      );
      expect(policy.evaluate(media, botAccountId: 'bot').allowed, isTrue);
      expect(media.promptText, isEmpty);
    });
  });

  group('capabilities', () {
    test('an undeclared capability reads as unsupported', () {
      const profile = ChannelCapabilities({
        ChannelCapability.directMessage: CapabilitySpec(
          CapabilityStatus.native,
        ),
      });
      expect(profile.supports(ChannelCapability.directMessage), isTrue);
      expect(profile.supports(ChannelCapability.messageEdit), isFalse);
      expect(
        profile.statusOf(ChannelCapability.messageEdit),
        CapabilityStatus.unsupported,
      );
      expect(profile.unavailable.keys, contains(ChannelCapability.file));
    });

    test('extension and application count as usable, unverified does not', () {
      const profile = ChannelCapabilities({
        ChannelCapability.image: CapabilitySpec(CapabilityStatus.extension),
        ChannelCapability.longText: CapabilitySpec(
          CapabilityStatus.application,
        ),
        ChannelCapability.file: CapabilitySpec(CapabilityStatus.unverified),
      });
      expect(profile.supports(ChannelCapability.image), isTrue);
      expect(profile.supports(ChannelCapability.longText), isTrue);
      expect(profile.supports(ChannelCapability.file), isFalse);
    });

    test('a profile survives a JSON round trip', () {
      const original = ChannelCapabilities({
        ChannelCapability.directMessage: CapabilitySpec(
          CapabilityStatus.native,
          note: '需要授权',
          requiresPermission: true,
          limit: '5 分钟',
        ),
      });
      final restored = ChannelCapabilities.fromJson(original.toJson());
      final spec = restored.spec(ChannelCapability.directMessage);
      expect(spec.status, CapabilityStatus.native);
      expect(spec.note, '需要授权');
      expect(spec.requiresPermission, isTrue);
      expect(spec.limit, '5 分钟');
    });
  });

  group('inbox', () {
    test('a redelivered message is refused, a new one is admitted', () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final inbox = ChannelInbox(preferences: preferences);
      final message = ChannelMessage(
        providerId: 'p',
        accountId: 'a',
        conversationId: 'c',
        conversationType: ChannelConversationKind.direct,
        senderId: 'u',
        messageId: '42',
        text: 'hi',
        receivedAt: DateTime(2026, 11, 24),
      );

      expect(await inbox.admit(message), isTrue);
      expect(await inbox.admit(message), isFalse);
      expect(
        await inbox.admit(
          ChannelMessage(
            providerId: 'p',
            accountId: 'a',
            conversationId: 'other',
            conversationType: ChannelConversationKind.direct,
            senderId: 'u',
            messageId: '42',
            text: 'hi',
            receivedAt: DateTime(2026, 11, 24),
          ),
        ),
        isTrue,
        reason: 'the same id in another conversation is another message',
      );
    });

    test('the window survives a new inbox instance', () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final message = ChannelMessage(
        providerId: 'p',
        accountId: 'a',
        conversationId: 'c',
        conversationType: ChannelConversationKind.direct,
        senderId: 'u',
        messageId: '7',
        text: 'hi',
        receivedAt: DateTime(2026, 11, 24),
      );
      expect(
        await ChannelInbox(preferences: preferences).admit(message),
        isTrue,
      );
      expect(
        await ChannelInbox(preferences: preferences).admit(message),
        isFalse,
      );
    });

    test('the window is bounded', () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final inbox = ChannelInbox(preferences: preferences, capacity: 2);
      for (var index = 0; index < 3; index++) {
        await inbox.admit(
          ChannelMessage(
            providerId: 'p',
            accountId: 'a',
            conversationId: 'c',
            conversationType: ChannelConversationKind.direct,
            senderId: 'u',
            messageId: '$index',
            text: 'hi',
            receivedAt: DateTime(2026, 11, 24),
          ),
        );
      }
      final oldest = ChannelMessage(
        providerId: 'p',
        accountId: 'a',
        conversationId: 'c',
        conversationType: ChannelConversationKind.direct,
        senderId: 'u',
        messageId: '0',
        text: 'hi',
        receivedAt: DateTime(2026, 11, 24),
      );
      expect(await inbox.contains(oldest), isFalse);
    });
  });

  group('outbox', () {
    Future<ChannelOutbox> outbox() async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      return ChannelOutbox(preferences: preferences, maxAttempts: 2);
    }

    const address = ChannelAddress(
      providerId: 'p',
      accountId: 'a',
      conversationId: 'c',
      conversationType: ChannelConversationKind.direct,
    );

    test('planned becomes delivered on a receipt', () async {
      final queue = await outbox();
      final entry = await queue.enqueue(
        providerId: 'p',
        accountId: 'a',
        address: address,
        text: 'hi',
        purpose: DeliveryPurpose.ack,
      );
      expect(entry.status, OutboxStatus.planned);
      await queue.markSending(entry.id);
      final settled = await queue.settle(
        entry.id,
        const DeliveryReceipt.delivered(messageId: 'm-9'),
      );
      expect(settled?.status, OutboxStatus.delivered);
      expect(settled?.platformMessageId, 'm-9');
    });

    test('a retryable failure becomes deferred and then due', () async {
      final queue = await outbox();
      final entry = await queue.enqueue(
        providerId: 'p',
        accountId: 'a',
        address: address,
        text: 'hi',
        purpose: DeliveryPurpose.finalAnswer,
      );
      final settled = await queue.settle(
        entry.id,
        const DeliveryReceipt.failed('网络错误', retryable: true),
      );
      expect(settled?.status, OutboxStatus.deferred);
      expect(settled?.nextAttemptAt, isNotNull);
      expect(await queue.due('p', 'a'), isEmpty);
    });

    test('an outbox item can only be claimed by one sender', () async {
      final queue = await outbox();
      final entry = await queue.enqueue(
        providerId: 'p',
        accountId: 'a',
        address: address,
        text: 'result',
        purpose: DeliveryPurpose.finalAnswer,
      );
      final claims = await Future.wait([
        queue.markSending(entry.id),
        queue.markSending(entry.id),
      ]);
      expect(claims.whereType<OutboxEntry>(), hasLength(1));
      await queue.settle(entry.id, const DeliveryReceipt.unknown('没有确认'));
      expect(await queue.markSending(entry.id), isNull);
    });

    test('platform-requested delays stop at the attempt ceiling', () async {
      final queue = await outbox();
      final entry = await queue.enqueue(
        providerId: 'p',
        accountId: 'a',
        address: address,
        text: 'result',
        purpose: DeliveryPurpose.finalAnswer,
      );
      const limited = DeliveryReceipt.deferred('限流', retryAfter: Duration.zero);
      await queue.markSending(entry.id);
      expect(
        (await queue.settle(entry.id, limited))?.status,
        OutboxStatus.deferred,
      );
      expect(await queue.markSending(entry.id), isNotNull);
      expect(
        (await queue.settle(entry.id, limited))?.status,
        OutboxStatus.failed,
      );
      expect(await queue.markSending(entry.id), isNull);
    });

    test('a final failure stays failed and is never due again', () async {
      final queue = await outbox();
      final entry = await queue.enqueue(
        providerId: 'p',
        accountId: 'a',
        address: address,
        text: 'hi',
        purpose: DeliveryPurpose.finalAnswer,
      );
      final settled = await queue.settle(
        entry.id,
        const DeliveryReceipt.failed('参数错误'),
      );
      expect(settled?.status, OutboxStatus.failed);
      expect(await queue.due('p', 'a'), isEmpty);
    });

    test('an unknown result is recorded and never retried', () async {
      final queue = await outbox();
      final entry = await queue.enqueue(
        providerId: 'p',
        accountId: 'a',
        address: address,
        text: 'hi',
        purpose: DeliveryPurpose.finalAnswer,
      );
      final settled = await queue.settle(
        entry.id,
        const DeliveryReceipt.unknown('超时'),
      );
      expect(settled?.status, OutboxStatus.unknown);
      expect(await queue.due('p', 'a'), isEmpty);
    });

    test('retries stop at the attempt ceiling', () async {
      final queue = await outbox();
      final entry = await queue.enqueue(
        providerId: 'p',
        accountId: 'a',
        address: address,
        text: 'hi',
        purpose: DeliveryPurpose.notice,
      );
      await queue.settle(
        entry.id,
        const DeliveryReceipt.failed('again', retryable: true),
      );
      final second = await queue.settle(
        entry.id,
        const DeliveryReceipt.failed('again', retryable: true),
      );
      expect(second?.status, OutboxStatus.failed);
      expect(second?.attempts, 2);
    });

    test('the queue is bounded and clears per account', () async {
      final queue = await outbox();
      for (var index = 0; index < 90; index++) {
        await queue.enqueue(
          providerId: 'p',
          accountId: 'a',
          address: address,
          text: '$index',
          purpose: DeliveryPurpose.notice,
        );
      }
      expect(await queue.pendingFor('p', 'a'), hasLength(80));
      await queue.clear('p', 'a');
      expect(await queue.pendingFor('p', 'a'), isEmpty);
    });

    test('concurrent enqueues never lose a row', () async {
      final queue = await outbox();
      await Future.wait([
        for (var index = 0; index < 20; index++)
          queue.enqueue(
            providerId: 'p',
            accountId: 'a',
            address: address,
            text: '$index',
            purpose: DeliveryPurpose.notice,
          ),
      ]);
      final rows = await queue.pendingFor('p', 'a');
      expect(rows, hasLength(20));
      expect(rows.map((row) => row.text).toSet(), hasLength(20));
    });

    test('a deferred entry becomes due once its time arrives', () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      var now = DateTime(2026, 11, 24, 12);
      final queue = ChannelOutbox(preferences: preferences, clock: () => now);
      final entry = await queue.enqueue(
        providerId: 'p',
        accountId: 'a',
        address: address,
        text: 'hi',
        purpose: DeliveryPurpose.notice,
      );
      await queue.settle(
        entry.id,
        const DeliveryReceipt.deferred('限流', retryAfter: Duration(seconds: 30)),
      );
      expect(await queue.due('p', 'a'), isEmpty);
      now = now.add(const Duration(seconds: 31));
      expect(await queue.due('p', 'a'), hasLength(1));
    });
  });
}
