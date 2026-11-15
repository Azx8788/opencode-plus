# OpenCode Plus 项目全书

- 仓库：<https://github.com/Azx8788/opencode-plus>
- 分析对象：`main` @ `0355410`（快照基线）+ 整改分支 `audit/quality-fixes-20261115`
- 应用版本：`0.3.14+19`（`pubspec.yaml`）
- 文档版本：2026-11-15（质量审计整改后）
- 方法：逐目录静态阅读 + 本地 Flutter 3.47.9 release 构建 + GitHub Actions 实跑（run `43700051452`）
- 可信度：未标注的内容都能在仓库文件里直接找到；推断会写"推断"；真机未验证的项目集中列在第 26 节

> 这是一份给"要接手、要改、要审计这个仓库的人"看的文档，不是宣传页。它回答四个问题：这个应用是什么、代码在哪里、为什么这样写、改哪里会踩坑。

---

## 1. 一句话定位

OpenCode Plus 是一个 **Android 专用（arm64-v8a）的 Flutter 客户端**：它既能把电脑上的编码 agent 服务器接进来，也能在自己应用私有目录里装一套 Ubuntu 24.04（proot，无需 root），在手机里跑 OpenCode 2、Claude Code、Codex、Gemini、Kilo、Cline、Goose 等 agent。

面向的场景是"一台手机就是开发终端"：对话、终端、审批、diff、文件预览、定时任务、桌面小组件、语音输入和多 agent 协作都在同一个应用里。

## 2. 与上游的关系

