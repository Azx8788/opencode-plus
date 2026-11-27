# Prior art: NapCat, SnowLuma, AstrBot

Three projects do the same job we do, or part of it, and they do some of it
better. This page records what was read, what was taken, and what was refused.
It exists so the next person does not have to rediscover that the official
repositories are gone.

## What happened to the sources

| Project | Official repository | State (November 2026) | Where the source was read |
| --- | --- | --- | --- |
| NapCat | `NapNeko/NapCatQQ` | Emptied. The README is one line: “到这里告一段落” (this is where it ends), commit `105f38e`, 2026-11-12 | Fork `MingTianSang/NapCatQQ`, which still carries `packages/napcat-onebot` and the network config schema |
| SnowLuma | `SnowLuma/SnowLuma` | Made private by its author after a lawyer's letter; the docs site is a 404 | Archive `XingYunStar/snowluma` (full history, v2.4.2 release artefacts, Docker image) and `venti1112/snowluma` |
| AstrBot | `AstrBotDevs/AstrBot` | Alive and active | `README.md`, `LICENSE` |

Neither the licence of NapCat nor that of SnowLuma is a standard one:
NapCat ships a “Limited Redistribution License”, SnowLuma a source-available
non-commercial licence plus an EULA. Both forbid the kind of redistribution an
APK would be, which is one more reason nothing from either is bundled here.

## What each one actually is

**NapCat** is a protocol-side framework: it runs inside the QQ NT client and
turns QQ's own protocol into OneBot 11. Its network config (read from
`packages/napcat-onebot/config/config.ts`) defines an HTTP server on 3000, a
WebSocket *server* on 3001, and a WebSocket *client* that dials a URL —
`ws://localhost:8082` by default — with the access token sent as
`Authorization: Bearer …`. Message bodies are arrays, not CQ strings. The WebUI
listens on 6099.

**SnowLuma** is a TypeScript runtime that bridges a running QQ client to
OneBot 11. It offers WebSocket server *and* client, plus an HTTP server, and
converts text, images, voice, video, files, replies, mentions, forwards and
common cards. WebUI on 5099, OneBot gateway on 3000 (HTTP) and 3001 (WS),
path `/`. Multiple QQ accounts run side by side, each with its own identity
map and message store.

**AstrBot** is not a transport at all. It is an agent chatbot platform: it
consumes OneBot 11 (through its `aiocqhttp` adapter), and also Telegram, Slack,
Feishu, DingTalk, Discord, Satori and a dozen more, and puts personas, plugins,
sessions and model routing on top. In the usual deployment NapCat logs the QQ
account in, AstrBot listens, and NapCat dials it.

That last sentence is the important one for us: **AstrBot occupies the same
seat as this app**, not the seat of a channel. Adding it “as a channel” would
mean handing the agent to another program.

## What was taken

1. **Reverse WebSocket.** NapCat and SnowLuma both offer a client that dials a
   URL, and AstrBot's adapter is a listener. On a phone this direction is the
   useful one: the PC running the QQ client needs no inbound port, only a route
   to the phone. `OneBot11Provider` now has `transport: reverse`, binds
   `0.0.0.0:8082` by default, and refuses to listen without an access token.
2. **The real default ports.** 3001 for a forward socket, 8082 for the reverse
   one, 6099 and 5099 for the two consoles. The settings page names them, so a
   person does not have to guess which number belongs to which project.
3. **Group discovery instead of typed group numbers.** `get_group_list` is a
   standard action; the page now offers the groups the account is actually in,
   because a nine-digit number typed by hand is an allowlist that silently
   answers nobody.
4. **The token never in the URL.** NapCat sends it as a bearer header and so do
   we. The reverse listener accepts the `access_token` query parameter as well,
   because other implementations put it there, but the header is what the
   settings page describes.

## What was not taken

- **Several QQ accounts in one app.** SnowLuma runs accounts side by side. Here
  one account is one channel configuration; two accounts would need two
  engines, two allowlists and a UI that says which is which. Not done, and not
  pretended.
- **Media sending.** SnowLuma converts images, voice, video and files. The
  agent's reply is text today, so the capability table says images are received
  and recorded but not sent. Implementing a send path without a caller would be
  a table entry with nothing behind it.
- **Cards and forwards.** Preserved as `unknown` segments so nothing is lost,
  never rendered.
- **AstrBot as a channel.** See above: it would replace the agent, not extend
  the channel layer.

## Licences

| Component | Licence | Bundled | Who runs it |
| --- | --- | --- | --- |
| NapCat | Limited Redistribution License (custom) | No | You, next to the QQ NT client |
| SnowLuma | Source-available non-commercial licence + EULA | No | You, on Windows or Linux |
| AstrBot | AGPL-3.0 | No | You, on a server |

Nothing from these projects is copied into this repository. The OneBot 11 client
here is written against the published protocol: forward and reverse WebSocket,
JSON actions, `echo` correlation, message segment arrays.

## Android environment deployment reference

The user's one-click deployment example is
[MuFengDR/AstrBot-Bubble-Android-App](https://github.com/MuFengDR/AstrBot-Bubble-Android-App),
reviewed at `0d1abe6ed5b6b384ab3dd3c0b513079c5ad18b36`.
Its `terminal_controller.dart` performs installation and process management;
its bootstrap stages and verifies downloaded installers. Those are the useful
patterns here: a deploy action must install and start the service, report real
progress/failure and keep account data across restarts. A WebView link alone
does not implement that flow.

The reference's separately downloaded installer v0.1.7
(`MuFengDR/AstrBot-Android-Scripts`, revision
`6b4e555f5ef185e30b35c805e37a19907f58a1a2`) disables online NapCat installation.
The app therefore does not copy that recipe. Its independent local installer
uses LLBot's official v8.3.2 Linux ARM64 release, pinned by SHA-256, inside the
existing built-in Ubuntu. LLBot authorization and QQ QR sign-in remain in the
local console. The deployment controls are reachable from both the Ubuntu
manager and personal-QQ settings.

The reference app is BSD-3-Clause; its separate installer repository is not
assumed to share that licence. No source from either is included here.
