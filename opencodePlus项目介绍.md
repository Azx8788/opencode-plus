# OpenCode Plus 项目介绍

> 当前版本：`0.3.25+33`（2026-11-16）。本文是面向使用者和接手维护者的当前版本概览；
> `docs/PROJECT_OVERVIEW.md` 是 2026-11-15 的质量审计历史快照，其中的版本、代码量和测试数量不再是现值。

## 一句话定位

OpenCode Plus 是 **Android 专用（仅 arm64-v8a）的 Flutter 客户端**：既可以把电脑上的编码 agent 服务器接进手机，也可以在应用私有目录里装一套 Ubuntu 24.04（proot，无需 root），在手机本机跑 OpenCode 2、Claude Code、Codex、Gemini、Kilo、Cline、Goose 等 agent。目标是"一台手机就是开发终端"：对话、终端、审批、diff、文件预览、定时任务、小组件、语音输入和多 agent 协作都在同一个应用里。

它是 [OpenCode Mobile](https://github.com/Eslamasabry/opencode-mobile-next) 的裁剪衍生版，保留需要的部分，不持续合并上游。名字从 OpenCode Mini 改成 Plus，但 applicationId 仍是 `com.azx8788.opencode.mini`，旧安装可以原地覆盖升级，不会丢服务器配置和已经装好的 Ubuntu。

## 核心能力

- **连接**：手机内置服务器（回环 `127.0.0.1:4097`）、HTTP(S)/Tailscale/Termux/自带 SSH 主机、二维码配对、会话接力。非回环明文需要逐源显式同意，传输禁止跟随重定向。
- **Agent 运行时**：带 SHA-256 的固定安装配方，下载、校验、解包、落盘都可审计；登录、进程所有权、孤儿回收和空闲停止都有独立机制。
- **会话**：流式文本、思考块、工具卡片、权限审批、diff 与回退、文件预览、内置 PTY 终端、离线语音识别。
- **自动化**：定时提示、桌面小组件、快捷磁贴、通知审批、分享入口。
- **多 agent**：AI Team 编排与 Rust 引擎（SQLite + git + 边界证明），引擎 `.so` 随仓库提交并有哈希校验。

## 0.3.25 新增

### 1. 本机用量仪表盘

活动热力图、累计概览、7/30/90 天及全部时间的 Token 卡片、可切换图表与模型排行。成本、预算、供应商筛选与工具可靠性仍在详细用量里。趋势使用服务端聚合接口，至少两次并发读取、带缓存与过期保护，失败显示未知而不是补零；语言、时区、项目范围严格隔离。应用冷启动次数只从本版本开始记录。

详见 [LOCAL_USAGE_DASHBOARD.md](LOCAL_USAGE_DASHBOARD.md)。

### 2. 预览后确认的长期记忆

- 设置 → 对话 → 记忆：手动新增、编辑、停用、删除、搜索。
- 对话中可让 AI 总结当前会话，或使用会话菜单的总结入口；内容通过正常会话发送，不导出聊天文本另起一次请求。
- 内置 `oc-ui` MCP 的 `memory_write` 只提交候选：原生卡片提供预览，用户勾选、可编辑，点"保存所选记忆"才写入本机加密库。模型的"已保存"文字、普通 JSON 或代码块都不会触发写入。
- 记忆分全局与项目范围；项目身份按 profile、服务器地址和项目 ID 隔离。正文只存 `flutter_secure_storage`，偏好里只有存在标记。
- 发送时把已启用的适用记忆同步到独立的 `mobile.long-term-memory` 指令键；同步失败就不发送，不降级成提示词拼接。停用或删除只影响后续消息，不会改写已经发给服务器的旧内容。
- 不后台提取、不自动保存；不修改外部 MCP 服务器，也不为任何供应商写特例。

详见 [MEMORY.md](MEMORY.md)。

### 3. 耗时、缓存命中率与请求时间线

- 每条回答底部显示服务端记录的耗时、模型步数、生成速度、上下文 Token，以及最后一次请求的缓存命中率；点开可看精确数值。
- 会话菜单可打开两页：**耗时统计**（整段会话和逐条回答的阶段分布）与**请求时间线**（按模型步骤的真实记录）。
- 用量页另有跨会话的本机请求时间线，只记本应用已确认发送的时间、模型和会话 ID，不保存提示词正文，不虚构 API 密钥泳道；窗口可选 15 分钟 / 1 小时 / 6 小时。
- 所有阶段只使用服务器时间戳。流式窗口里没有单独文本边界的部分标成"未分类生成"，不猜成输出；缓存或时间缺失时显示未知，不填零。缓存命中率的分母是最后一次请求的输入侧 Token：`cacheRead / (input + cacheRead + cacheWrite)`，不含输出和推理。

详见 [CONVERSATION_PROCESS_CARDS.md](CONVERSATION_PROCESS_CARDS.md)。

## 数据与隐私边界

- 凭据和记忆正文存在 Android Keystore / `flutter_secure_storage`；普通偏好只放引用和存在标记。
- 请求日志有上限、串行写入；损坏的日志不会被当成空日志覆盖，必须显式清除。
- 用量统计把服务器未报告的项显式标成不可用：没有消息总数、没有请求来源占比、没有 API key 身份。
- `allowBackup=false`，备份规则排除敏感目录；日志本地 JSONL 滚动保存，导出前提示。详见 [PRIVACY.md](PRIVACY.md) 与 [SECURITY.md](SECURITY.md)。

## 代码地图

| 路径 | 作用 |
| --- | --- |
| `lib/ui/` | 全部界面；`ui/kit/` 是自研设计系统，颜色/字体/间距走 token，先改 Kit 再改页面 |
| `lib/state/` | 连接控制器与各 mixin、偏好、队列、加密记忆与本机请求日志 |
| `lib/domain/` | 纯 Dart 规则与模型：记忆、耗时、统计、agent 配方、供应商等 |
| `lib/api2/` | OpenCode 2 HTTP/SSE、网关、发送前记忆同步 |
| `lib/builtin/` | 内置 Ubuntu、服务器、agent 安装与内置 `oc-ui` MCP |
| `lib/l10n/` | 英文/中文 ARB 与生成文件；新增文案要同时改两种语言 |
| `android/` | Kotlin 原生层：Linux 生命周期、进程所有权、通知、小组件、凭据 |
| `engine/phone/` | AI Team Rust 引擎；改源码后必须重新生成并提交 `.so` 与 manifest |
| `test/` | Flutter 单测与 widget 测试；CI 还会跑 Android 原生回归测试 |
| `.github/workflows/build.yml` | 静态分析、全量测试、原生测试、arm64 release APK 与发布 |

## 构建、验证与发布

- 工具链：Flutter 3.47.9、Dart ^3.10.0、JDK 17、Android SDK 37；Rust 不需要（`.so` 已提交）。
- 版本号唯一来源是 `pubspec.yaml` 的 `version`。普通 bump 只加 build 号，`--patch` 改语义版本，见 [README.md](README.md#versioning)。
- CI 把 `versionCode` 设为 `100000 + GITHUB_RUN_NUMBER`，保证发布包能覆盖本地包；tag `v0.3.25+33` 必须与 pubspec 一致，否则发布流程拒绝构建。
- 发布前必须通过 `flutter analyze`、全量 Flutter 测试和 Android 原生回归测试，并校验 APK 签名、ABI 与 SHA256SUMS。发布资产是 arm64 APK 和校验文件。
- 分支整合与验证门槛见 [docs/BRANCH_INTEGRATION.md](docs/BRANCH_INTEGRATION.md)；历史审计材料见 [docs/PROJECT_OVERVIEW.md](docs/PROJECT_OVERVIEW.md)。

## 已知限制

- 只构建 arm64-v8a；32 位设备和模拟器装不上，桌面工程保留但不构建。
- 界面只有英文和简体中文；`values-ar` 是上游遗留资源。
- 记忆注入目前只接 OpenCode 2 的指令 API；内置 MCP 工具更新后需要重启已加载的运行时才会出现。不支持 MCP 的远端 agent 会明确告知，手动记忆仍可用。
- 本机请求时间线从本版本开始记录，不补录历史；用量统计中的启动次数同理。
- 截图和交互在 CI 中用应用真实主题组件验证；安装到真机后的实际使用仍需单独验证。
