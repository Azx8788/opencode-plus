# QQ channels: official bot and personal account

OpenCode Plus offers two QQ routes that are **not** interchangeable. They use
different accounts, different protocols, different permissions and different
risk. The app keeps them in separate providers with separate configuration and
separate connection state; neither is described as a version of the other.

| | Official QQ bot | Personal QQ account |
| --- | --- | --- |
| Account | A bot created on the QQ Open Platform | A real QQ account |
| Transport | Official gateway WebSocket + HTTPS OpenAPI | OneBot 11 forward WebSocket to LLBot |
| Authorised by Tencent | Yes, within the approved scenes | No |
| Runs where | Inside the app | In LLBot, which you run yourself |
| Configuration | AppID + ClientSecret | WebSocket URL + access token + expected QQ number |
| Licence | Tencent platform terms | LLBot and its OneBot plugin are GPL-2.0 |

> Nothing here bypasses Tencent's permissions. A scene the bot has not been
> granted shows as unavailable in the app and fails at the platform, with the
> platform's own error surfaced.

## 1. Official QQ bot

### 1.1 Create and authorise the bot

1. Register at [QQ 开放平台](https://q.qq.com/) with a personal or company
   entity. The two entity types get different default permissions.
2. Create a bot and note its **AppID** and **ClientSecret**. The legacy "Token"
   authentication is deprecated; this app uses the access-token flow only.
3. In the console, enable the scenes you need:
   * **QQ 单聊 (C2C)** — private chat between a user and the bot.
   * **QQ 群** — the bot must also be added to the group.
   * **频道 / 频道私信** — separate guild permissions.
4. Sandbox bots only reach sandbox users. Use production for real use.

Permissions are granted per scene after review. A bot without C2C permission can
still connect to the gateway and receive nothing useful; the app cannot grant
that permission for you.

### 1.2 Configure the app

Settings → 消息渠道 → **QQ 官方机器人**:

| Field | Meaning |
| --- | --- |
| AppID | The numeric id from the console |
| ClientSecret | Stored in the platform keystore, exchanged for an access token |
| Sandbox | Use the sandbox API host |
| Allowed openids | Who may drive the agent; empty means nobody |
| Allowed group openids | Which groups the bot may answer in; empty means none |
| Allow private / group chat | Scene switches, independent of platform permission |
| Require @ or a command in groups | On by default |

"Test credentials" fetches a token and the gateway URL and reports success
without sending anything to a person. It cannot prove that a scene is
authorised; only a real message can.

### 1.3 How the protocol is used

* **Token**: `POST /app/getAppAccessToken` with `appId` and `clientSecret`,
  cached until 60 seconds before `expires_in`. A `401` from the OpenAPI triggers
  exactly one refresh and one retry.
* **Gateway**: `GET /gateway` → `wss://…`; `op 10` hello carries the heartbeat
  interval; `op 2` identify carries `token: "QQBot <access token>"` and the
  intents mask; `op 1` heartbeat with the last `s`; `op 11` ack; `op 6` resume
  with `session_id` and `seq`; `op 7` reconnect; `op 9` invalid session → fresh
  identify.
* **Intents**: `GROUP_AND_C2C_EVENT (1 << 25) | PUBLIC_GUILD_MESSAGES (1 << 30)`.
  Subscribing to an intent the bot lacks permission for makes the gateway close
  the connection, so the mask stays minimal.
* **Events used**: `C2C_MESSAGE_CREATE`, `GROUP_AT_MESSAGE_CREATE`,
  `AT_MESSAGE_CREATE`, `DIRECT_MESSAGE_CREATE`. Other dispatches are ignored.
* **Sending**: `POST /v2/users/{openid}/messages`,
  `POST /v2/groups/{group_openid}/messages`,
  `POST /channels/{channel_id}/messages`, with `msg_id` and an increasing
  `msg_seq` for a passive reply.

### 1.4 Passive replies, active messages and long tasks

* A passive reply must be sent **within 5 minutes** of the incoming message and
  **at most 5 times per message** (`msg_seq` 1–5).
* A long task cannot hold one reply window open. The engine sends a start notice,
  occasional progress and a final answer, and the provider **reserves the last
  reply slot for the final answer**: a progress note that would consume it is
  refused with a notice instead of silently dropped.
* When the window expires or the budget is exhausted, the send returns `failed`
  with the reason. The agent is not re-run and the message is not retried
  forever.
* Active messages (no `msg_id`) require platform approval for the scene. Without
  it the send fails; the app never fabricates a passive reply to look successful.
* Rate limits come back as `429` and are surfaced as `deferred`, retried with
  backoff.

### 1.5 Common problems

| Symptom | Cause |
| --- | --- |
| `401` / token errors | Wrong AppID or ClientSecret, or a rotated secret |
| Gateway closes right after identify | An intent the bot has no permission for |
| Connects but never receives | The scene (C2C/group) is not enabled, or the bot is not in the group |
| Send fails with a passive-reply error | Window expired (5 min) or 5 replies already used |
| Send fails with a permission error | Active message not approved for this scene |
| `403` on a group send | The bot was removed from the group, or the group permission was revoked |

## 2. Personal QQ account: LLBot + OneBot 11

This route logs a real QQ account in through a third-party implementation. It is
not authorised by Tencent, it can get an account restricted, and it is **not
bundled with the app**. You run it; you own the consequences.

### 2.1 Deploy LLBot (Linux x64, headless)

1. Prepare a Linux x64 host (a small VPS, a home server, a container). Headless
   is enough; no desktop session is needed.
2. Install LLBot by following its own documentation and start it once to log the
   QQ account in (QR scan or the method its version supports).
3. Install and enable its **OneBot 11** plugin.
4. Enable the **forward WebSocket server** (正向 WebSocket). Note the address,
   for example `ws://192.168.1.10:3001`.
5. Set an **access token** in the plugin. The app sends it as
   `Authorization: Bearer <token>`; it is never placed in the URL.
6. Keep the host reachable from the phone: same LAN, a VPN, or a `wss://` reverse
   proxy. Prefer `wss://` anywhere the network is not trusted.

Notes:

* LLBot and its OneBot 11 plugin are **GPL-2.0**. They stay separate programs;
  no code from them is copied into this repository or packaged into the APK.
* PMHQ mode is not offered: its licence and distribution boundary have not been
  verified.
* An Android/PRoot deployment of the protocol side is an experiment, not a
  supported configuration. A Linux ARM64 build existing upstream does not mean
  it runs inside this app.

### 2.2 Configure the app

Settings → 消息渠道 → **QQ 普通账号（OneBot 11）**:

| Field | Meaning |
| --- | --- |
| WebSocket address | `ws://host:port` or `wss://host/path` |
| Access token | Sent as a Bearer header |
| Expected QQ account | `self_id` the implementation must report |
| Allowed QQ numbers | Who may drive the agent; empty means nobody |
| Allowed group numbers | Which groups the bot may answer in |
| Allow private / group chat | Scene switches |
| Require @ or a command in groups | On by default |

"Test connection" opens the socket, waits for the lifecycle event, checks
`self_id`, calls `get_version_info` and disconnects. It sends no message.

A plain `ws://` address to a non-loopback host shows a warning: the token and
all messages would travel unencrypted.

### 2.3 Protocol behaviour

* **Events**: `post_type: message` with `message_type: private | group`. `at`
  segments naming the bot set `mentionsAccount`. `message_sent` is ignored so the
  bot never answers itself. Unknown `post_type` and unknown segment types are
  ignored or preserved, never fatal.
* **Sending**: `send_private_msg` / `send_group_msg` with a **structured segment
  array** (`reply` then `text`). No CQ string is ever built. Text is sent
  verbatim, including brackets that look like CQ codes.
* **Correlation**: every action carries a unique `echo`; the response is matched
  by it. `echo` is a correlation id, never a task id, and is discarded when the
  response arrives.
* **Result checking**: both `status` and `retcode` are checked. A socket that
  accepted the bytes is not a delivered message. A timeout is `unknown`, not
  success.
* **Identity**: the first lifecycle event's `self_id` must match the configured
  QQ number. A mismatch disconnects instead of answering as the wrong account.
  Events that report another `self_id` are dropped.
* **Heartbeat**: the watchdog uses the interval the implementation announces
  (three missed intervals) or the configured grace period when it announces none.

### 2.4 Common problems

| Symptom | Cause |
| --- | --- |
| Connection refused | Wrong host/port, LLBot not running, plugin's forward WS not enabled |
| `401` during upgrade | Access token mismatch, or the plugin expects a query parameter this app refuses to use |
| Connects, then "self_id 不匹配" | Another QQ account is logged in, or the expected number is wrong |
| No events, socket idle | The plugin's event filter, or the account is offline in LLBot |
| `retcode 100` on send | Malformed target id (for example a group id sent as a private message) |
| Repeated reconnects | Network change, or the host is dropping idle WebSockets |

## 3. Security notes for both routes

* Credentials live in the platform keystore, are registered for redaction and are
  never written to logs, exception text or exported configuration.
* The channel layer cannot approve a permission request. Agent approvals stay in
  the app's own UI; `/approve` from a chat is refused with an explanation.
* Group answers are only produced for allowlisted groups and allowlisted members,
  and only when addressed.
* Agent output is sent to the platform you configured. Do not drive the agent
  with material you would not send to that platform.
