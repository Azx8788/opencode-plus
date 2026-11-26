# Setting up message channels

This page is the user-facing walkthrough. For the design behind it, read
[CHANNELS.md](CHANNELS.md); for QQ-specific details, [QQ_CHANNELS.md](QQ_CHANNELS.md).

## Before you start

1. Connect OpenCode Plus to the OpenCode server on this phone.
2. Open a project folder. A channel message with no project open is refused with
   an explanation instead of being silently dropped.
3. Settings → 消息渠道 lists the three channels and their state.

```
消息渠道
  ├── Telegram                    (official Bot API, long polling)
  ├── QQ 官方机器人                (Tencent Open Platform)
  └── QQ 普通账号（OneBot 11）      (LLBot you run yourself)
```

## Telegram

Settings → 消息渠道 → **Telegram**, or the older Settings → Conversations →
Telegram bot entry. Both open the same page.

1. Create a bot with [@BotFather](https://t.me/BotFather) and copy the token.
2. Get your numeric user id from [@userinfobot](https://t.me/userinfobot).
3. Open the bot's private chat and send `/start` — Telegram does not let a bot
   write first.
4. Paste the token and the id, verify, then enable and save.

The relay removes any webhook and publishes the command menu when it starts, so a
leftover webhook cannot leave it "connected but deaf".

## QQ official bot

Settings → 消息渠道 → **QQ 官方机器人**.

1. Create the bot on the [QQ 开放平台](https://q.qq.com/) and copy the AppID and
   ClientSecret.
2. Ask the console for the scenes you need (C2C, group, channel) and add the bot
   to the group.
3. Paste the AppID, paste the secret, choose sandbox only for sandbox testing.
4. Fill the allowlists: your `openid` for private chat, the `group_openid`s for
   groups. Empty means nobody can drive the agent.
5. Test credentials, then enable and save.

The page lists every capability with the platform's conditions. A scene without
permission shows as unavailable rather than failing quietly.

## QQ personal account (OneBot 11)

Settings → 消息渠道 → **QQ 普通账号（OneBot 11）**.

1. Run LLBot on a Linux x64 machine and log the QQ account in.
2. Enable its OneBot 11 plugin's **forward WebSocket** server and set an access
   token.
3. Enter the `ws://host:port` address, the token, and the QQ number it logs in.
4. Fill the allowlists (QQ numbers and group numbers). Empty means nobody.
5. Test connection, then enable and save.

The app connects out to LLBot; nothing listens on the phone. Prefer `wss://` or a
private network — a plain `ws://` address to a remote host shows a warning
because the token would travel unencrypted.

## Talking to the agent

The same commands work on all three channels:

| Command | Effect |
| --- | --- |
| any text | Sent to the agent as a prompt |
| `/status` | Agent connection, project, bound session, channel state |
| `/stop` | Interrupt the bound session and clear the queue |
| `/new` | The next prompt starts a new session |
| `/queue <text>` | Run `<text>` as a new task after the current one |
| `/help`, `/start` | Short usage message |

Rules that hold on every channel:

* A message while the agent is running is a **supplement** to the current task.
* Only `/queue` creates the next task.
* The agent's start notice, occasional progress and final answer come back to the
  conversation the request came from.
* A permission prompt is announced with "handle it in the app". The app never
  approves anything on your behalf from a chat.
* In groups the bot answers only when addressed (`@bot` or a command) and only
  for allowlisted groups and members. Each member gets a separate session, and
  nobody sees another member's context.

## When something does not arrive

1. Check the channel's state on its page: 在线 / 连接中 / 重连中 / 异常.
2. Read the error line. Each one names the next action: token, permission,
   address, or platform window.
3. Press "Test" — it verifies credentials and reachability without sending a
   message.
4. Remember the boundaries: a passive QQ reply expires after 5 minutes; Android
   may suspend the app in the background; LLBot must be running.

Messages that could not be sent are kept in the outbox and retried a few times.
They are never used as a reason to run the agent again — a delivery failure is
not a task failure.
