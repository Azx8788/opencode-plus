# Multi-channel architecture

OpenCode Plus can be driven from Telegram, from an official QQ bot, and from a
personal QQ account through OneBot 11. All three share one pipeline: a channel
turns platform events into a neutral message, the pipeline decides who may talk,
which conversation and session it belongs to, runs the agent, and sends the
answer back through the channel it came from.

The agent core knows nothing about Telegram, QQ, OneBot or WebSockets. Adding a
fourth channel means writing one provider and one settings page.

## Pipeline

```
Telegram provider ────────┐
Official QQ provider ─────┼── ChannelProvider (transport + normalisation)
OneBot 11 provider ───────┘             │
                                        ▼
                            ChannelConversationEngine
                             ├─ ChannelPolicy        (who may talk)
                             ├─ ChannelInbox         (de-duplication)
                             ├─ conversation key     (which session)
                             ├─ ChannelTask          (new / supplement / queue)
                             ├─ ChannelAgentPort     (the app's prompt path)
                             └─ ChannelOutbox        (durable, retried sends)
                                        │
                                        ▼
                            ChannelProvider.send → original conversation
```

Everything above the provider is channel-neutral. Everything below the engine is
platform-specific and cannot leak upward: OneBot JSON, QQ payloads and Telegram
updates stop at the adapter.

## Where the code lives

| Path | Responsibility |
| --- | --- |
| `lib/channels/channel_message.dart` | Neutral message, segments, outbound address |
| `lib/channels/channel_capabilities.dart` | Capability statuses and profile |
| `lib/channels/channel_provider.dart` | Provider contract, events, receipts, status |
| `lib/channels/channel_identity.dart` | `ActorKey`, `ConversationKey`, policy |
| `lib/channels/channel_text.dart` | Chunking, command parsing, fingerprints, redaction |
| `lib/channels/channel_inbox.dart` | Durable de-duplication window |
| `lib/channels/channel_outbox.dart` | Durable send queue and its state machine |
| `lib/channels/channel_sessions.dart` | Conversation → agent session bindings |
| `lib/channels/channel_agent_port.dart` | The only door to the agent |
| `lib/channels/channel_engine.dart` | The shared pipeline |
| `lib/channels/channel_config.dart` | Typed configuration, secrets in secure storage |
| `lib/channels/channel_hub.dart` | Lifecycle of the two QQ channels |
| `lib/channels/providers/*` | Telegram, official QQ, OneBot 11 |
| `lib/telegram/telegram_bot.dart` | The Telegram relay's facade over provider + engine |

## Provider contract

```dart
abstract interface class ChannelProvider {
  String get providerId;      // 'telegram' | 'qq-official' | 'onebot11'
  String get accountId;       // the bot account, never shared between instances
  ChannelCapabilities get capabilities;
  ProviderStatus get status;
  Stream<ProviderEvent> get events;   // status, inbound message, notice
  Future<void> connect();
  Future<void> disconnect();
  Future<DeliveryReceipt> send(RenderedChannelMessage message, DeliveryContext context);
  Future<void> dispose();
}
```

`ChannelProviderBase` supplies the one broadcast stream, the status history and
the guard that refuses to emit after close. A provider that cannot say what it
can do, or that reports success without a receipt, is a bug: see
[CHANNELS_LIMITATIONS.md](CHANNELS_LIMITATIONS.md).

### Receipts

`DeliveryReceipt` has five outcomes, and they are not interchangeable:

| Receipt | Meaning | What the outbox does |
| --- | --- | --- |
| `delivered` | The platform confirmed the message | terminal |
| `accepted` | Queued by the platform, not yet confirmed | terminal, recorded as delivered |
| `deferred` | Rate limit or a closed reply window | retried with backoff |
| `failed` | Definitely not sent | terminal unless `retryable` |
| `unknown` | May have been delivered; the ack was lost | terminal, **never retried** |

## Message model

`ChannelMessage` carries `providerId`, `accountId`, `conversationId`,
`conversationType`, `senderId`, `messageId`, `text`, `segments`,
`replyToMessageId`, `receivedAt` and `extensions`.

* External ids are strings. Telegram chat ids, QQ openids and QQ numbers are not
  numbers this app may assume anything about.
