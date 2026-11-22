# Telegram bot relay

The optional Telegram relay connects one private Telegram account to the
OpenCode server installed on this phone. It uses Telegram long polling from the
Android app; it is not a public bot service or a separate VPS deployment.

## Setup

1. Create a bot with [@BotFather](https://t.me/BotFather) and copy its token.
2. Find **your own account's `@username`** in Telegram settings (recommended).
   This is not your display name or the bot's username. A numeric user ID is
   optional: leave it blank when using a username, or use an ID alone if your
   account has no username (for example, get it from
   [@userinfobot](https://t.me/userinfobot)).
3. Connect OpenCode Plus to its built-in OpenCode server, open a project, then
   open **Settings → Conversations → Telegram bot**.
4. Enter the bot token and your username, verify the token, then enable and
   save. A leading `@` is optional and usernames are matched case-insensitively.
5. From that Telegram account, open the bot's private chat and send `/start`.
   The first matching private message automatically binds the account's stable
   numeric ID. Telegram does not let a bot write first, and the Bot API cannot
   look up an ordinary private user by username, so verification without an ID
   checks the token and asks you to complete this step. No agent progress is
   sent to a username-only account until it is bound.
6. Opening a conversation binds that OpenCode session for progress and replies.
   A Telegram text sent before a session is bound starts a separate conversation
   in the currently open project.

If both username and optional ID are filled in, both must match the same account
on first contact. Existing ID-only configurations continue to work unchanged.

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
- `/start` and `/help` show a short usage message. Other text, including other
  slash commands, is sent to the agent as a prompt.
- The bot reports that work started, occasionally names a running tool, and
  sends the final assistant text when the turn completes. If the agent is
  waiting for a permission or question response, the bot asks you to handle it
  in the app. It never auto-approves agent requests.

Only plain text is accepted inbound in this first version. Photos, files,
voice notes, inline keyboards and remote permission approval are not supported.

## Security and privacy

The bot accepts only human senders in private chats whose sender and chat IDs
match. With a username, the first message must match the configured username
and any optional ID; its numeric ID is saved before an instruction is forwarded.
After binding, only that stable ID is authorized, even if the account changes
or removes its username. Another account acquiring the old username is not
authorized. Editing the configured username or optional ID clears the binding
and requires a new match. ID-only setups check the configured ID directly.
Other senders are ignored. The bot token is stored in Android secure storage;
profile deletion removes it and the saved identity and binding.
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
that agent progress and the finished reply come back to Telegram. They also
cover username-only setup, case-insensitive matching, automatic ID binding,
restoring a binding after restart, username changes and takeover rejection,
optional-ID constraints, identity edits, verification before binding, and
removal of the stored identity and binding. Storage-refusal and in-flight-write
tests verify instructions are not forwarded without a saved binding and an old
binding cannot overwrite edited settings; server profiles keep bindings separate.
