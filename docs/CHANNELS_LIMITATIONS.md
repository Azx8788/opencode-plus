# Channel limitations and verification status

This page separates three things that are easy to confuse:

* **Implemented** — the code exists and its automated tests pass.
* **Verified in a real environment** — it was run against the real platform with
  a real account.
* **Blocked** — it needs something only you can provide (a platform approval, a
  QQ account, a host running LLBot).

The honest summary: the code and its protocol tests are complete; the two QQ
routes have **not** been verified against real accounts, because that needs
credentials and approvals this repository does not have.

## Verification matrix

| Area | Implemented | Automated tests | Real platform |
| --- | --- | --- | --- |
| Channel engine (routing, tasks, policy, dedupe, outbox) | Yes | Yes (87 channel tests) | n/a |
| Telegram automatic private-chat pairing and final reply recovery | Yes | Local Bot API and OpenCode v2 wire/HTTP regressions | **Not verified** for these changes against a real Telegram account on Android |
| Official QQ: token, gateway, identify, heartbeat, resume | Yes | Yes, against a local fake gateway | **Not verified** — needs AppID/Secret and scene approval |
| Official QQ: C2C / group / channel message parsing | Yes | Yes | **Not verified** — needs a real bot |
| Official QQ: passive reply window and 5-reply budget | Yes | Yes (fake clock) | **Not verified** |
| Official QQ: active messages, images, files | Declared, not sent | Capability table only | **Blocked** — platform approval required |
| OneBot 11: connect, auth header, lifecycle, self_id check | Yes | Yes, against a local fake server | **Not verified** — needs LLBot + QQ account |
| OneBot 11: private/group events, at/reply segments | Yes | Yes | **Not verified** |
| OneBot 11: send with echo correlation and retcode checks | Yes | Yes | **Not verified** |
| OneBot 11: heartbeat watchdog and reconnect | Yes | Yes | **Not verified** |
| Android/PRoot hosting of a protocol side | No | n/a | **Blocked** — experimental, unsupported |

## Platform limits the app cannot lift

**Official QQ bot**

* C2C, group, channel and channel DM are separate console permissions. Without
  them the bot connects and receives nothing, or the send is refused.
* A passive reply is valid for 5 minutes and at most 5 times per message. A long
  task cannot keep one window open; the app reserves the last slot for the final
  answer and says so when it drops a progress note.
* Active messages, images, files and voice need approvals this app cannot
  request on your behalf. They show as `unverified` or `extension`, never as
  working.
* Personal and company entities get different default permissions.
* Rate limits apply per bot and per scene; a `429` is surfaced and retried, not
  hidden.

**Personal QQ account**

* The route depends on LLBot, which is GPL-2.0, runs outside this app, and is not
  authorised by Tencent. Account risk is yours.
* PMHQ mode is not offered: its licence and distribution boundary are unverified.
* Android/PRoot hosting is not supported. A Linux ARM64 build existing upstream
  does not mean it runs inside the app.
* `ws://` to a remote host exposes the token and messages on the network; the UI
  warns and `wss://` is the supported choice off-LAN.

## Delivery guarantees

* **De-duplication** is exact when the platform supplies a stable message id. When
  it does not, a fingerprint scoped to conversation + sender + a 30-second bucket
  is used; the guarantee ends at the bucket boundary and identical text sent
  twice within one bucket is treated as one message.
* **Retries** stop after three attempts. A retry never re-runs the agent.
* **`unknown`** results are never retried: a duplicate answer in a chat is worse
  than a gap.
* **Ordering** is per conversation. Two conversations can interleave.
* **Crash recovery** restores the outbox and the de-duplication window, but not a
  task that was running inside OpenCode. That is OpenCode's own recovery, not the
  channel layer's.

## Android behaviour

* The app is not a permanent server. Android may stop background work; Doze and
  battery optimisation can suspend a socket.
* A reconnect after resume is normal and expected. The UI shows 重连中 rather than
  pretending to be online.
* No claim is made that a channel stays connected while the app is killed.

## Product behaviour that may surprise

* Telegram remains a single-owner private chat with one current binding.
  Switching the binding does not discard the result an earlier task still owes.
* `/approve` and `/deny` from a chat are refused with an explanation. Approvals
  stay in the app.
* Group members never share a session. If you want shared context in a group, it
  is not implemented.
* A message that arrives while the agent is running becomes a supplement, not a
  second task. Use `/queue` for the next task.
* Deleting a channel configuration removes its credentials, inbox and outbox
  rows. It does not delete the OpenCode sessions it created.

## Third-party components

| Component | Licence | Bundled? | Who runs it |
| --- | --- | --- | --- |
| Telegram Bot API | Telegram platform terms | No | Telegram |
| QQ Open Platform API | Tencent platform terms | No | Tencent |
| LLBot | GPL-2.0 | **No** | You |
| LLBot OneBot 11 plugin | GPL-2.0 | **No** | You |
| OneBot 11 | Protocol specification | No code copied | n/a |

No new Dart package was added for the channel work: the WebSocket, HTTP and JSON
support comes from `dart:io` and `dart:convert`.

What a channel carries leaves the phone: message text and the agent's replies go
to Telegram, to Tencent's Open Platform, or through the LLBot you run. The
[privacy policy](../PRIVACY.md) says what is stored locally, what is transmitted
and what deleting a configuration does and does not remove.