* `extensions` is adapter-owned. It exists for things the transport needs to
  answer at all (the QQ passive `msg_id`, the OneBot `group_id`); it is never
  passed to the agent as context.
* Segments are typed (`text`, `mention`, `image`, `file`, `voice`, `reply`,
  `face`, `unknown`). Unknown segments are preserved, not dropped, so a new
  segment type from an implementation cannot make a message disappear.

## Capabilities

Every provider declares all twelve capabilities; a missing entry reads as
`unsupported`. Statuses are `native`, `extension`, `application`, `unsupported`
and `unverified`. `unverified` is deliberately *not* usable: a documented
feature that this build has not proven against a real account must not be
presented as working.

The settings pages render the full table with each provider's own wording, so
"why can't it send an image?" is answerable without reading code.

## Identity and policy

```
ActorKey      = (channel, accountId, externalUserId)
ConversationKey = (workspaceId, providerId, accountId,
                   conversationType, conversationId, ownerActorId, threadId?)
```

* Nicknames never take part. Two people called "Alex" are two actors.
* An official QQ `openid` is not a QQ number. The same person on Telegram and on
  QQ is two actors until they explicitly link accounts — which this version does
  not implement, on purpose.
* `ownerActorId` is part of the conversation key: in a group, each member's
  conversation with the bot is separate, with its own session.
* Every key component is percent-escaped, so an id containing `:` cannot forge a
  different conversation.

`ChannelPolicy` is fail-closed: an empty allowlist admits nobody. It checks, in
order, that the sender is not the bot itself, that the message has something an
agent can act on, that the conversation type is enabled, that the user is
allowlisted, that the group is allowlisted, and — in groups — that the message
addresses the bot by mention or command prefix.

## Task lifecycle

One independent request is one main task (`ChannelTask`). The rules:

1. A message while idle starts a new main task.
2. A message while running is a **supplement** to the current task: it is sent to
   the same session, where OpenCode steers the running turn.
3. `/queue <text>` while running stores the request and starts it as a new main
   task when the current one finishes.
4. `/stop` interrupts the bound session and clears the queue.
5. Permission and question prompts are announced into the conversation, bound to
   the task and the session. They are **never** approved from a channel: the
   channel layer has no method that can. `/approve` is answered with an
   explanation, not an approval.

The completion path reads the last finished assistant text, sends it once, and
deduplicates by text so a repeated idle event cannot repeat the answer.

## Inbox and outbox

**Inbox.** Key = account + conversation + external message id. Platforms without
a stable id fall back to a fingerprint scoped to conversation, sender and a
30-second bucket; the guarantee ends at the bucket boundary and is documented
rather than sold as exactly-once. The window is bounded (400 keys per account) and
persisted in preferences, so a redelivery after a restart is still caught.

**Outbox.** Entries are persisted (80 per install), carry the provider, account,
address, task id, purpose and attempt count, and move through
`planned → sending → delivered | deferred | failed | unknown`. Retries use
quadratic backoff, stop at three attempts, and never run the agent again. A send
failure is a message failure, not a task failure.

## Lifecycle and failure isolation

* Each provider owns exactly one socket and one poll loop, guarded by a
  generation counter: a reconnect after a config change cannot resurrect the old
  loop, and a closed stream is never written to.
* Reconnects back off (1 s, 2 s, 4 s … capped at 60 s, with jitter). No channel
  reconnects in a tight loop.
* One channel's failure cannot stop another: separate providers, separate
  engines, separate subscriptions, and the hub catches per-engine exceptions.
* Deleting a configuration closes its socket, clears its inbox and outbox rows
  and removes its secret.
* Android may stop background work. This is not a permanent server, and the app
  does not claim to be one.

## Relationship to the Telegram relay

The Telegram relay shipped first and keeps its preferences keys, its settings
page and its single-owner-chat behaviour. It now runs on the same engine and the
same provider contract: `TelegramBotBridge` is a facade over
`TelegramProvider` + `ChannelConversationEngine`, and its regression suite is
unchanged. Telegram's one conversation is a deliberate product decision, not an
architectural limit: `ChannelConversationEngine` already supports per-chat
sessions, which is what QQ uses.
