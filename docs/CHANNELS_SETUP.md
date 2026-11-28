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
  └── QQ 普通账号（OneBot 11）      (self-managed SnowLuma, NapCat or LLBot)
```

## Telegram

Settings → 消息渠道 → **Telegram**, or the older Settings → Conversations →
Telegram bot entry. Both open the same page.

1. Create a bot with [@BotFather](https://t.me/BotFather) and copy the token.
2. Paste the token and choose **Pair automatically → Open Telegram**.
3. In Telegram, tap **Start** if prompted, then return to the app. The one-time
   link expires in three minutes. A successful pairing enables the relay.
4. Alternatively, choose **Bind by username or numeric ID**. Enter your own
   `@username`, save and enable the relay, then send `/start` in the bot's
   private chat. The relay saves the numeric ID on the first new matching
   message. You can also enter the ID directly; existing ID-only bindings
   do not need to be paired again.

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

For a new connection, use **SnowLuma → SnowLuma 配置指南**. Run your own
SnowLuma with desktop QQ, then connect the account's OneBot WebSocket. The app can
verify manually downloaded ARM64 archives and check the default local ports,
but it does not install or start SnowLuma. See [SnowLuma setup](SNOWLUMA_SETUP.md).

**Legacy LLBot** is still available when selected, or from the Linux manager.
The upstream site has closed new registrations. This path requires an existing
valid LLBot Auth Token and does not migrate any saved connection.

1. On Android ARM64 with built-in Ubuntu installed, choose **管理本机 LLBot**
   and press **一键部署并启动**. The app downloads the official LLBot v8.3.2
   ARM64 runtime (about 89 MB, Node included), verifies it, installs it (about
   172 MB), prepares random local credentials and starts the console.
2. Copy the generated WebUI password on that page and open the embedded WebUI.
   Enter your existing upstream **LLBot Auth Token** in the WebUI, then scan
   the QQ QR code.
3. Choose **使用本机连接** to return `ws://127.0.0.1:3001/` and the generated
   OneBot access token to the form. The listener starts after QQ login; a ready
   WebUI alone does not mean QQ is online. Confirm the QQ account number.
4. Review the allowed QQ and group numbers. Import preserves existing allowlists;
   empty means nobody. Import only edits the draft and leaves its relay disabled.
5. Test connection, then explicitly enable and save. Until Save, the stored
   endpoint and credentials remain unchanged.

The deployment page supports progress, failure/retry, refresh, stop and start.
Leaving it does not cancel the shared deployment operation while the app's
environment stays running. The same management page is also available under
This phone → Linux environment manager. Open it from the QQ form when you want
to import its connection.

Manual/remote LLBot, NapCat and SnowLuma are still supported: run the service,
log the QQ account in, configure OneBot 11 and its access token, then enter the
forward address or select the reverse listener. Prefer `wss://` or a private
network for remote endpoints. Managed local WebUI and OneBot listen only on
loopback; Android may stop their processes.

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
    may suspend the app in the background; your OneBot service must be running.

Messages that could not be sent are kept in the outbox and retried a few times.
They are never used as a reason to run the agent again — a delivery failure is
not a task failure.
