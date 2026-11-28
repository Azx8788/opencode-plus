# 用 SnowLuma 接入普通 QQ（OneBot 11）

SnowLuma 是新建 QQ 普通账号配置的首选，不需要 LuckyLillia 账号或 Auth Token。
它需要一个运行中的桌面 QQ；OpenCode Plus 只连接它提供的 OneBot 11。Android 上
App 可以读取你自己下载的官方 ARM64 发行包，核对发布方的大小和 SHA-256，再
复制到内置 Ubuntu 解压并启动包内启动器。App 不下载 SnowLuma、不代你接受
EULA/隐私条款、不登录 QQ，也不会自动迁移已有 LLBot 或 NapCat 配置。

## 1. 手动下载并启动

1. 在你管理的 Windows 或 Linux 主机上准备桌面 QQ。去
   [TomyJan/SnowLuma v2.4.2 发布页](https://github.com/TomyJan/SnowLuma/releases/tag/v2.4.2)
   下载适合该主机的原始发行包，不要选 GitHub 的「Source code」压缩包。
2. Android 上可在「设置 → 对话 → 消息渠道 → QQ 普通账号 → SnowLuma 配置指南」
   选择「选择并校验 ARM64 发行包」。App 只读取你选中的文件，比对发布方的大小和
   SHA-256，不上传文件。支持 `SnowLuma-v2.4.2-linux-arm64.tar.gz` 和对应
   `-lite.tar.gz`；Lite 不含 Node.js，需使用完整版或先在 Ubuntu 中安装兼容的
   Node.js（`^24.22.1 || >=26.12.1`）。
3. 校验通过后点「导入到 Ubuntu 并启动」。App 会把该文件复制到内置 Ubuntu、
   再次核对 SHA-256、安全解压到 `/root/.oc-builtin/snowluma/releases`，并以后台
   服务运行包内 `launcher.sh`；就绪后可在 App 内打开 5099 的本机 WebUI。首次
   启动仍由你在 WebUI 中阅读并接受 EULA/PRIVACY，登录桌面 QQ 并确认账号。
   WebUI 就绪不代表 QQ 已在线；QQ 登录和 OneBot 状态仍需你完成和确认。
4. 也可以不用本机导入：在 Windows 或 Linux 主机上按上文手动解压并运行
   `launcher.sh`/`launcher.bat`，再用 WebUI 完成设置。

不要把 WebUI 端口开放到公网。SnowLuma 并非腾讯官方方案，使用普通 QQ 账号
存在账号限制风险。请先查看上游 [LICENSE](https://github.com/TomyJan/SnowLuma/blob/v2.4.2/LICENSE)
和 [EULA](https://github.com/TomyJan/SnowLuma/blob/v2.4.2/EULA.md#5-专有组件)。
EULA 第 5.4 条要求：把专有组件并入第三方安装包、通过自动化脚本部署或用于商业
用途，须事先取得著作权人书面授权，列出的联系方式是 `motricseven@foxmail.com`。
本 App 不打包、不下载、不镜像 SnowLuma；本机导入只是执行你明确选择并校验的
文件，是否属于该条限制以及是否需要书面授权，由你自行判断并在导入前确认。
App 的确认对话只记录你的选择，不代你接受任何条款。

## 2. 配置 OneBot

1. 在 SnowLuma 为所选 QQ 账号启用 **OneBot 11 → WebSocket 服务端**，角色选择
   **Universal**，消息格式选择**数组**，设置该连接的 **Access Token**。
2. 返回 App 的「QQ 普通账号」，选择 **SnowLuma → 应用主动连接**。填写服务端
   WebSocket 地址（默认端口 3001，非 WebUI 5099）和该 OneBot Token。连接其他
   主机优先用 `wss://` 或可信私有网络，Token 单独填写，不放进 URL。
3. 点击「测试连接与 QQ 账号」。测试核对会话事件的 `self_id`、OneBot 实现、
   `get_login_info` 的账号以及 `get_status` 的在线与链路状态。不发 QQ 消息；
   预期账号留空时，测试成功会填入表单草稿。确认这个账号无误，设置允许的发送者
   （群聊还要设置群白名单），再启用并保存。空白名单不允许任何人驱动 Agent。

已有手动运行的本机实例，可在指南中点「检查本机环境」。如果识别到 5099 的
SnowLuma WebUI，且 3001 可达，可把 `ws://127.0.0.1:3001/` 填入表单草稿。
这只证明本机端口状况；仍需填写 Token 和测试后由你启用。

## 验证范围

- 参考 [AstrBot Bubble](https://github.com/MuFengDR/AstrBot-Bubble-Android-App/tree/0d1abe6ed5b6b384ab3dd3c0b513079c5ad18b36)
  的分步流程，区分运行环境、账号登录和消息连接。不沿用其 NapCat 启动代码。
- 导入辅助脚本已用官方 v2.4.2 Lite 包实测：大小与 SHA-256 校验、安全解压、
  重复导入幂等、启动器运行及 5099 回环 HTTP 200 均通过，停止后端口释放。测试
  未启用自动接入 QQ、未登录任何 QQ 账号。桌面 QQ 在手机 PRoot 中的接入和真实
  消息收发尚未验证；失败时请改用普通 Windows/Linux 主机。
- 真实收发验收：使用你自有的测试账号，从允许的 QQ 私聊发送一条无副作用的短指令，
  确认进度和最终答复回到原会话，再用未列入白名单的账号确认不会触发 Agent。
