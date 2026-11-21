# Telegram bot relay

The optional Telegram relay connects one private Telegram account to the
OpenCode server installed on this phone. It uses Telegram long polling from the
Android app; it is not a public bot service or a separate VPS deployment.

## Setup

1. Create a bot with [@BotFather](https://t.me/BotFather) and copy its token.
2. Get your numeric Telegram user ID from [@userinfobot](https://t.me/userinfobot).
3. In OpenCode Plus, open **Settings → Conversations → Telegram bot**.
4. Enter the bot token and your user ID, verify the token, then enable and save.
5. Open the bot's private chat and send `/start`.
6. Connect the app to its built-in OpenCode server and open a project. Opening a
   conversation binds that session for progress and replies. A Telegram text
   sent before a session is bound starts a separate conversation in the
   currently open project.

To receive messages while the app is backgrounded, enable the app's background
connection and keep Android from stopping the app. Android may still stop a
process; start the app again to resume polling. The bot token can only have one
active Telegram update receiver: remove any webhook and stop any other poller
for that bot.

## Telegram messages

- Send normal text to give the local agent an instruction.
- `/status` reports the connection and selected session state.
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

The bot accepts private-chat messages only when both the sender and private
chat IDs match the configured numeric user ID. Other senders are ignored. The
bot token is stored in Android secure storage; profile deletion removes it.
Telegram instructions are sent through the app's existing OpenCode connection
and ordinary permission policy. Agent reply text and short progress notices are
sent to Telegram, so Telegram receives that content. Do not relay information
you do not want sent to Telegram. See [PRIVACY.md](../PRIVACY.md).
