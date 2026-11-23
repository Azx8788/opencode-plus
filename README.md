# OpenCode Plus

**Coding agents on an Android phone, 64-bit ARM only.**

OpenCode Plus is a trimmed derivative of [OpenCode Mobile](https://github.com/Eslamasabry/opencode-mobile-next).
It keeps the parts this project uses — the on-device Linux, the agent
sessions, the chat, terminal, approvals and diffs — and drops everything that
was built for other platforms or for release tooling we do not run. It was
called OpenCode Mini up to 0.3.13; the display name, launcher label and
documents are now OpenCode Plus, while the application id stays
`com.azx8788.opencode.mini` so an existing install upgrades in place instead
of losing its servers and its Ubuntu.

中文概览见 [opencodePlus项目介绍.md](opencodePlus项目介绍.md)；面向维护者的历史审计快照见 [docs/PROJECT_OVERVIEW.md](docs/PROJECT_OVERVIEW.md)。

## What it does

- **Agents run on the phone.** The app installs its own Ubuntu (proot, no root),
  then runs OpenCode 2, Claude Code, Codex, Gemini, Kilo or Cline inside it.
  The first run downloads about 210 MB of Linux and tools over Wi-Fi.
- **Or connect to a computer** running an OpenCode 2 / Codex / Paseo server.
- **Approve from anywhere**: notification, home-screen widget or the chat.
- **See the result**: built-in terminal, in-app preview, phone-sized diffs.
- **Scheduled prompts**, widgets, voice input, and multi-agent teams are kept.
- **Optional Telegram relay** for the on-phone OpenCode server: send text
  instructions from one allowlisted private account and receive agent replies
  plus brief progress notices. The bot token stays in Android secure storage.
  See [docs/TELEGRAM_BOT.md](docs/TELEGRAM_BOT.md) for setup and limits.

## Platform

| | Status |
| --- | --- |
| Android | 8.0 (API 26) or newer, **arm64-v8a only** |
| iOS, Linux, Windows, macOS | Not built from this repository |
| Languages | English and Simplified Chinese |
| Updates | Plain APKs from this repository's Releases. No code-push channel. |

## Versioning

`version:` in `pubspec.yaml` is the only version the APK carries
(`0.3.25+33` is name 0.3.25, code 33). **A plain `flutter build apk` does not
move it**, so two builds of the same tree install as the same version and the
phone has no reason to treat the second one as an upgrade. Use one of these
(the numbers below are the current version and what each command makes of it):

```sh
dart run tool/bump_version.dart              # 0.3.25+33 -> 0.3.25+34
dart run tool/bump_version.dart --patch      # 0.3.25+33 -> 0.3.26+34
tool/build_apk.sh                            # bump, then build a release APK
```

The build number always increases, including on `--patch`, `--minor` and
`--major`: Android compares `versionCode` first, and a version that calls
itself newer while carrying a smaller code installs nothing.

CI does not commit a bump back to the branch. It sets `OC_VERSION_CODE` to
`100000 + GITHUB_RUN_NUMBER`, which the Gradle build prefers over the pubspec
value, so every CI run is a higher code than the last — and higher than a
local bump, because Releases is the channel people install from. A local
build that needs a new code must run the bump itself — or use
`tool/build_apk.sh`.

### Cutting a release

Every push and every tag builds and tests, but only a tag publishes. The tag
must be `v` plus the **whole** `pubspec.yaml` version, build number included:

```sh
# version: 0.3.27+35
git tag -a "v0.3.27+35" -m "OpenCode Plus 0.3.27+35"
git push origin "v0.3.27+35"
```

`v0.3.27` is rejected by the `Check the tag matches pubspec` step, and that
failure happens *before* packaging: the run goes red and carries no APK
artifact, which reads like "the build produced no install package". The
release job then attaches `opencode-plus-<version>-arm64-v8a.apk` and
`SHA256SUMS` to a draft release; publish the draft (or pass `--draft=false`)
to make it installable from Releases.

Branch and `main` runs upload the same APK as a workflow artifact, zipped by
`actions/upload-artifact` — that is a build for testing, not the install
channel. Their `versionCode` is `100000 + run_number`, so a branch build made
*after* a release carries a higher code and will refuse to be replaced by
that release; uninstall it first, or install a build made later than it.

## Architecture and internals

[docs/PROJECT_OVERVIEW.md](docs/PROJECT_OVERVIEW.md) is the long-form guide: every
`lib/` directory and what it owns, the 169 Kotlin files grouped by job, the Rust
engine's modules and tests, the full test and dependency lists, common change
recipes and a troubleshooting table. Read it before changing anything that
crosses the Flutter/native boundary.

[docs/BRANCH_INTEGRATION.md](docs/BRANCH_INTEGRATION.md) records the consolidated
branches, conflict decisions and the validation gate before branch cleanup.

## Local usage

Usage → Local usage shows an activity heatmap, overview cards, 7/30/90-day
and all-time token metrics, a selectable daily/monthly trend and a model
ranking. It follows the app's existing appearance settings. Exact costs,
budgets and the previous detailed report remain one tap away. Unreported
source breakdowns and message counts are not invented; app launches begin
counting with this version. See [LOCAL_USAGE_DASHBOARD.md](LOCAL_USAGE_DASHBOARD.md)
for measurements, bounded reads and verification.

## Memory

Settings → Conversations → Memory lets you add, edit, disable and delete
memories. In a conversation, ask AI to summarize memories, or use the
conversation menu's summary action. The `oc-ui` MCP `memory_write` tool only
proposes entries: preview, edit and select them, then explicitly save to the
same local store. There is no background extraction, independent summary
request or automatic write. The tool must be installed on the current agent;
unsupported agents do not silently use files or a different model instead.
See [MEMORY.md](MEMORY.md) for the contract and host limits.

## Shizuku

Settings → Shizuku lets the agents run Android commands through a UserService
the app binds itself, as uid 0 or 2000 — no ADB, no root and no hidden
fallback. Read-only queries may run directly; writes and red commands (delete,
stop, uninstall, privilege changes) wait for the system overlay, and advanced
mode only removes that overlay for non-red commands. Each operation is
journalled before dispatch, so a lost reply is reported as unconfirmed and is
never retried; cancel and timeout target the command's process group. The
bridge from the built-in Ubuntu is a private socket that only this app's UID
can open. See [docs/SHIZUKU_HANDOFF_2026-11-21.md](docs/SHIZUKU_HANDOFF_2026-11-21.md)
for the state machine, the known limits and the on-device checklist.

## Conversation layout

Each reply shows live elapsed time and model-step counts independently of its
finished-turn actions. Generation speed uses reported tokens and matching
generation intervals; context and cache-hit rate use the final request's
usage. The conversation menu and Usage open a task-first tree/Gantt timeline,
with independent user tasks, supplemental message turns, nested subagents and
their model steps counted separately. Unknown associations stay pending.
The managed recording plugin retains timestamps and structured outcomes, not
prompt text or credentials. Missing history and token usage remain unknown.
See [TASK_TIMELINE.md](TASK_TIMELINE.md) for the data and verification contract.

Settings → Agent → Search provider exposes OpenCode's native search providers,
including Tavily. Connect your own credential, select a fixed provider and
test a real search. A catalogue entry alone is not proof of authorization;
failed searches do not silently switch to a different provider.
Each service opens its own full-page configuration in the existing provider
style. Saving a credential and enabling a search provider are separate actions.

Reply prose stays on the page. Consecutive thoughts and tool operations sit
in a collapsible process card, in their original order. Running cards open
to the newest steps; a manual collapse or expansion is retained. Shell output
starts with a short inset preview, with the full output available on demand.
Cards follow the existing appearance settings; no background or theme is forced.

Every reply has a separate statistics row for reported elapsed time, model
steps, generation speed and the final model request's context/cache usage.
Tap it for exact totals and definitions. Speed uses recorded streaming time,
not time spent running tools. Missing data stays unknown. The timestamp
preference controls timestamps only.

Design reference and verification notes: [CONVERSATION_PROCESS_CARDS.md](CONVERSATION_PROCESS_CARDS.md).

## Reasoning levels

For the built-in server, open the conversation's model picker → All models →
Thinking. Models already advertising a reasoning-effort control show missing
levels, including Max, in the same compact, ascending list. Choose a level and
apply it to save the override and use it for the conversation. An additional
request level shows one short explanation after selection. Save and Fetch
models preserve these settings. Provider support can differ from its catalog;
an explicit override is not a promise that every model supports Max.

After upgrading from 0.3.20 or earlier, restart the built-in server once, after
its current work finishes, so configuration reload uses the live file instead
of a frozen startup snapshot. Remote servers require their owner to edit the
server configuration; this phone does not silently write to another machine.

## Provider keys

The built-in server's Providers page has an Actions button on every row.
Configured providers can be deleted with a backup; unused, unconfigured
templates can be hidden and restored. An unsupported config entry can still
be removed without opening the editor.

In a provider's configuration, name the first API key, then save (or fetch
models). The named-key list lets you add other keys, select which one to use,
rename a key, or remove an inactive key. There is no automatic key rotation or
fallback. The last selected key is the default, and a newly added key becomes
selected. Long-press a model → Switch API key to choose by name without leaving
the model list. This changes the provider's key for all of its models, not a
per-model or per-conversation override. Names and file paths are kept in app preferences; key values are
stored in private server-side files. Switching reloads the current project;
if reload fails the app says to restart after ongoing work finishes. Existing
file-based and plaintext keys are retained, and shared/external files are not
silently erased.

