import 'dart:async';

import 'package:opencode_mobile/channels/channel_agent_port.dart';
import 'package:opencode_mobile/channels/channel_capabilities.dart';
import 'package:opencode_mobile/channels/channel_engine.dart';
import 'package:opencode_mobile/channels/channel_identity.dart';
import 'package:opencode_mobile/channels/channel_inbox.dart';
import 'package:opencode_mobile/channels/channel_message.dart';
import 'package:opencode_mobile/channels/channel_outbox.dart';
import 'package:opencode_mobile/channels/channel_provider.dart';
import 'package:opencode_mobile/channels/channel_sessions.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A provider that records what it was asked to send and lets a test push
/// inbound messages and status changes through the real event stream.
class FakeChannelProvider extends ChannelProviderBase {
  FakeChannelProvider({
    super.providerId = 'fake',
    super.accountId = 'bot-1',
    this.failSends = false,
    this.receipt = const DeliveryReceipt.delivered(messageId: 'sent-1'),
  });

  /// Messages the platform accepted.
  final List<RenderedChannelMessage> sent = [];

  /// Every send attempt, including the ones that failed.
  final List<RenderedChannelMessage> attempts = [];
  final List<DeliveryContext> contexts = [];
  bool failSends;
  DeliveryReceipt receipt;
  int connects = 0;
  int disconnects = 0;

  static const declaredCapabilities = ChannelCapabilities({
    ChannelCapability.directMessage: CapabilitySpec(CapabilityStatus.native),
    ChannelCapability.groupMessage: CapabilitySpec(CapabilityStatus.native),
    ChannelCapability.passiveReply: CapabilitySpec(CapabilityStatus.native),
    ChannelCapability.longText: CapabilitySpec(
      CapabilityStatus.application,
      limit: '3500',
    ),
  });

  @override
  ChannelCapabilities get capabilities => declaredCapabilities;

  @override
  Future<void> connect() async {
    connects++;
    publishStatus(ProviderState.online);
  }

  @override
  Future<void> disconnect() async {
    disconnects++;
    publishStatus(ProviderState.disabled);
  }

  @override
  Future<DeliveryReceipt> send(
    RenderedChannelMessage message,
    DeliveryContext context,
  ) async {
    attempts.add(message);
    contexts.add(context);
    if (failSends) return DeliveryReceipt.failed('模拟发送失败');
    sent.add(message);
    return receipt;
  }

  void deliver(ChannelMessage message) => emitMessage(message);

  void goOnline() => publishStatus(ProviderState.online);

  void goOffline(String reason) =>
      publishStatus(ProviderState.reconnecting, lastError: reason);

  void notify(String text) => emitNotice(text);
}

class FakeAgentPort extends ChannelAgentPort {
  final List<ChannelPromptRequest> prompts = [];
  final List<String> stopped = [];
  String nextSession = 'ses-1';
  String? reply = '完成。';
  bool busy = false;
  Object? sendError;
  String Function(ChannelPromptRequest request)? sessionFor;
  String status = '本机 OpenCode 已连接。';
  int latestReplyCalls = 0;

  @override
  Future<String> sendPrompt(ChannelPromptRequest request) async {
    if (sendError != null) throw sendError!;
    prompts.add(request);
    return sessionFor?.call(request) ?? nextSession;
  }

  @override
  Future<void> stopTask(String? sessionID) async {
    stopped.add(sessionID ?? '');
    busy = false;
  }

  @override
  Future<String?> latestReply(String sessionID) async {
    latestReplyCalls++;
    return reply;
  }

  @override
  String statusText() => status;

  @override
  bool isBusy(String sessionID) => busy;
}

class EngineHarness {
  EngineHarness({
    required this.provider,
    required this.agent,
    required this.engine,
    required this.preferences,
  });

  final FakeChannelProvider provider;
  final FakeAgentPort agent;
  final ChannelConversationEngine engine;
  final SharedPreferences preferences;

  static Future<EngineHarness> start({
    ChannelPolicy? policy,
    bool agentReady = true,
    String directory = '/home/owner/projects/demo',
    String workspace = '',
    bool singleConversation = false,
    ChannelEngineCopy copy = const ChannelEngineCopy(),
    Duration progressInterval = const Duration(seconds: 25),
    String providerId = 'fake',
    SharedPreferences? sharedPreferences,
    ChannelInbox? sharedInbox,
    ChannelOutbox? sharedOutbox,
  }) async {
    if (sharedPreferences == null) {
      SharedPreferences.setMockInitialValues({});
    }
    final preferences =
        sharedPreferences ?? await SharedPreferences.getInstance();
    final provider = FakeChannelProvider(providerId: providerId);
    final agent = FakeAgentPort();
    final inbox = sharedInbox ?? ChannelInbox(preferences: preferences);
    final outbox = sharedOutbox ?? ChannelOutbox(preferences: preferences);
    final key = ConversationKey(
      workspaceId: 'profile-1',
      providerId: provider.providerId,
      accountId: provider.accountId,
      conversationType: ChannelConversationKind.direct,
      conversationId: 'dm-1',
      ownerActorId: 'u1',
    );
    final engine = ChannelConversationEngine(
      provider: provider,
      policy:
          policy ??
          const ChannelPolicy(
            allowedUsers: {'u1', 'u2'},
            allowedGroups: {'g1', 'g2'},
          ),
      agent: agent,
      inbox: inbox,
      outbox: outbox,
      conversationKeyOf: singleConversation
          ? (_) => key
          : (message) => ConversationKey(
              workspaceId: 'profile-1',
              providerId: provider.providerId,
              accountId: provider.accountId,
              conversationType: message.conversationType,
              conversationId: message.conversationId,
              ownerActorId: message.senderId,
            ),
      primaryConversation: singleConversation ? key : null,
      workspaceId: 'profile-1',
      directory: () => directory,
      workspace: () => workspace,
      agentReady: () => agentReady,
      copy: copy,
      progressInterval: progressInterval,
      adoptViewedSession: singleConversation,
    );
    engine.useSessionStores(
      (conversation) => PrefsChannelSessionStore(
        preferences: preferences,
        conversationKey: conversation.value,
      ),
    );
    await engine.start();
    provider.goOnline();
    return EngineHarness(
      provider: provider,
      agent: agent,
      engine: engine,
      preferences: preferences,
    );
  }

  Future<void> stop() => engine.shutdown();
}

ChannelMessage directMessage(
  String text, {
  String sender = 'u1',
  String conversation = 'dm-1',
  String id = 'm-1',
  String providerId = 'fake',
}) => ChannelMessage(
  providerId: providerId,
  accountId: 'bot-1',
  conversationId: conversation,
  conversationType: ChannelConversationKind.direct,
  senderId: sender,
  messageId: id,
  text: text,
  segments: [ChannelSegment.text(text)],
  receivedAt: DateTime(2026, 11, 24, 12),
);

ChannelMessage groupMessage(
  String text, {
  String sender = 'u1',
  String group = 'g1',
  String id = 'gm-1',
  bool mentions = true,
  String providerId = 'fake',
}) => ChannelMessage(
  providerId: providerId,
  accountId: 'bot-1',
  conversationId: group,
  conversationType: ChannelConversationKind.group,
  senderId: sender,
  messageId: id,
  text: text,
  segments: [
    if (mentions) const ChannelSegment.mention('bot-1'),
    ChannelSegment.text(text),
  ],
  mentionsAccount: mentions,
  receivedAt: DateTime(2026, 11, 24, 12),
);

Future<void> waitFor(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
  String? reason,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  throw StateError('Timed out waiting for ${reason ?? 'condition'}');
}
