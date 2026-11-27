# Telegram bot relay

The optional Telegram relay connects one private Telegram account to the
OpenCode server installed on this phone. It uses Telegram long polling from the
Android app; it is not a public bot service or a separate VPS deployment.

Since the multi-channel work it is one of three channels and runs on the shared
engine described in [CHANNELS.md](CHANNELS.md): this page keeps its product
behaviour, while transport, de-duplication, task lifecycle and delivery live in
`lib/channels/`. Its settings page is still reachable on its own, and also from
**Settings → 消息渠道 → Telegram**.

## Setup

1. Create a bot with [@BotFather](https://t.me/BotFather) and copy its token.
2. In OpenCode Plus, open **Settings → Conversations → Telegram bot**. Paste
   the token and choose **Pair automatically → Open Telegram**.
3. In Telegram, tap **Start** if prompted, then return to the app. The link
   contains an eight-character random code, not the bot token. It can be used
   once, expires in three minutes and only works in a private chat. Don't share it.
4. On success the app saves the stable numeric ID and enables the relay. No
   second bot or manual ID lookup is needed. If the bot already has a webhook
   or another poller, stop that receiver before pairing; pairing itself never
   removes a webhook. Existing bindings stay valid. To rebind an enabled bot,
    disable it and save first.
5. Connect the app to its built-in OpenCode server and open a project. Opening a
   conversation binds that session for progress and replies. A Telegram text
   sent before a session is bound starts a separate conversation in the
    currently open project.

### Bind by username or numeric ID

Instead of opening the pairing link, choose **Bind by username or numeric ID**.
Enter your account's `@username` (not the bot's name), save and enable the relay,
then send `/start` from that account in the bot's private chat. The first new
matching private text binds its numeric ID. If you also enter an ID, both must
match before binding, and no prompts or replies are relayed before the binding
is saved. You may leave the username blank and use a numeric ID alone. Existing
numeric-ID configurations need no setup changes.

Enabling the relay claims the bot for long polling: it removes any webhook and
publishes the command menu (`/status`, `/stop`, `/new`, `/help`) so the bot is
not left "connected but deaf" by an earlier setup. Only one receiver can poll a
bot token; if another program keeps polling it, Telegram answers `409` and the
settings page shows that as a conflict instead of a healthy state.

To receive messages while the app is backgrounded, enable the app's background
connection and keep Android from stopping the app. Android may still stop a
process; start the app again to resume polling.

## Telegram messages

- Send normal text to give the local agent an instruction.
- `/status` reports the connection, the project, the bound session, the poll
  state, and the last transport error when there is one.
- `/stop` requests interruption of the bound session. It does not undo actions
  already completed.
- `/new` binds the next Telegram prompt to a new session; it does not cancel an
  existing task.
- `/queue <text>` runs `<text>` as a new task after the current one finishes. A
  plain message during a run is a supplement to the current task instead.
- `/start` and `/help` show a short usage message. Other text, including other
  slash commands, is sent to the agent as a prompt.
- The bot reports that work started, occasionally names a running tool, and
  sends the final assistant text when the turn completes. If the agent is
  waiting for a permission or question response, the bot asks you to handle it
  in the app. It never auto-approves agent requests.

The reply uses the session that ran the task, even if you open another chat or
use `/new` before it finishes. If the app is still running but misses a completion
event, it can recover an unambiguous result from the server transcript without
sending the task again. It cannot reconstruct an in-flight turn after Android
kills the app. If Telegram does not acknowledge a send, the app records the
delivery as unknown rather than sending it again. See **Message channels →
Manager agent → Channel task records** for execution and delivery status.

Only plain text is accepted inbound in this first version. Photos, files,
voice notes, inline keyboards and remote permission approval are not supported.

## Security and privacy

After binding, both sender and private chat IDs must match the saved numeric
ID. Changing or removing the Telegram username does not revoke that account;
another account acquiring the old name does not gain access. Groups and bots
cannot bind or reach the relay. The bot token is stored in Android secure
storage; profile deletion removes it and the local identity settings.
Telegram instructions are sent through the app's existing OpenCode connection
and ordinary permission policy. Agent reply text and short progress notices are
sent to Telegram, so Telegram receives that content. Do not relay information
you do not want sent to Telegram. See [PRIVACY.md](../PRIVACY.md).

## Tests

`test/telegram_bot_contract_test.dart` covers the allowlist and message
chunking. `test/telegram_bot_relay_test.dart` runs the shipping bridge against a
local stand-in for the Bot API: it asserts the webhook is cleared and the menu
published before the first poll, that a plain message reaches the agent and
binds its session, that `/status`, `/stop` and `/new` answer correctly, that a
foreign account is ignored, that a `409` is reported rather than hidden, and
that agent progress and the finished reply come back to Telegram. It also
exercises automatic binding (wrong code, group, bot, expired/cancelled), username
binding (optional ID, old settings, storage refusal and in-flight reconfiguration),
fast completion before the submit receipt, rebinding, reconnect and lost delivery
acknowledgements. `test/channels/api2_channel_replies_test.dart` checks the
OpenCode 2 transcript fallback against a local HTTP server. These are not
real Telegram-account tests.