## Differences from upstream

Full list in [UPSTREAM.md](UPSTREAM.md). In short:

- Android only: no iOS, desktop or web projects.
- One ABI: `arm64-v8a`.
- Two locales: `en`, `zh`.
- Shorebird code push removed; the app never asks a third-party update service
  for patches.
- Documentation site, widgetbook, marketing assets, device QA harness and the
  185 MB test suite are not included (they stay in upstream).
- Application id `com.azx8788.opencode.mini`, kept across the rename, so it
  installs beside OpenCode Mobile rather than over it and upgrades over
  earlier OpenCode Mini builds.

## Build

- Flutter **3.47.9**
- JDK 17, Android SDK 37, NDK as required by that Flutter release
- Rust binaries are committed under `android/app/src/main/jniLibs/arm64-v8a`,
  so no Rust toolchain is needed to build the APK.

```sh
flutter pub get
dart run tool/bump_version.dart
flutter build apk --release --target-platform android-arm64
```

A release build uses `android/key.properties` when it exists (see
`android/key.properties.example`); without it Gradle falls back to the debug
key, which still proves both the Kotlin and Dart sides compile but is not a
key to publish. CI (`.github/workflows/build.yml`) builds the signed APK from
four repository secrets and uploads it as an artifact.

## Security

Read [SECURITY.md](SECURITY.md) before reporting a problem. Reports go to this
repository's private advisory page — **not** to the upstream OpenCode or
OpenCode Mobile projects, which do not maintain this app. The app stores
server passwords in the Android Keystore and approves shell-capable actions,
so a defect here can become code execution on someone's development machine.

