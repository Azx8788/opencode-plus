# Adding a channel provider

A new channel (Discord, Slack, Matrix, a webhook of your own) needs one provider
and one settings page. It must not need changes to the agent core, the engine,
the inbox, the outbox, the policy or the session store.

## 1. Implement the provider

```dart
class DiscordProvider extends ChannelProviderBase {
  DiscordProvider({required super.accountId, required this.token})
      : super(providerId: 'discord');

  @override
  ChannelCapabilities get capabilities => declaredCapabilities;

  static const declaredCapabilities = ChannelCapabilities({
    ChannelCapability.directMessage: CapabilitySpec(CapabilityStatus.native),
    // Declare all twelve. A missing entry reads as unsupported on purpose.
    ChannelCapability.messageEdit: CapabilitySpec(CapabilityStatus.unverified),
  });

  @override
  Future<void> connect() async { /* one socket, generation-guarded */ }

  @override
  Future<void> disconnect() async { /* stop timers, close the socket */ }

  @override
  Future<DeliveryReceipt> send(
    RenderedChannelMessage message,
    DeliveryContext context,
  ) async { /* return what the platform actually confirmed */ }
}
```

Requirements that are checked in review, not just in prose:

1. **One connection per instance.** Guard reconnects with a generation counter so
   a config change cannot resurrect an old loop.
2. **Never emit after close.** Use `emitMessage` / `publishStatus` from the base;
   they are no-ops once the stream is closed.
3. **Back off.** No tight reconnect loop; cap the delay and add jitter.
4. **Normalise at the boundary.** Platform JSON stops here. External ids become
   strings; unknown segments are preserved as `ChannelSegmentType.unknown`.
5. **Receipts are honest.** `delivered` only with a platform confirmation;
   `unknown` when the ack was lost; `deferred` only when a retry can work.
6. **No agent logic.** No prompts, no sessions, no approvals, no "if the user
   says X then do Y". That belongs to the engine.
7. **No secrets in logs, URLs or exceptions.** Register every secret with
   `KitRedact.registerKnownSecret` and send tokens in headers.
8. **Declare capabilities truthfully.** `unverified` is the right answer for a
   documented feature this build has not proven against a real account.

## 2. Register it

1. Add the id to `ChannelProviderIds` (with its label).
2. Add a typed config to `channel_config.dart` (secrets in secure storage,
   allowlists, scene switches) and a load/save/clear trio to `ChannelConfigStore`.
3. Add the channel to `ChannelHub`: build the provider, build the engine with
   `_buildEngine`, connect on enable, tear down on disable and on clear.
4. Add the conversation key shape. If the platform has threads, pass `threadId`;
   otherwise leave it null.

The engine is already parameterised by:

```dart
ChannelConversationEngine(
  provider: provider,
  policy: config.policy,           // allowlists, mention rule
  agent: agentPort,                // the app's prompt path
  inbox: inbox,                    // shared, scoped per account
  outbox: outbox,                  // shared, scoped per account
  conversationKeyOf: (message) => ConversationKey(...),
  workspaceId: profileId,
  directory: () => directory,
  workspace: () => workspace,
  agentReady: () => isConnected,
)
```

## 3. Settings page

Reuse the pattern in `lib/ui/screens/settings/channels_screen.dart`:

* a row in the 消息渠道 hub with the channel's state,
* a page with credentials, allowlists, scene switches, enable, test, remove,
* the capability table with the provider's own notes,
* a note stating what the platform requires and what the user must run.

Add the row id to `settingsGroupRowIds` and a `SearchEntry` in
`lib/ui/search/search_index/hub_rows.dart`, plus the two ARB strings.

## 4. Tests

Copy the shape of the existing suites:

| Test | What it must prove |
| --- | --- |
| `*_provider_test.dart` | Connect, auth failure, event normalisation, send + receipt, error codes, reconnect, unknown event tolerance |
| `channel_engine_test.dart` | Nothing new is needed — the engine is shared. Add a case only for a policy shape the new channel introduces |
| `channel_config_test.dart` | Validation, secrets not in preferences, clear removes both halves |

Use a local mock server (HTTP + WebSocket upgrade on loopback). Never test
against a real account in CI, and never write a test that needs a token.

## 5. Documentation

Update `docs/CHANNELS.md` (the code table and the capability table),
`docs/CHANNELS_SETUP.md` (the user steps) and `docs/CHANNELS_LIMITATIONS.md`
(what is unverified). If the channel needs a third-party component, say who runs
it, under which licence, and that it is not bundled.

## Checklist

- [ ] `providerId` is stable and stored in session keys.
- [ ] All twelve capabilities declared, with notes where they are conditional.
- [ ] Secrets in secure storage, registered for redaction.
- [ ] One socket, generation-guarded, backoff on failure.
- [ ] Receipts reflect the platform's answer, not the socket's.
- [ ] Allowlists fail closed.
- [ ] Settings page with state, test, remove and the capability table.
- [ ] Tests pass with `flutter test`, and `flutter analyze` is clean.