OpenCode Plus 是 [OpenCode Mobile](https://github.com/Eslamasabry/opencode-mobile-next) 的裁剪衍生版，不是 fork 后持续 merge 的分支，而是"取需要的部分、删掉不做的东西"的快照式衍生：

| 保留 | 删除 |
| --- | --- |
| 内置 Linux、agent 会话、对话/终端/审批/diff | iOS / macOS / Windows / Linux 桌面工程 |
| 多后端（OpenCode 2、Codex、Paseo、ACP、A2A） | Web 工程、文档站、widgetbook |
| 小组件、快捷开关、定时任务、AI Team | Shorebird 热更新通道 |
| 中英双语 | 上游的 30+ 语言（本仓库只留 en / zh） |
| MIT 许可证与原始版权 | 上游 185 MB 测试工程与设备 QA 套件 |

关键取舍：**applicationId 保留 `com.azx8788.opencode.mini`**。0.3.13 之前项目叫 OpenCode Mini，改名后包名不动，目的是让旧安装原地覆盖升级，不丢服务器配置和已经装好的 Ubuntu。代价是代码里到处能看到 `mini` 字样（包名、prefs 键、URL scheme、日志目录名的一部分），这是有意保留的历史包袱。

## 3. 关键事实表

| 项 | 值 |
| --- | --- |
| 版本 | `0.3.14+19`（name 0.3.14 / code 19） |
| Flutter | 3.47.9（README、CI 一致） |
| Dart SDK 约束 | `^3.10.0` |
| Android | minSdk 26（8.0）、compileSdk 37、targetSdk 跟随 Flutter |
| ABI | 仅 `arm64-v8a`（Gradle 里 `abiFilters.clear()` 后只加这一个） |
| 构建 | AGP 9.3.2、Gradle 9.5.0、JDK 17、Kotlin JVM 17 |
| UI | Material 3 + 自研 Kit 设计系统（278 个文件） |
| 状态 | Riverpod 3 + `ChangeNotifier` 连接控制器 |
| 本地化 | Flutter ARB 9622 键 × 2 语言；Android 原生文案 220 条 × 2 语言 |
| Dart 代码 | 1442 文件 / 614,977 行（其中生成 l10n 129,415 行） |
| Kotlin 代码 | 169 文件 / 25,512 行 |
| Rust 代码 | 36 文件 / 19,229 行，233 个测试 |
| Dart 测试 | 27 文件 / 277 用例 / 4,670 行 |
| 内置服务器端口 | `4097` |
| 内置 rootfs | Ubuntu 24.04（proot），首次约 210 MB |
| 应用包名 | `com.azx8788.opencode.mini` |
| 许可证 | MIT（含原始版权），第三方见 `THIRD_PARTY_NOTICES.md` |

## 4. 功能全景

### 4.1 连接方式

| 方式 | 说明 | 入口 |
| --- | --- | --- |
| 手机内置服务器 | 应用自己装 Ubuntu，跑 OpenCode 2，`127.0.0.1:4097` | `BuiltinServerService` + `lib/builtin/` |
| 局域网 / 公网 HTTP(S) | 手动填地址、用户名、密码，逐源同意明文 | `lib/api2/transport.dart` |
| Tailscale | 通过 tailnet 地址连接，含 handoff 流程 | `TailscaleHandoff.kt`、`lib/platform/tailscale.dart` |
| Termux | 驱动 Termux 里的 opencode，`RUN_COMMAND` 权限 | `lib/termux/` |
| SSH 主机（BYO host） | 自带主机 + 签名 bundle，跑 host agent | `lib/host/`、`ByoHostSigner.kt` |
| 二维码配对 | 扫 `opencode2 pair` 打印的码 | `mobile_scanner` + `PairingScannerScreen` |
| 会话接力 | 另一台手机通过 `opencode-mobile://session` 传会话标识 | `SessionLinkIngress.kt` |

### 4.2 agent 运行时

`lib/domain/agent_catalog.dart` 里每个 agent 都是一条**带哈希的固定配方**：版本、可执行文件名、arm64/x64 两种产物、下载地址、SHA-256、压缩包内路径、安装后体积。当前配方覆盖：

| agent | 版本 | 启动方式 | 备注 |
| --- | --- | --- | --- |
| OpenCode | 2.1.1 | 内置服务器 | 主后端 |
| Claude Code | 2.1.294 | 原生二进制 | 需账号或网关 |
| Codex | 0.162.1 | musl 静态包 | 支持 ACP |
| Gemini | 0.63.0 | `--acp` | 需主机登录 |
| Qwen | 0.25.0 | `--acp` | 需在主机配 key |
| Kilo | 7.8.3 | npm 包解包 | 需主机登录 |
| Cline | 3.0.68 | npm 包解包 | 需主机登录 |
| Goose | 1.54.0 | tar.gz | 需主机登录 |
| oh-my-pi (omp) | 18.5.1 | 原生二进制 | 实验性 |

"带哈希的固定配方"意味着**离线可审计**：`test/mini_agents_test.dart` 会校验每个 pin 都是 https、哈希是 64 位十六进制、压缩包成员存在，新增 agent 不能只写个地址了事。

### 4.3 会话能力

- 对话流：流式文本、思考块、工具调用卡片、权限询问、表单问题、计划审阅。
- 审批：允许一次 / 总是允许 / 拒绝，可从聊天、通知、桌面小组件三处操作，答复有短暂撤销窗口（`delayed_answers.dart`）。
- diff 与回退：按文件看改动、按轮次回退（`staged_revert`）、工作树管理。
- 预览：内置 WebView 预览开发服务器、PDF 本地渲染（隔离进程 `:local_pdf`）、图片、SVG（静态内容过滤）、Office 文本提取。
- 终端：内置 PTY 终端（Termux terminal-emulator 库），可在 Ubuntu 里直接敲命令。
- 语音：本地 sherpa_onnx 识别 + 朗读，模型可选下载。
- 导出/导入：会话 JSON、项目打包导出。

### 4.4 自动化与系统集成

| 能力 | 实现位置 | 说明 |
| --- | --- | --- |
| 定时提示 | `lib/scheduling/` + `ScheduledPrompt*`（13 个 Kotlin 文件） | WorkManager + AlarmManager，应用关闭也能跑 |
| 桌面小组件 | `Sessions*/Usage*/StatusWidget*` | 4 种会话卡 + 2 种用量卡 + 状态卡，支持按钮操作 |
| 快捷开关 | `AttentionTileService`、`PauseTileService` | 待处理计数 / 暂停后台 |
| 通知 | `StatusNotification*`、`CodingAlertRequest` | 实时进度、审批、语音下载、空闲暂停 |
| 启动器快捷方式 | `res/xml/shortcuts.xml`、`PinnedSessionShortcuts.kt` | 连接、新对话、固定会话 |
| 分享入口 | `MainActivity` 的 `SEND text/plain` | 任意应用分享文本直接开新会话 |

## 5. 技术栈

### 5.1 运行时依赖

`pubspec.yaml` 的依赖几乎每个都带"为什么锁这个版本"的注释，这是这个仓库的一个特点：版本选择是可追溯的决策，不是随手 `^`。

| 依赖 | 版本 | 用途 |
| --- | --- | --- |
| `flutter_riverpod` | ^3.4.3 | 应用级状态（连接之外的部分） |
| `dio` | ^5.7.0 | HTTP 传输；重定向显式关闭 |
| `webview_flutter` / `_android` | ^4.9 / ^4.10 | 应用内预览 |
| `flutter_secure_storage` | 11.2.0 | 服务器密码、API key（Android Keystore） |
| `local_auth` | 3.0.2 | 生物识别解锁 |
| `shared_preferences` | ^2.3.3 | 轻量偏好（`oc.` 前缀） |
| `path_provider` | 2.1.6 | 应用目录 |
| `file_picker` | 12.2.0 | 选文件/目录 |
| `image_picker` | 1.2.3 | 拍照进对话 |
| `mobile_scanner` | 7.4.2 | 二维码配对（CameraX + 捆绑 ML Kit） |
| `qr` | 3.0.2 | 生成会话接力二维码（纯 Dart） |
| `record` | 7.1.1 | 录音 |
| `sherpa_onnx` | 1.13.7 | 离线语音识别 |
| `xterm` | 本地 `third_party/xterm` | 终端渲染 |
| `highlight` | ^0.7.0 | 代码高亮 |
| `flutter_svg` | 2.3.0 | 供应商图标（静态校验） |
| `xml` | 7.0.1 | 解析 Android 资源、SVG |
| `crypto` / `cryptography` | 3.0.7 / 2.9.0 | 哈希、签名、TLS 辅助 |
| `flutter_timezone` | 5.1.0 | 真实 IANA 时区，统计按设备日切分 |
| `dynamic_color` | ^1.9.0 | Material You 取色（锁 1.x，2.x 类型不兼容） |
| `package_info_plus` | ^10.2.1 | 版本号展示 |
| `url_launcher` | ^6.3.1 | 外链 |
| `uuid` | ^4.5.1 | 标识符 |
| `clock` | ^1.1.2 | 可注入时间（测试） |
| `desktop_drop` | 0.8.4 | 桌面拖拽（仅桌面路径用，Android 不激活） |
| `window_manager` / `screen_retriever` | ^0.5.2 / ^0.2.0 | 桌面窗口（本仓库不构建桌面，代码仍在） |
| `scrollable_positioned_list` | 0.3.8 | 长会话定位 |
| `path` | ^1.9.1 | 路径拼接 |

已知代价（仓库自己写在注释里，不藏）：`desktop_drop` 会多编译一个 Gradle 子工程并触发 KGP 警告；`mobile_scanner` 捆绑 ML Kit 模型使 APK 变大，但换来无 Play 服务也能扫码。

### 5.2 Android 原生依赖

- `androidx.work:work-runtime:2.10.5`：定时任务。
- `androidx.core:core:1.13.1`：`ShortcutManagerCompat`。
- `commons-compress:1.27.1`：解 Ubuntu Base tarball。
- `com.github.termux.termux-app:terminal-emulator:v0.118.3`：PTY（JitPack，仅此 group）。
- 测试：JUnit 4.13.2、Robolectric 4.17（把真实 RemoteViews 渲染成图片做断言）。

### 5.3 Rust 引擎依赖

`axum 0.8`（HTTP）、`tokio 1`、`rusqlite 0.37`（bundled SQLite）、`git2 0.20`、`reqwest 0.12`、`p256`（ECDSA 证明）、`sha2` / `hmac` / `subtle`（校验与常数时间比较）。release 配置 `opt-level="s"`、`lto="thin"`、`strip=true`，为体积让路。

## 6. 总体架构

### 6.1 分层

```
┌──────────────────────────────────────────────────────────────┐
│ UI 层        lib/ui（722 文件）                                 │
│   screens 306 / widgets 107 / kit 278 / git / search ...      │
├──────────────────────────────────────────────────────────────┤
│ 状态层       lib/state（215 文件）                              │
│   ConnectionController（36 个 mixin，54 个 part 文件）           │
│   ProfileStore / offline_queue / delayed_answers / ...        │
├──────────────────────────────────────────────────────────────┤
│ 领域层       lib/domain（190 文件，纯 Dart，无 I/O）             │
│   agent_catalog / custom_provider / team_* / session_* / git  │
├──────────────────────────────────────────────────────────────┤
│ 协议/适配层  lib/api2 / paseo / codex / acp / a2a / orchestration│
├──────────────────────────────────────────────────────────────┤
│ 设备层       lib/builtin / termux / platform / background      │
│   Flutter ⇄ MethodChannel/EventChannel ⇄ Kotlin ⇄ PRoot/进程    │
├──────────────────────────────────────────────────────────────┤
│ 原生层       Kotlin 169 文件 + 3 个 .so（AI Team 引擎）          │
│   Rust 引擎：HTTP + SQLite + git + 调度 + 边界证明               │
└──────────────────────────────────────────────────────────────┘
```

### 6.2 依赖方向（硬规则）

1. `domain` 不 import `state`、`ui`、`api2`——纯数据与规则，可单测。
2. `ui` 不直接调 MethodChannel，一律经 `state` 或 `platform`。
3. 原生层不解析业务 JSON，只搬运与执行；协议解释留在 Dart/Rust。
4. Rust 引擎不感知 Flutter，只暴露 6 条 HTTP 路由。

违反这些方向的地方通常是历史遗留，改动时要留意（例如部分 `platform` 直接持有 `ConnectionController`）。

### 6.3 一次"发送提示"的完整路径

```
Composer 输入
  → ConnectionController.sendPrompt（state/connection/queue.dart）
  → 选择后端方言（api2/dialect.dart）
  → transport（dio，关闭重定向，8s 连接 / 2min 请求超时）
  → OpenCode 2 / Codex / Paseo 服务器
  → SSE / 长轮询事件（10min 超时）
  → events.dart 解析成 ChatEvent
  → chat_feed 合并工具调用、权限请求、思考块
  → UI 增量重建
  → 同时写 app_log（JSONL，8 MB/7 天滚动）
```

审批回传走反向路径：UI/通知/小组件 → `permissions.dart` → 对应后端 API；若应用被杀，`pending_command_journal` 在下次启动时对账。

## 7. 目录结构与模块地图

### 7.1 顶层

| 路径 | 作用 |
| --- | --- |
| `lib/` | Dart 全部源码（1442 文件） |
| `android/` | Android 工程：Kotlin 169 文件、资源、签名、ProGuard |
| `engine/phone/` | AI Team Rust 引擎（36 文件） |
| `test/` | Dart 测试（27 文件） |
| `tool/` | 版本、构建、配额、APK 校验脚本 |
| `assets/` | 字体、图标、供应商 marks、AI Team manifest |
| `third_party/xterm` | 本地 patch 的终端包 |
| `LICENSES/` | 第三方许可证全文 |
| `.github/workflows/` | `build.yml`（APK）、`engine.yml`（手动构建 .so） |

### 7.2 `lib/` 逐目录

| 目录 | 文件 | 行数 | 职责 | 从哪读起 |
| --- | --- | --- | --- | --- |
| `ui/` | 722 | 280,279 | 所有界面 | `ui/screens/home_screen.dart` |
| `state/` | 215 | 68,410 | 连接、偏好、队列、缓存 | `state/connection.dart` |
| `domain/` | 190 | 41,547 | 纯规则与模型 | `domain/agent_catalog.dart` |
| `l10n/` | 3 | 129,415 | 生成的本地化（勿手改） | `lib/l10n/app_en.arb` |
| `orchestration/` | 44 | 12,144 | 多 agent 编排、适配器 | `orchestration/dispatch.dart` |
| `api2/` | 31 | 10,334 | OpenCode 2 HTTP/SSE 与网关 | `api2/transport.dart` |
| `termux/` | 22 | 9,442 | Termux 桥、脚本、迁移 | `termux/bridge.dart` |
| `paseo/` | 34 | 9,064 | Paseo agent host 协议 | `paseo/` |
| `background/` | 14 | 4,547 | 前台服务、通知、快照 | `background/live_background.dart` |
| `voice/` | 14 | 4,364 | 语音识别、模型管理、朗读 | `voice/controller.dart` |
| `diagnostics/` | 10 | 3,371 | 日志、崩溃、性能轨迹 | `diagnostics/app_log.dart` |
| `platform/` | 18 | 2,797 | 平台能力与通道封装 | `platform/platform_capabilities.dart` |
| `codex/` | 5 | 2,549 | Codex 后端 | `codex/` |
| `main_parts/` | 7 | 2,275 | 启动闸门、路由、分享 | `main_parts/bootstrap_gate.dart` |
| `scheduling/` | 9 | 1,744 | 定时提示 Dart 侧 | `scheduling/controller.dart` |
| `host/` | 4 | 1,108 | BYO SSH 主机、签名 | `host/byo_host_signer.dart` |
| `acp/` | 2 | 596 | Agent Client Protocol | `acp/` |
| `update/` | 2 | 586 | 版本检查（桌面遗留 + Shorebird 提示） | `update/desktop_release_check.dart` |
| `demo/` | 3 | 551 | 演示数据 | `demo/demo_store.dart` |
| `desktop/` | 2 | 484 | 桌面窗口状态（不构建） | `desktop/window_state.dart` |
| `feedback/` | 2 | 431 | 问题反馈 | `feedback/problem_report.dart` |
| `a2a/` | 1 | 426 | Agent-to-Agent | `a2a/` |
| `widgets_overlay/` | 6 | 418 | 小组件覆盖层独立入口 | `widgets_overlay/widget_overlay_app.dart` |
| `quota/` | 1 | 294 | 供应商配额客户端 | `quota/provider_quota_client.dart` |
| `builtin/` | 79 | 27,052 | 内置 Linux 与服务器 | `builtin/builtin_linux.dart` |

### 7.3 `lib/builtin/` 子树

| 子目录 | 文件 | 内容 |
| --- | --- | --- |
| `agents/` | 14 | agent 安装、探测、登录、进程 |
| `setup/` | 15 | 安装步骤、规划、重试、完成判定 |
| `linux_manager/` | 6 | Ubuntu 生命周期、迁移 |
| `migration/` | 6 | 旧安装迁移 |
| `team/` | 3 | AI Team 宿主 |

顶层关键文件：`builtin_linux.dart`（proot 启动、环境变量、服务器脚本）、`builtin_server.dart`（前台服务与恢复）、`builtin_provider_store.dart`（写 opencode 配置）、`phone_server_healing.dart`（自愈）、`thermal_guard.dart`（过热降载）。

### 7.4 `lib/domain/` 子树

| 子目录 | 文件 | 内容 |
| --- | --- | --- |
| `factsbook/` | 14 | 事实簿（项目级知识条目） |
| `genui/` | 12 | 生成式 UI 描述与渲染协议 |
| `git/` | 8 | 分支、diff、工作树、提交 |
| `server_gateway/` | 5 | 服务器网关能力协商 |
| `agent_tools/` | 4 | agent 工具描述 |
| `models/` | 3 | 模型数据结构 |

### 7.5 `lib/ui/` 子树

| 子目录 | 文件 | 内容 |
| --- | --- | --- |
| `kit/` | 278 | 设计系统：按钮、字段、卡片、diff、图表、玻璃层、动效 |
| `screens/` | 306 | 页面，按功能再分 `chat/`、`settings/`、`team/`、`library/`、`files/`、`terminal/` 等 |
| `widgets/` | 107 | 跨页面复用组件（markdown、表单渲染、文件预览） |
| `git/` | 4 | Git 界面 |
| `search/` | 5 | 全局搜索 |
| `desktop/` | 4 | 桌面布局适配（未构建） |
| `navigation/` | 3 | 路由壳 |
| `agents/`、`teaching/` | 各 1 | agent 引导、教学层 |

`kit/` 是自研设计系统的核心：不用 Material 组件直接拼页面，而是先有 Kit 原子件，再组合成 screen。好处是视觉一致、深色/玻璃/动效统一；代价是学习曲线，改样式应优先改 Kit 而不是逐页打补丁。

## 8. 启动与运行流程

### 8.1 冷启动

1. `OcApplication` 初始化崩溃存储、通知渠道、语言。
2. `MainActivity` 用 `LaunchTheme` 显示原生启动底色，Flutter 引擎起。
3. `main.dart` → `AppBootstrapGate`：首帧先画"正在打开"，再读偏好与 Keystore。
4. 读 `ProfileStore`：服务器列表、选中项、密钥引用（值在 Keystore）。
5. 构建 `ConnectionController`，注入 `BackgroundLiveController`。
6. 若选了内置服务器：`BuiltinServerService` 前台服务起，检查 rootfs、密码文件、进程所有权票据，必要时恢复或重装。
7. 若选了远程服务器：连接探测（8 秒超时），失败进离线态，队列保留待发提示。
8. 首帧之后才允许暴露会话与连接，避免"半初始化"状态被操作。

`AppBootstrapGate` 有一条明确设计：**任何偏好/Keystore 失败都不能让 Android 显示空白原生窗口**，所以先渲染再加载，8 秒后显示"仍在打开 / 重试"。

### 8.2 进程与前台服务

| 组件 | 类型 | 作用 |
| --- | --- | --- |
| `BuiltinServerService` | `specialUse` 前台服务 | 跑内置 OpenCode 服务器 |
| `SetupService` | `specialUse` 前台服务 | 首次安装 Ubuntu |
| `BackgroundConnectionService` | `dataSync\|shortService` | 远程连接保活 |
| `LocalPdfService` | `isolatedProcess`，进程 `:local_pdf` | PDF 渲染隔离 |
| `TermuxResultService` | 普通 service | 接收 Termux 执行结果 |

`specialUse` 的 subtype 描述写在 manifest 里，是给审核和用户看的：只在设备本地跑用户自己的服务器。

### 8.3 退出与恢复

- `AppExitHistoryPolicy` 记录异常退出，`app_exit_recovery.dart` 在下次启动提示。
- `NativeOrphanReaper` 清理失去所有者的进程（应用被杀后遗留的 proot/agent）。
- `RestartBackoff` 控制重启节奏，避免崩溃循环。
- `NativeWorkLeaseHost` / `WorkLeases` 用租约表达"还有活在跑"，空闲停止前必须无租约。

## 9. 内置 Linux 与进程模型

### 9.1 rootfs

- 发行版：Ubuntu 24.04 Base（arm64 tarball）。
- 解压：`commons-compress`，解到应用私有目录；`BuiltinProjectStorage` 管理项目空间。
- 运行：`libproot.so` + `libproot-loader.so` + `libtalloc.so` + `libandroid-shmem.so`，全部以 `useLegacyPackaging = true` 落成真实文件——proot 只能从真实路径执行。
- 首次下载约 210 MB，建议 Wi-Fi；`SetupService` 保活，`SetupStepRetry` 断点重试。

### 9.2 为什么必须"真实文件"

Android 10+ 默认 `extractNativeLibs=false`，`.so` 留在 APK 里按页映射，磁盘上没有可执行文件。proot 需要 exec 一个真实 loader，所以 Gradle 显式打开 legacy packaging，并排除 32 位与模拟器 ABI。这不是可选优化，是功能前提。

### 9.3 服务器启动脚本

`BuiltinLinux` 生成启动脚本（约 1500 行处的字符串）：

- 端口固定 `4097`，只监听回环。
- 密码从 `/root/.oc-builtin/server.password` 读，文件权限仅 root；缺失时 `exit 78`（配置错误），不静默用空密码。
- `XDG_*` 全部指到 `/root/.oc-opencode2/{data,cache,state,config}`，与 Termux 里的 OpenCode 隔离，避免两套实例抢同一份状态。
- `OPENCODE_SERVER_USERNAME` / `OPENCODE_SERVER_PASSWORD` 从文件注入，不写进命令行（`ps` 看不到）。

### 9.4 服务器空闲停止

`IdleStopPolicy`：1–60 分钟可配。判定依据是"无租约 + 无活动连接 + 无运行中的任务"，不是简单的计时器。停止后 `NativeIdleReturnNotification` 发通知，点按可恢复；`phone_server_idle.dart` 负责前台恢复路径。

### 9.5 进程所有权

这是这个项目最"重"的一块设计，因为 Android 会随时杀应用，而 proot 子进程可能活下来：

| 机制 | 文件 | 作用 |
| --- | --- | --- |
| 所有权票据 | `NativeRuntimeOwnership.kt`、`BuiltinInstallerOwnership.kt` | 进程记录"属于哪个安装/哪次启动" |
| 准入 | `NativeAgentHostAdmission.kt`、`NativeInstallerAdmission.kt` | 新进程启动前核对票据 |
| 恢复预算 | `NativeRecoveryBudget.kt` | 限制单位时间内重启次数 |
| 竞态处理 | `NativeProcRace.kt`、`NativeProcScan.kt` | 扫描与 kill 之间的 TOCTOU |
| 孤儿回收 | `NativeOrphanReaper.kt` | 无主进程回收 |
| 进程树 | `NativeProcessTree.kt`、`NativeProcessList.kt` | 按父进程整树处理 |

## 10. Agent 运行时

### 10.1 安装

`lib/builtin/agents/` + `SetupRunner`：

1. 选 agent → 读配方（版本、URL、哈希）。
2. 下载到临时目录，校验 SHA-256 与体积。
3. 解包（tar.gz / npm tgz / 裸二进制），按配方取成员。
4. 落到 `/root/.local/share/oc-agents/<id>/`，`chmod +x`。
5. 写启动包装脚本，注入 PATH、代理、provider 配置。
6. 记录 manifest，供升级与卸载。

### 10.2 登录

`PhoneAgentSignIn.kt` 一族（14 个文件）处理"在手机里登录一个原本给电脑用的 CLI"：

- 探测已有凭据（Claude 的 `~/.claude`、Codex 的 `auth.json`）。
- 需要浏览器时，用前台服务 + 通知承载，避免切走就断。
- 一次性验证码/设备码走 `PhoneAgentAuthInventory` 与 `PhoneAgentAuthDeadline`，超时即失败，不挂死。
- 多进程同时登录用 `PhoneAgentAuthLock` 串行化。

### 10.3 运行

- 每个会话一个 agent 进程组，stdin/stdout 走 PTY 或管道。
- 工具调用、权限请求由 agent 输出解析成结构化事件，进入 `chat_feed`。
- 进程退出码、最后输出由 `PhoneAgentCheckOutput` 归档，失败可解释（不是"未知错误"）。
- `phone_agent_work_watch.dart` 监视"还在干活"，用于后台保活与空闲判定。

### 10.4 与 AI Team 的关系

AI Team 是"让多个 agent 协作"的上层：编排器把任务拆给不同 agent，产物落在共享工作区，由 Rust 引擎做边界与提交控制。这条链路比单 agent 复杂，代码集中在 `lib/orchestration/` 与 `engine/phone/`，第 12 节展开。

## 11. 连接与协议层

### 11.1 后端矩阵

| 后端 | 代码 | 协议 | 用途 |
| --- | --- | --- | --- |
| OpenCode 2 | `lib/api2/` | HTTP + SSE | 主后端，内置或远程 |
| Codex | `lib/codex/` | HTTP/JSON | OpenAI Codex 服务器 |
| Paseo | `lib/paseo/` | agent host 协议 | 第三方 agent host |
| ACP | `lib/acp/` | Agent Client Protocol | Gemini/Qwen 等 |
| A2A | `lib/a2a/` | Agent-to-Agent | agent 间调用 |
| 多后端编排 | `lib/orchestration/` | 适配器 | AI Team |

### 11.2 传输层约束

`api2/transport.dart` 的硬约束：

- `connectTimeout = 8s`，`requestTimeout = 2min`，长轮询 `10min`。
- **永远不跟随重定向**：`followRedirects = false`、`maxRedirects = 0`。原因写在代码里——同意是按源给的，重定向会把凭据带去另一个源，或把 https 降级成 http。
- 非回环的 http 源需要**按 profile、按源**的显式同意；同意记录随 profile 删除。
- 每个 profile 有自己的凭据；Keystore 存值，prefs 只存引用。

### 11.3 事件模型

- SSE 为主，断线后 `quiet_reconnect.dart` 退避重连，不打断正在读的会话。
- 事件带序号，`session_cache.dart` 去重与补齐。
- 长轮询用于不支持 SSE 的部署。
- 所有事件解析失败都写 `app_log`，不吞异常。

### 11.4 方言差异

`dialect.dart` 把"同一个概念在不同后端的字段差异"收在一处：消息角色、工具调用结构、权限请求格式、停止语义。新增后端时优先加方言，不要在 UI 里判断后端类型。

## 12. AI Team 与 Rust 引擎

### 12.1 分层

```
Flutter（lib/orchestration）
  → MethodChannel（oc/team）
  → Kotlin 宿主（PhoneAgentHost、NativeWorkLeaseHost）
  → 子进程 oc-engine（libaiteam_engine.so）
  → HTTP /v1/*（回环）→ SQLite + git
```

### 12.2 引擎模块

| 文件 | 职责 |
| --- | --- |
| `main.rs` / `daemon.rs` | 启动、6 条路由、优雅退出 |
| `store.rs` | SQLite：`workspace`、`jobs`、`commands`、`events`、`meta` |
| `repository.rs` | git 仓库：提交、合并、工作树、搜索 |
| `scheduler.rs` | 任务调度与重试计划 |
| `chat.rs` | 会话消息存取 |
| `opencode.rs` / `opencode2.rs` | 对接 OpenCode 两种 API |
| `boundary.rs` | 路径边界：只允许工作区内写入 |
| `attestation.rs` | ECDSA 证明：二进制未被替换 |
| `admission.rs` | 作业准入：并发、配额、所有权 |
| `config.rs` / `startup.rs` | 配置与启动自检 |

### 12.3 六条路由

```
GET    /v1/health      健康与版本
GET    /v1/workspace   工作区快照
POST   /v1/commands    执行命令（带指纹去重）
POST   /v1/chatBusy    "还有活在跑吗"
GET    /v1/events      事件流（保留上限 10,000 条）
DELETE /v1/profile     删除配置
```

`commands` 表按 `fingerprint` 去重，保证重试不会重复执行副作用命令；`event_retention` 记录已裁剪到的序号，客户端可判断"我落后太多，需要全量同步"。

### 12.4 存储可靠性

`store.rs` 打开数据库时固定：

```sql
PRAGMA journal_mode=WAL;
PRAGMA synchronous=FULL;
PRAGMA secure_delete=ON;
```

`FULL` 牺牲写入速度换崩溃一致性；`secure_delete` 让删除的会话内容不留在空闲页里。事务用 `Immediate` 避免写升级死锁。

### 12.5 二进制供应链

- `.so` 提交在 `android/app/src/main/jniLibs/arm64-v8a/`，构建 APK 不需要 Rust 工具链。
- `assets/aiteam-engine-manifest.json` 记录每个 `.so` 的 SHA-256；`tool/qa/verify_phone_engine_apk.py` 在 `assembleRelease` 前校验**APK 里的实际字节**，不是只看源目录。
- 运行时 `attestation.rs` 再做一次自检：哈希不符拒绝启动。
- 改引擎源码后必须手动跑 `engine.yml`，把新 `.so` 与 manifest 一起提交；只改源码不更新二进制会被 APK 校验拦下。

## 13. 状态管理与 UI

### 13.1 两套状态

| 层 | 技术 | 范围 |
| --- | --- | --- |
| 连接会话 | `ConnectionController extends ChangeNotifier` | 服务器、会话、事件、权限、队列 |
| 应用偏好 | Riverpod providers | 主题、语言、开关、列表 |

不统一成 Riverpod 是历史选择：连接对象生命周期长、mixin 多、监听者需要细粒度 `notifyListeners`，迁到 Riverpod 收益不大、风险很高。

### 13.2 ConnectionController 的 36 个 mixin

`connection.dart` 只留字段与核心循环，能力拆在 `lib/state/connection/` 的 54 个 part 文件里：

| 关注点 | mixin（部分） |
| --- | --- |
| 连接 | `Connect`、`Lifecycle`、`QuietReconnect`、`SideConnections` |
| 会话 | `Sessions`、`SessionCache`、`SessionEvents`、`SessionNotes`、`ChatFeed` |
| 交互 | `Permissions`、`Questions`、`FormsInbox`、`Revert`、`Queue`、`Drafts` |
| 展示 | `Catalog`、`Models`、`Status`、`Activity`、`Attention` |
| 扩展 | `Team`、`PhoneChat`、`PhoneAgents`、`GenUi`、`McpChat`、`Worktrees` |
| 设置 | `Settings`、`Locations`、`Alerts`、`ReadState`、`Deletion` |

改动建议：先找 mixin，再改；不要往 `connection.dart` 本体塞新逻辑，它会迅速变成上帝对象。

### 13.3 Kit 设计系统

- `kit.dart` 是导出面；`kit_buttons.dart`、`kit_field.dart`、`kit_card` 系列是原子件；`chat/`、`diff/`、`glass/` 是复合件。
- 颜色、间距、圆角、动效都走 token，不写魔法数。
- 深色、Material You 取色、玻璃层（`glass/`）共用一套角色色。
- 文字用 Geist / Geist Mono（可变字体，支持 550/650 权重），图标用 Phosphor 三套字重。
- 空态/错误态统一走 `kit_error_fallback.dart`，并挂"报告问题"入口。

### 13.4 页面组织

`screens/` 按功能分：`chat/`（对话、输入、附件）、`chats/`（列表）、`settings/`、`team/`、`library/`、`files/`、`terminal/`、`scheduling/`、`servers/`、`agents/`、`phone_setup/`。每个目录的第一层文件通常就是该功能的入口页。

## 14. 供应商与模型

### 14.1 两层概念

| 概念 | 文件 | 说明 |
| --- | --- | --- |
| 内置模板 | `builtin_provider_templates.dart`（25 个） | 应用自带的供应商清单，含默认 base URL、协议、图标、模型来源 |
| 自定义供应商 | `domain/custom_provider.dart` | 用户添加，存成 v1/v2 两种配置文档 |

模板 25 个覆盖主流直连与聚合网关；每个模板都能"规范化后原样通过"，即保存再读回不丢字段（有测试守住）。

### 14.2 配置写入

`builtin_provider_store.dart` 把供应商写进 OpenCode 的配置文件：

- v2 用 `settings.headers`，v1 用 `options.headers`。
- provider id 规则、npm 包名（v1 裸名、v2 带 `aisdk:` 前缀）。
- 模型勾选写成 `disabled`/`blacklist`，未勾选的不写入。
- key 以文件引用保存，不把明文复制进配置。
- 写完 reload 服务器配置，失败有明确错误（不是"没反应"）。

### 14.3 模型列表

`provider_model_source.dart` 按失败模式重建过：

1. 有 `/models` 先试，返回不是列表则退到 `/v1/models`。
2. 地址缺 scheme 自动补 https。
3. 第一个地址返回 HTML（网页）时，试下一个拼写。
4. 记录所有尝试过的候选，失败时展示"试过哪些"，而不是一句"加载失败"。

### 14.4 配额与余额

`quota/` + `tool/quota/*.mjs`：可选采集器在 Ubuntu 里跑，或对已保存的电脑执行一次性只读检查。采集结果落到小组件（5 小时/本周剩余百分比）。

### 14.5 参数兼容

`provider_parameter.dart` 识别供应商拒绝的参数（temperature、max_tokens、reasoning budget、tool_choice），把"被拒绝"与"其他失败"分开，避免把 400 当成网络错误重试。

## 15. 定时任务、小组件与后台

### 15.1 定时提示

- Dart 侧 `lib/scheduling/`：模型、重复规则、存储、执行器。
- Kotlin 侧 13 个 `ScheduledPrompt*`：AlarmManager 精确闹钟 + WorkManager 兜底，`BOOT_COMPLETED` / `MY_PACKAGE_REPLACED` / 时区变化后重排。
- 执行结果分三类：已开始、失败、跳过，通知带早间摘要（`native_schedule_digest_*`）。
- 幂等：`ScheduledPromptClaims` + `Receipts` 防重复触发；`Recovery` 处理错过的时间点。

### 15.2 小组件

| 组件 | 布局 | 内容 |
| --- | --- | --- |
| Conversations | 4×2 | 最近会话、状态、允许/回复按钮 |
| Conversations wide | 宽版 | 同上，更多列 |
| Conversations list | 列表 | 多行会话 |
| Conversations strip | 条状 | 单行 |
| Usage | 2×2 | 5 小时/本周配额 |
| Usage wide | 宽版 | 多供应商 |
| Status | 2×2 | 服务器/Linux/任务状态 |

渲染在 Kotlin 里直接构造 `RemoteViews`（不走 Flutter），所以应用被杀也能刷新；`WidgetCardRenderTest` 用 Robolectric 把真实布局渲染成图片做断言。小组件按钮操作走 `WidgetActionReceiver` → `WidgetActionRunner`，带租约与幂等票据。

### 15.3 通知与磁贴

- `StatusNotificationRenderer` 负责实时更新（Android 16 QPR1 的 promoted chip 需要 `POST_PROMOTED_NOTIFICATIONS`）。
- 审批按钮直接回传，不必打开应用。
- 磁贴：待处理计数、暂停/恢复后台。

### 15.4 后台保活

- `BackgroundConnectionService` 前台服务 + 通知，用户可暂停。
- `PauseTileService` 与通知按钮是同一个暂停开关，状态存 `BackgroundPauseStore`。
- `NativeWorkLeaseHost` 保证"有活在跑"时不空闲停止；`ThermalMonitor` 过热时降载并提示。

## 16. 安全与隐私

### 16.1 凭据

- 服务器密码、API key 存 `flutter_secure_storage`（Android Keystore）。
- 配置文件里只存**引用**（key 文件名），不复制明文。
- `provider_parameter` 与日志层都有脱敏：`app_log_test.dart` 断言"凭据字段永不落盘"。
- 生物识别（`local_auth`）保护敏感操作入口。

### 16.2 传输

- 明文仅限用户显式同意的源；`network_security_config.xml` 的 `cleartextTrafficPermitted="true"` 是平台限制下的最窄设置，真正的边界在 Dart（逐源同意 + 禁止重定向）。
- manifest 里删掉了误导性的 `usesCleartextTraffic="false"`——它在 API 24+ 会被 NSC 覆盖，留着只会让人误以为强制 TLS。
- TLS 自签证书：`provider_tls.dart` 支持按 profile 信任指定证书（测试里有自签证书夹具），不做全局"忽略证书错误"。

### 16.3 进程与边界

- AI Team 引擎的 `boundary.rs` 限制写入路径，`admission.rs` 限制并发与所有权。
- `attestation.rs` 校验二进制哈希，防替换。
- PDF 渲染在独立进程 `:local_pdf`，崩溃不影响主进程。
- WebView 预览限制导航与外部内容；SVG 先静态校验再渲染。

### 16.4 数据

- `allowBackup="false"`，`dataExtractionRules` / `backup_rules` 明确排除敏感目录。
- 日志：JSONL，8 MB 上限、保留 7 天，公共镜像目录 `OpenCodePlus/logs`（可导出，导出前提示含路径信息）。
- 崩溃报告本地保存，用户主动分享才外发。
- 隐私说明在 `PRIVACY.md`，随应用打包（`assets` 里列了它）。

### 16.5 权限清单（18 条）

`INTERNET`、`ACCESS_NETWORK_STATE`、`RECEIVE_BOOT_COMPLETED`、`SCHEDULE_EXACT_ALARM`、`POST_NOTIFICATIONS`、`POST_PROMOTED_NOTIFICATIONS`、`FOREGROUND_SERVICE`、`FOREGROUND_SERVICE_DATA_SYNC`、`FOREGROUND_SERVICE_SPECIAL_USE`、`WAKE_LOCK`、`REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`、`RECORD_AUDIO`、`CAMERA`、`MANAGE_EXTERNAL_STORAGE`、`READ_EXTERNAL_STORAGE`（≤32）、`WRITE_EXTERNAL_STORAGE`（≤29）、`com.termux.permission.RUN_COMMAND`、`MANAGE_DOCUMENTS`（provider 权限）。

敏感权限都是"用到才要"：存储权限在打开共享目录项目时才申请，相机在扫码/拍照时才申请，不在启动时一次性索取。

## 17. 数据与路径

### 17.1 应用私有目录

```
/data/data/com.azx8788.opencode.mini/
  files/           项目、导出、日志镜像
  cache/           临时下载
  shared_prefs/    oc.* 偏好
```

### 17.2 Ubuntu 内路径

```
/root/.oc-builtin/server.password     服务器密码（root only）
/root/.oc-opencode2/{data,cache,state,config}   OpenCode 2 的 XDG
/root/.local/share/oc-agents/<id>/    agent 安装目录
/root/.oc-aiteam/                     AI Team 工作区与引擎状态
```

### 17.3 共享存储

- `OpenCodePlus/logs`：日志公共镜像（旧版是 `OpenCodeMini/logs`）。
- Termux 项目：两边共享，不属于任一应用。
- 共享目录项目：需要 All files access，按需申请。

### 17.4 引擎数据库

`oc-engine.db`（WAL）：

| 表 | 键 | 内容 |
| --- | --- | --- |
| `meta` | 单行 | 删除标记 |
| `workspace` | 单行 | 工作区 JSON 快照 |
| `jobs` | job id | 任务 |
| `commands` | command id + fingerprint | 命令结果（幂等） |
| `events` | 自增序号 | 事件（上限 10,000） |
| `event_retention` | 单行 | 已裁剪序号 |

## 18. 本地化与设计系统

### 18.1 Flutter 侧

- `l10n.yaml` 配置 `app_en.arb` / `app_zh.arb`，`flutter gen-l10n` 生成 `app_localizations*.dart`（3 个文件，12.9 万行）。
- 键数 9622，两种语言严格同键；`mini_l10n_catalogue_test.dart` 断言"每条英文都有中文"。
- 语言选择存 `app_locale.dart` 的 `supportedLanguages = {'en','zh'}`，与原生 `NativeStrings.supported` 由测试强制一致。
- 产品名统一 `OpenCode Plus`，测试断言两个语言都带这个名称。

### 18.2 Android 原生侧

通知、小组件、磁贴、快捷方式的文案不走 ARB，走 `res/values*/`。当前共 **220 条**，分布在 5 个文件：

| 文件 | 条数 | 内容 |
| --- | --- | --- |
| `strings.xml` | 148（143 string + 5 plurals） | 通知、磁贴、快捷方式、小组件通用 |
| `widget_v2_strings.xml` | 63 | 小组件按钮、状态、相对时间、预览 |
| `scheduled_prompts.xml` | 7 | 定时提示通知 |
| `bb_idle_strings.xml` | 1 | 空闲暂停通知 |
| `widget_v2_bridge_strings.xml` | 1 | 小组件覆盖层 toast |

`values-zh/` 逐文件对应，`values-ar/` 是上游遗留（应用不提供阿拉伯语，`NativeStrings` 不选它）。`test/native_strings_test.dart` 现在按文件比对：键集合、格式参数、复数只允许 `other`——上一轮审计只比了 `strings.xml`，漏掉另外 72 条，这一轮补上并把测试改成"全目录"，同类遗漏不会再发生。

### 18.3 视觉

- 字体：Geist（正文）/ Geist Mono（代码、路径、命令），可变字重。
- 图标：Phosphor Regular/Duotone/Fill（MIT）。
- 供应商图标：`assets/marks/*.svg`（lobe-icons，MIT）。
- 主题：Material 3 + 动态取色 + 玻璃层；深色有独立资源目录 `values-night`。
- 动效：`kit_effects.dart`、`kit_arrival.dart` 统一时长与曲线。

## 19. 原生层组件清单（Kotlin 169 文件）

按职责域分组。文件名本身就是文档，改某块前先看同域其他文件，通常已有约定。

### 19.1 应用与生命周期（12）

`OcApplication`、`MainActivity`、`MainActivityBackground`、`MainActivityBackgroundChannel`、`MainActivityBuiltinSupport`、`MainActivityMedia`、`AppLifecycle`、`AppExitHistoryPolicy`、`ManageSpaceActivity`、`LaunchActivityBridge`、`NativeComponentUpdateRecovery`、`NativeCrashStore`、`CrashDiagnosticsBridge`。

`MainActivity` 只做壳：接收 intent、转发 URI/分享/快捷方式到 Dart，不承载业务。

### 19.2 内置 Linux、安装与服务器（34）

`BuiltinLinux`、`BuiltinServerService`、`BuiltinProjectStorage`、`BuiltinGitConfig`、`BuiltinRestoreReceiver`、`BuiltinIdleReceiver`、`BuiltinInstallerProducerQaService`、`NativeInstallerAdmission`、`NativeInstallerOwnership`、`NativeInstallerVisibility`、`NativeServerRecipe`、`NativeServerRestoreEvent`、`SetupJob`、`SetupPersistence`、`SetupRunner`、`SetupService`、`SetupScriptCompletion`、`SetupStepRetry`、`SetupWorkScopes`、`NativeRuntimeOwnership`、`NativeRecoveryBudget`、`NativeOrphanReaper`、`NativeOrphanReaperHost`、`NativeProcessList`、`NativeProcessTree`、`NativeProcRace`、`NativeProcScan`、`NativeEngineReadiness`、`NativeWorkLeaseHost`、`WorkLeases`、`NativeIdleState`、`NativeIdleTimer`、`NativeIdleHeartbeat`、`IdleStopPolicy`、`RestartBackoff`、`ThermalMonitor`、`ServiceDiagnostics`。

### 19.3 Agent 主机与登录（19）

`PhoneAgentHost`、`PhoneAgentPaths`、`PhoneAgentInventory`、`PhoneAgentSignIn`、`PhoneAgentClaudeHome`、`PhoneAgentChecks`、`PhoneAgentCheckOutput`、`PhoneAgentAuthRequest`、`PhoneAgentAuthRuntime`、`PhoneAgentAuthProbe`、`PhoneAgentAuthInventory`、`PhoneAgentAuthDeadline`、`PhoneAgentAuthLock`、`PhoneAgentAuthJson`、`PhoneAgentAuthCapture`、`PhoneAgentAuthColdOwner`、`PhoneAgentAuthOtherOwners`、`PhoneAgentAuthProcessTree`、`PhoneAgentAuthProjection`、`NativeAgentHostAdmission`。

### 19.4 引擎与证明（5）

`PhoneEngineNative`、`PhoneEngineAttestation`、`PaseoStaleLock`、`ByoHostSigner`、`ByoHostAgentProtocol`。

### 19.5 终端与 Termux（12）

`LocalTerminal`、`TermuxResultService`、`TermuxActivityBridge`、`TermuxActivityCommands`、`TermuxActivityEnvironment`、`TermuxActivityPermissions`、`TermuxActivitySetup`、`TermuxSetupRunner`、`TermuxSetupShell`、`LocalPdfBridge`、`LocalPdfService`、`ProjectExportBridge`。

### 19.6 通知、磁贴与审批（14）

`StatusNotification`、`StatusNotificationModel`、`StatusNotificationRenderer`、`StatusActionReceiver`、`CodingAlertRequest`、`CodingActionReceiver`、`LivePauseReceiver`、`AttentionTileService`、`PauseTileService`、`NativeNotificationLocale`、`NativeStrings`、`NativeIdleReturnNotification`、`NativeIdleReturnNotificationHost`、`VoiceDownloadNotifications`。

### 19.7 小组件（38）

`SessionsWidgetProvider`、`SessionsWideWidgetProvider`、`SessionsListWidgetProvider`、`SessionsStripWidgetProvider`、`UsageWidgetProvider`、`UsageWideWidgetProvider`、`StatusWidgetProvider`、`WidgetProviders`、`WidgetConfigureActivity`、`WidgetRouteActivity`、`WidgetOverlayActivity`、`WidgetOverlaySession`、`WidgetOverlayStyle`、`WidgetActionReceiver`、`WidgetActionBridge`、`WidgetActionLease`、`WidgetActionPolicy`、`WidgetActionRuntime`、`WidgetActionSnapshot`、`WidgetCopy`、`WidgetGraphite`、`WidgetLayoutPolicy`、`WidgetLayoutRules`、`WidgetStatusIdentity`、`WidgetStatusPolicy`、`WidgetStatusScheduler`、`WidgetStatusTickets`、`WidgetStatusWorker`、`WidgetStatusModel`、`WidgetV2Bridge`、`WidgetV2Policy`、`WidgetV2Style`、`SessionWidgetActions`、`SessionWidgetCardBinder`、`SessionWidgetIntents`、`SessionWidgetRenderer`、`SessionWidgetRowEnv`、`SessionWidgetStripBinder`、`ConversationsWidgetBinder`、`UsageWidgetFit`、`UsageWidgetPlans`、`UsageWidgetRenderer`、`UsageWidgetRow`、`UsageWidgetRows`、`UsageWidgetText`、`BackgroundWidgetActionController`。

小组件单独有一套"布局策略/身份/票据"文件，因为 RemoteViews 的限制（没有 Flexbox、刷新有配额、点击要 PendingIntent）需要专门处理。

### 19.8 定时提示（13）

`ScheduledPromptChannel`、`ScheduledPromptCalendar`、`ScheduledPromptCalls`、`ScheduledPromptClaims`、`ScheduledPromptNotifications`、`ScheduledPromptPhoneLease`、`ScheduledPromptPolicy`、`ScheduledPromptReceipts`、`ScheduledPromptRecovery`、`ScheduledPromptRuntime`、`ScheduledPromptScheduler`、`ScheduledPromptSettlement`、`ScheduledPromptStore`、`ScheduledPromptWorker`。

### 19.9 其余

`BackgroundConnectionService`、`BackgroundPauseReceipt`、`BackgroundPauseStore`、`NetworkMonitor`、`TailscaleHandoff`、`SessionLinkIngress`、`PinnedSessionShortcuts`、`LaunchLinkChannel`、`LaunchShareChannel`、`LaunchShortcutChannel`、`InternalStorageProvider`、`StorageAccess`、`ReadAloudBridge`、`AndroidGroupNames`、`LocalTerminal`。

## 20. Rust 引擎模块与测试矩阵

### 20.1 源码 14 个

`main.rs`、`lib.rs`、`daemon.rs`、`startup.rs`、`config.rs`、`store.rs`、`repository.rs`、`scheduler.rs`、`chat.rs`、`opencode.rs`、`opencode2.rs`、`boundary.rs`、`attestation.rs`、`admission.rs`；`bin/` 下两个探针：`oc-engine-sandbox.rs`、`oc-engine-boundary-probe.rs`。

### 20.2 测试 20 个文件 / 149 个集成用例

| 测试文件 | 用例 | 验证什么 |
| --- | --- | --- |
| `store_durability.rs` | 27 | 崩溃、半写、重开后的数据一致性 |
| `repository_authority.rs` | 27 | 谁有权改仓库、并发提交 |
| `attestation.rs` | 10 | 签名与哈希证明 |
| `store_retry_plan.rs` | 9 | 失败任务的重试计划 |
| `repository_proot_objects.rs` | 9 | proot 下的 git 对象 |
| `repository_worker_recovery.rs` | 7 | worker 崩溃后恢复 |
| `store_scheduler.rs` | 7 | 调度状态机 |
| `repository_merge_journal.rs` | 6 | 合并日志 |
| `store_restart_reconciliation.rs` | 6 | 重启后对账 |
| `store_planner_projection.rs` | 5 | 计划投影 |
| `store_resolved_models.rs` | 5 | 模型解析结果 |
| `task_workflow.rs` | 5 | 任务全流程 |
| `boundary_kernel.rs` | 4 | 路径边界 |
| `daemon_startup.rs` | 4 | 启动与路由 |
| `startup_reporting.rs` | 4 | 启动自检上报 |
| `store_merge_projection.rs` | 4 | 合并投影 |
| `store_review_acceptance.rs` | 4 | 审阅接受 |
| `boundary_proof.rs` | 3 | 边界证明 |
| `status_fallback.rs` | 3 | 状态兜底 |
| `repository_search_ancestors.rs` | 2 | 祖先搜索 |

加上 `src` 内联单元测试，共 233 个。运行方式：

```sh
cargo test --manifest-path engine/phone/Cargo.toml --locked --no-fail-fast -- --test-threads=1
```

`--test-threads=1` 是必须的：测试会碰真实文件系统与 git，并行会互相干扰。

## 21. 测试清单（Dart 27 文件 / 277 用例）

| 文件 | 用例 | 覆盖 |
| --- | --- | --- |
| `agent_endpoint_test.dart` | 28 | 地址解析、端口/路径、拒绝非法 scheme/query/user |
| `custom_provider_test.dart` | 39 | 供应商配置 v1/v2、协议→包名、base URL、模型表 |
| `provider_model_source_test.dart` | 26 | 模型列表多候选、HTML 误返回、scheme 补全 |
| `provider_server_test.dart` | 19 | 供应商服务器身份与启动脚本 |
| `provider_parameter_test.dart` | 17 | 被拒绝的参数分类 |
| `builtin_provider_store_test.dart` | 13 | 配置写入、v2 目录、脚本有效性 |
| `custom_provider_headers_test.dart` | 12 | 自定义 header 在 v1/v2 的位置 |
| `app_log_test.dart` | 8 | JSONL、脱敏、按日滚动、并发打开 |
| `builtin_provider_templates_test.dart` | 8 | 模板唯一性、规范化幂等 |
| `bump_version_test.dart` | 9 | 版本解析/递增/改写、发布脚本契约 |
| `custom_provider_disabled_models_test.dart` | 9 | disabled/blacklist 写法 |
| `model_library_enabled_test.dart` | 9 | 模型库隐藏与持久化 |
| `provider_balance_test.dart` | 9 | 余额 JSON 路径与请求 |
| `kit_field_secret_mask_test.dart` | 8 | 密钥输入掩码 |
| `mini_package_test.dart` | 7 | 资源存在、ABI、包名与标签 |
| `provider_tls_test.dart` | 7 | 自签证书信任 |
| `custom_provider_record_test.dart` | 6 | 记录读取、密钥引用 |
| `model_switch_fit_test.dart` | 6 | 模型能力与历史窗口 |
| `provider_list_entries_test.dart` | 6 | 供应商行合并顺序 |
| `mini_l10n_catalogue_test.dart` | 5 | 语言目录一致、英文都有中文 |
| `model_library_provider_test.dart` | 5 | 供应商级隐藏 |
| `native_strings_test.dart` | 5 | 原生文案逐文件对齐（本轮扩展） |
| `mini_agents_test.dart` | 4 | agent 配方哈希与 arm64 可装 |
| `team_planning_marker_test.dart` | 4 | 新旧 planning 标记兼容 |
| `mini_l10n_test.dart` | 3 | 仅 en/zh、产品名 |
| `token_count_format_test.dart` | 3 | token 数字格式 |
| `provider_google_test.dart` | 2 | Google 模型列表 |

原则：**测规则，不测像素**。UI 用 Robolectric 只渲染小组件（因为 RemoteViews 的坑多），其余靠 widget test 覆盖关键分支。

## 22. 构建、测试与发布

### 22.1 本地

```sh
flutter pub get
dart run tool/bump_version.dart          # 0.3.14+19 -> 0.3.14+20
flutter build apk --release --target-platform android-arm64
```

或一条命令（bump + build）：

```sh
tool/build_apk.sh            # 补丁位不变，build +1
tool/build_apk.sh --patch    # 0.3.15+20
tool/build_apk.sh --no-bump  # 不动版本
```

环境：Flutter 3.47.9、JDK 17、Android SDK 37、NDK 随 Flutter。Rust 不需要（`.so` 已提交）。

签名：有 `android/key.properties` 用 release key，没有就退 debug key（能编译、不能发布）。`key.properties.example` 是模板。

**本轮修复**：`tool/build_apk.sh` 原先把 `"$@"` 透传给 `flutter build`，`--patch` 会被 Flutter 当成未知选项，版本已 bump 但构建失败。现在参数只用于 bump，并加了测试锁住。

### 22.2 版本号规则

- 唯一来源 `pubspec.yaml` 的 `version: x.y.z+n`。
- 普通 bump 只加 `n`；`--patch/--minor/--major` 改语义版本且 `n` 仍增。
- `versionCode` 优先读 `OC_VERSION_CODE`，否则 `flutter.versionCode`。
- CI 设 `OC_VERSION_CODE = 100000 + GITHUB_RUN_NUMBER`，保证 CI 包永远高于本地包（Releases 是安装渠道）。

### 22.3 CI（`.github/workflows/build.yml`）

16 步：checkout → 设 versionCode → 读版本 → tag 校验 → JDK 17 → Flutter 3.47.9 → SDK licenses → 写签名 → `pub get` → `analyze` → `flutter test`（全量）→ 构建 arm64 release → 校验签名/ABI/产出 SHA256 → 上传 artifact → tag 时建 draft release。

只有 `main`/`master`/`v*` 触发；分支验证要临时改成自己的分支再改回（本轮做过一次，`ci/verify-20261115`）。

签名 secret 四个：`RELEASE_KEYSTORE_BASE64`、`RELEASE_KEYSTORE_PASSWORD`、`RELEASE_KEY_ALIAS`、`RELEASE_KEY_PASSWORD`。缺失时自动退 debug key，不失败。

### 22.4 引擎 CI（`engine.yml`）

手动触发：装 Rust + Android target → `cargo test` → `build-android.sh --stage-android` → 裁 manifest 只留 arm64 → 上传 `.so` 与 manifest。**这条流水线不会自动提交**，改完引擎要人工下载、提交二进制。

### 22.5 发布检查单

1. `dart run tool/bump_version.dart`
2. `flutter analyze`（0 error / 0 warning）
3. `flutter test`（277）
4. `flutter build apk --release --target-platform android-arm64` 或 CI
5. `apksigner verify --print-certs` 确认签名
6. `unzip -l` 确认无 32 位/模拟器 `.so`
7. 打 tag `v0.3.14`（必须与 pubspec 一致，CI 会拦）
8. draft release 里核对 SHA256SUMS

## 23. 依赖与权限清单

依赖见 5.1–5.3；这里只列容易被忽略的约束：

- `dynamic_color` 必须 1.x：2.x 返回 `package:material_ui` 的 `ColorScheme`，类型不兼容。
- `flutter_secure_storage` 11.x 升级会丢旧凭据（跳过 1.0.31 的安装），发布说明要提醒重新配对。
- `mobile_scanner` 捆绑 ML Kit 模型，APK 变大但无 Play 服务可用。
- `desktop_drop` 在 Android 上不激活，但会多一个 Gradle 子工程与 KGP 警告。
- `xterm` 是本地路径依赖，改动要同步 `third_party/xterm`。

权限与组件见 16.5 与 manifest；`queries` 里声明了 Termux、Tailscale、TTS、PROCESS_TEXT，Android 11+ 才能看到这些包。

## 24. 常见改动指南

| 想做什么 | 改哪里 | 别忘了 |
| --- | --- | --- |
| 改一条界面文案 | `lib/l10n/app_en.arb` + `app_zh.arb` | `flutter gen-l10n`；跑 `mini_l10n_catalogue_test` |
| 加一条通知/小组件文案 | `res/values/*.xml` + `values-zh/` 同名文件 | 占位符一致；跑 `native_strings_test` |
| 加供应商模板 | `builtin_provider_templates.dart` | 规范化幂等测试；图标放 `assets/marks/` |
| 加 agent | `domain/agent_catalog.dart` | 真实 SHA-256、arm64 产物、`mini_agents_test` |
| 改协议/字段 | `api2/dialect.dart` 的方言 | 不要按后端类型在 UI 分支 |
| 改连接行为 | `state/connection/` 对应 mixin | 别动 `connection.dart` 本体 |
| 加页面 | `ui/screens/<域>/` | 用 Kit 原子件；错误态挂 report hook |
| 改引擎 | `engine/phone/src/` | `cargo test`；跑 `engine.yml` 更新 `.so` 与 manifest |
| 改版本 | `tool/bump_version.dart` | 不要手改 `pubspec.lock` |
| 改原生通知 | `StatusNotification*` / `ScheduledPrompt*` | 中文文案同步；磁贴计数 |

## 25. 故障排查手册

| 症状 | 先看 | 常见原因 |
| --- | --- | --- |
| 新 APK 装不上（"未安装"） | 两个包的 `versionCode` | 没 bump；CI 包与本地包混装 |
| 内置服务器起不来 | `ServiceDiagnostics`、`app_log` | 密码文件缺失（exit 78）、端口被占、rootfs 不完整 |
| 服务器反复重启 | `RestartBackoff`、`NativeOrphanReaper` 日志 | 崩溃循环、孤儿进程抢锁、租约未释放 |
| 中文界面但通知是英文 | `values-zh/` 是否缺文件 | 语言未选、资源文件漏译（本轮修了 72 条） |
| 小组件不刷新 | `WidgetStatusWorker`、电池优化 | 刷新配额、后台被限制、租约过期 |
| 定时提示不触发 | `ScheduledPromptScheduler`、精确闹钟权限 | 厂商 ROM 杀后台、时区变化未重排 |
| 模型列表加载失败 | `provider_model_source` 的尝试记录 | 地址少 scheme、返回 HTML、key 无效 |
| 审批按钮没反应 | `pending_command_journal` | 应用被杀、通知过期、服务器已断 |
| 终端键盘变成密码框 | `MainActivity` 输入类型 | 终端视图未设 `visiblePassword` |
| AI Team 启动失败 | `attestation`、manifest 哈希 | `.so` 与 manifest 不一致、ABI 不对 |
| CI 构建失败 | 第几步 | Flutter 版本、Kotlin/AGP、keystore secret、tag 与 pubspec 不符 |

日志位置：应用内"诊断 → 日志"，或 `/storage/emulated/0/OpenCodePlus/logs`（公共镜像），每条是 JSON，含步骤名与时间。

## 26. 分支、验证与边界

### 26.1 当前分支状态

| 分支 | 提交 | 说明 |
| --- | --- | --- |
| `main` | `0355410` | 远端主线，未改动 |
| `audit/quality-fixes-20261115` | 本轮整改 | 46 文件 +830/−135，已推送 |
| `ci/verify-20261115` | 已删除 | 临时触发 CI 用 |

整改提交序列：`74a75a2`（主体）→ `f4f1487`、`036482e`（CI 表达式）→ `900cde1`（README 中英对齐）→ `82e1c5d`（日志目录改名）→ 本轮（文档 + 原生小组件中文 + 构建脚本修复）。

### 26.2 已验证

- `flutter analyze`：0 error / 0 warning（1 条既有 `ref.exists` 弃用 info）。
- `flutter test`：277 通过（本轮新增 1 条构建脚本契约，原生文案测试扩展）。
- CI run `43700051452`：16 步 15 通过 1 跳过（签名步骤因无 secret 跳过），`versionCode=100079`，`application-label='OpenCode Plus'`，release key 签名。
- 本地 release APK 构建成功；APK 内实测 `native_allow_once="允许一次"`。
- APK 内 ABI 只有 `arm64-v8a`；`libaiteam_*.so` 哈希与 manifest 一致。

### 26.3 未验证（需真机）

- 首次安装 Ubuntu 的下载中断恢复。
- 通知在中文 ROM 上的排版（长文本、折叠、大字号）。
- 覆盖升级（0.3.13 → 0.3.14）是否保留服务器与 rootfs。
- 小组件在 Lawnchair/ColorOS/One UI 上的尺寸与点击。
- AI Team 多 agent 真机协作与边界证明。
- 远程连接在弱网/切换网络下的重连。
- 语音识别模型下载与离线识别质量。

### 26.4 已知限制

- 只有 arm64，32 位设备与模拟器装不上（有意）。
- 只有中英双语；`values-ar` 是遗留资源，不会被选中。
- 不构建桌面端，但 `desktop/`、`window_manager` 代码仍在（上游遗留）。
- 文档站、widgetbook、设备 QA 套件不在本仓库；`pubspec.yaml` 注释里引用的 `docs/qa/...`、`docs/design/...` 在上游，本仓库没有。
- AI Team 引擎二进制靠人工提交，源码改了但忘记跑 `engine.yml` 会被构建拦下。

## 27. 阅读导引

按目的选路线：

| 目的 | 路线 |
| --- | --- |
| 搞懂应用怎么跑起来 | 8 → 9 → 10 |
| 改界面 | 13 → 7.5 → `lib/ui/kit/kit.dart` |
| 接一个新后端 | 11 → `api2/dialect.dart` → `api2/transport.dart` |
| 改供应商/模型 | 14 → `domain/custom_provider*.dart` |
| 改 AI Team | 12 → `engine/phone/src/daemon.rs` → `store.rs` |
| 查安全问题 | 16 → `SECURITY.md` → `api2/transport.dart` |
| 发版 | 22 → `tool/bump_version.dart` → `build.yml` |
| 接手维护 | 全文，重点 7、19、20、24、25 |

## 28. 代码量指标

| 范围 | 文件 | 行数 |
| --- | ---: | ---: |
| `lib/ui` | 722 | 280,279 |
| `lib/state` | 215 | 68,410 |
| `lib/domain` | 190 | 41,547 |
| `lib/builtin` | 79 | 27,052 |
| `lib/orchestration` | 44 | 12,144 |
| `lib/api2` | 31 | 10,334 |
| `lib/termux` | 22 | 9,442 |
| `lib/paseo` | 34 | 9,064 |
| `lib/background` | 14 | 4,547 |
| `lib/voice` | 14 | 4,364 |
| `lib/diagnostics` | 10 | 3,371 |
| `lib/platform` | 18 | 2,797 |
| `lib/main_parts` | 7 | 2,275 |
| `lib/scheduling` | 9 | 1,744 |
| `lib/codex` | 5 | 2,549 |
| 其余 lib | 33 | 4,236 |
| **Dart 合计** | **1442** | **614,977** |
| 其中生成 l10n | 3 | 129,415 |
| Kotlin | 169 | 25,512 |
| Rust | 36 | 19,229 |
| Dart 测试 | 27 | 4,670 |

## 29. 版本历史（近期）

| 版本 | 主题 |
| --- | --- |
| 0.3.14+19 | 原生中文补齐、发布脚本落地、改名收尾、CI 跑全量测试 |
| 0.3.13+18 | Claude Code 网关与登录答案统一 |
| 0.3.13+17 | 模型窗口不再一律 200K；日志可读性 |
| 0.3.12+16 | 供应商选择写入 Claude 设置 |
| 0.3.11+15 | AI Team 适配 OpenCode 2.1.1 |
| 0.3.10+14 | 国产 ROM 键盘替换问题 |
| 0.3.9+13 | 登录页文案纠正 |
| 0.3.8+12 | Claude Code 支持非账号方式 |
| 0.3.7+11 | 键盘到端点的两条死路 |
| 0.3.6+10 | Providers 成为独立窗口 |
| 0.3.5+9 | 改供应商不生效的三个原因 |
| 0.3.4+8 | 供应商模型裁剪 |
| 0.3.3+7 | 模型列表抓取重建 |
| 0.3.2+6 | 新增三个供应商 |
| 0.3.1+5 | 供应商统一为一套清单 |
| 0.3.0+4 | Providers 成为一级分区 |
| 0.2.0+3 | 供应商可管理 |
| 0.1.1+2 | token 用量显示在输入框下 |
| 2.1.0+57 | 两个小组件、Git、工作树 |
| 2.0.0+56 | 应用关闭也能跑的定时提示、开发服务器 |
| 1.4.0+54 | 可操作 agent 的小组件 |
| 1.3.0+53 | Claude Code 的 Files/Changes/Terminal/Worktrees |

更早的 1.0.x 是上游 OpenCode Mobile 的历史，保留在 `CHANGELOG.md`。

## 30. 术语表

| 术语 | 含义 |
| --- | --- |
| profile | 一套服务器配置（地址、凭据、同意记录） |
| 内置服务器 | 应用自己装 Ubuntu 并运行的 OpenCode 2 |
| rootfs | proot 里的 Ubuntu 根文件系统 |
| 租约（lease） | "还有活在跑"的所有权声明，空闲停止的前提 |
| 票据（ticket/receipt） | 幂等标识，防重复执行 |
| 方言（dialect） | 同一概念在不同后端字段的映射 |
| 边界（boundary） | AI Team 引擎允许读写的路径范围 |
| 证明（attestation） | 二进制哈希 + ECDSA 签名校验 |
| Kit | 自研设计系统的组件前缀 |
| 快照（snapshot） | 小组件/通知拿到的当前状态副本 |

## 31. 说明与边界

- 本文档描述的是 `audit/quality-fixes-20261115` 分支的状态；合并到 `main` 后，除提交号外内容仍适用。
- 代码量、文件数为脚本统计（`find` + `wc -l`），随代码变化会有出入；比例比绝对值更有意义。
- 第 26.3 节列出的未验证项不是"应该没问题"，是"确实没在真机上跑过"。
- 发现问题请按 `SECURITY.md` 走私密渠道，不要公开 issue 附利用细节。