## License

MIT — see [LICENSE](LICENSE), which keeps the original copyright notice.
Bundled fonts, native binaries and packages are listed in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) with full texts in `LICENSES/`.
PRoot (GPL-2.0), talloc (LGPL-3.0) and libandroid-shmem (BSD-3-Clause) ship as
native libraries; their sources are linked in the notices.

This is an independent community project. It is not built, maintained,
endorsed by, or affiliated with the official OpenCode team, nor with Anthropic.

## 中文说明

OpenCode Plus 是 OpenCode Mobile 的精简衍生版，只面向 Android 64 位
（arm64-v8a）设备：保留手机内置 Linux、Agent 会话、对话/终端/审批/diff/预览
等全部功能；通知栏、桌面小组件与快捷开关的原生文案同样跟随中英双语。去掉
iOS 与桌面工程、多语言（仅中英）、Shorebird 热更新、文档站与测试工程。

想详细了解仓库，读 [docs/PROJECT_OVERVIEW.md](docs/PROJECT_OVERVIEW.md)：
逐目录职责、Kotlin 169 个文件的分组、Rust 引擎模块与测试、依赖与测试清单、
常见改动步骤和故障排查表。

可选 Telegram 机器人在「设置 → 对话 → Telegram 机器人」配置：使用
@BotFather 创建 bot，并填写自己的 Telegram 数字用户 ID。机器人只处理该 ID
的私聊文字消息；Agent 回复和工具进度会回传 Telegram。Bot Token 使用 Android
安全存储；在 Telegram 收发的内容会经过 Telegram 服务。要后台持续接收消息，
需保持 App 可运行并启用后台运行功能。

0.3.13 及以前叫 OpenCode Mini；现在应用名、桌面图标名与文档统一为
OpenCode Plus，包名仍为 `com.azx8788.opencode.mini`，因此可以直接覆盖升级，
不会丢服务器配置和内置 Ubuntu。

版本号只有 `pubspec.yaml` 里的一处。直接 `flutter build apk` **不会**自动加
版本号，构建前请运行 `dart run tool/bump_version.dart`（或直接用
`tool/build_apk.sh`）；CI 把 `versionCode` 设为 `100000 + GITHUB_RUN_NUMBER`，
保证每次产出的包都能覆盖上一次，且高于本地构建的包。许可证仍为 MIT，原始版权与
第三方声明完整保留（见 `LICENSE`、`NOTICE`、`THIRD_PARTY_NOTICES.md` 和
`UPSTREAM.md`）。
