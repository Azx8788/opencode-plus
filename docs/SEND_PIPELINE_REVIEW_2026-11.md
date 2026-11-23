# 消息发送第二轮复核：处置结果

对应文档：`大问题.txt`（2026-11-23 源码复核，22 项）。
本文只说明这一轮改了什么、为什么这样改、哪些仍需要产品或服务端决定。
基线：`main` @ `0f9ac0e`，App 0.3.27+35。分支：`fix/22-send-pipeline-reliability`。

## 一、结论先说

22 项里真正可以在客户端独立修掉的缺陷，本轮全部改了代码并加了回归测试；
属于设计取舍或需要服务端原子能力的部分，本轮不伪装修好，只写清边界。

- 新增/修改测试：`test/send_pipeline_reliability_test.dart`（24 项）。
- `flutter analyze` 无问题；`flutter test` 全量通过。

## 二、贯穿性改动：一次发送只有一个身份

原复核最关键的结论是「不能把所有入口当成同一条发送链」。本轮把三条链合成一条：

| 入口 | 改前 | 改后 |
| --- | --- | --- |
| 普通在线 | `promptAsync`，服务端自生成 ID | `promptWithMessageID`，客户端先给出 `msg_` ID |
| 离线恢复 | `CommandReceiptTransport` 直接 `client.prompt` | 同一 `promptWithMessageID`，走网关完整准备 |
| 首条消息 | `promptAsync`，无 ID | `promptWithMessageID`，失败时抛出带 sessionID 的失败 |

`Api2Gateway` 现在实现 `CorrelatedPromptGateway`，能力表打开
`clientPromptMessageID`。由此得到：

- **同一逻辑发送重试复用同一个 `msg_` ID**，服务端按 ID 去重，ACK 丢失后重试不会二次准入（#2 / R02）。
- **会话记录里存的是同一个 ID**（`QueuedPrompt.messageID`），气泡与队列卡按 ID 关联，
  不再靠文本比对（#3 / #17 / B07 / B11）。
- 首条消息失败时 `ChatStartFailure` 带出已创建的 sessionID，Retry 不再新建会话（#8 / R08）。

## 三、逐项处置

### 已确认 Bug（改代码）

| 编号 | 处置 | 落点 |
| --- | --- | --- |
| **B01** 进网关后无法取消 | 取消随发送进入网关：`PromptCancellation` 接口，每个 `await` 之后与 HTTP 之前检查，`CancelToken` 覆盖在途请求 | `domain/server_gateway/interfaces.dart`、`api2/gateway.dart`、`api2/client.dart`、`ui/screens/chat/chat_send.dart` |
| **B02** 停止补偿丢失 | 停止请求不再因「已有一个在飞」被丢弃：`_abortRun` / `_abortAgain`，当前一次结束后必然再补一次；补偿移到 `mounted` 检查之前 | `chat_session_actions.dart`、`chat_send.dart` |
| **B03** 准备抛异常锁死 Stop | 整个准备与请求纳入 `try/finally`，任何路径都释放 `_aborting` | `chat_session_actions.dart` |
| **B04** 旧回执标错新输入 | 停止前捕获目标 prompt ID，只按 ID 标记，且要求它仍是最后一条 | `chat_session_actions.dart` |
| **B05** 离线回执绕过准备 | `CommandReceiptTransport.dispatch` 改为走 `promptWithMessageID`，权限模式、记忆、taskMetadata 全部执行；测试断言三者顺序 | `domain/command_receipt_transport.dart`、`api2/gateway.dart` |
| **B06** 确定未 POST 却丢内容 | `finishOnlinePrompt(restored:)`：只有「服务端已接收」或「文字已回到编辑器**且已保存**」才删除记录；退页无法恢复时保留记录 | `state/connection/queue.dart`、`chat_send.dart` |
| **B07** 同文误删持久记录 | 删除/隐藏只认 ID；无 ID 的旧记录保留待人工核对 | `chat_queue.dart` |
| **B08** 合法回执被判未知 | `type: user` 与 `prompt` 都算 prompt 回执；读 `time.created`；严格校验 ID/session 仍在 | `api2/models/models_inbox.dart`、`gateway.dart` |
| **B09** 撤回 no-op 当成功 | `cancelInboxItem` 返回 `cancelled / delivered / unknown`：删完再看 inbox 与正式消息，只有 `cancelled` 才合并 | `state/connection/forms_inbox.dart`、`chat_queue.dart` |
| **B10** 撤回文字无保管者 | 新增 `SteerEscrowStore`：**先写托管，再 DELETE**；替代 admission 确认后才释放；下次进会话恢复到编辑器（保存成功后才释放） | `state/steer_escrow.dart`、`state/connection/queue.dart`、`chat_queue.dart`、`chat_history.dart` |
| **B11** 普通气泡错配/隐藏 | 有 authored ID 的气泡不再按文本认领；文本兜底只对本地乐观气泡、且有时间下限、且候选唯一；等待气泡不再隐藏正式行 | `chat_history.dart`、`chat_stream.dart`、`chat_page.dart` |
| **B12A** 共享历史读起点不一致 | 共享读返回 `startedAt`，合并基线取两者较小值；旧 Future 清理加 identity 校验 | `state/connection/session_cache.dart`、`chat_history.dart` |
| **B12B** inbox 全局 revision 不足 | 改为 per-session epoch + tombstone + 有界追补 | `forms_inbox.dart` |
| **B12C** 首次 attach 缺 status 补齐 | 首次 live 时额外做一次轻量 `sessionStatuses` 补齐（只增不减） | `state/connection/events.dart`、`session_events.dart` |
| **B13A** 引用提示被清输入撤掉 | 提示改在命令/`!shell` 清空输入之后发布 | `chat_send.dart` |
| **B13B** 斜杠前缀误判命令 | 记录「实际按命令发送过的文本」，不再看 `/` 前缀 | `chat_send.dart`、`transcript_turns.dart`、`chat_page.dart` |
| **B13C** 控制消息被合并 | Stop-after-step note 不参与普通合并 | `chat_queue.dart` |

### 潜在风险（本轮已收窄）

| 编号 | 处置 |
| --- | --- |
| **R02** 缺稳定 ID | 已修：见第二节。旧无 ID 记录不自动重发、不自动删除。 |
| **R08** 首条无绑定 | 部分修复：精确 ID + `ChatStartFailure` 打开既有会话。**持久化的 attempt→session 记录**（进程被杀后的恢复）仍需新增存储，列为后续。 |
| **R09** 权限同步乱序 | 已修：同一 session 的同步串行化 + 代际校验，旧代际直接放弃。 |
| **R16** 恢复选择先于发送 | 部分修复：选择变更前先做无副作用准入，准入失败不再改共享选择。原子性仍需产品定义。 |
| **R10 / R21** 准备链成本与观测 | 已加 `prompt.prepare.permission` / `memory` / `metadata` 分阶段计时。**统一前台 deadline** 未加：仅包 `Future.timeout` 会留下迟到 POST，需要先决定「超时后按未发送还是按未知」。 |
| **R18 / R19** | 未改代码。现有 part revision、sticky partial、保守 pending 分类已是安全侧；本轮改动不影响其结论。 |

### 设计取舍（本轮明确语义，不改行为）

| 编号 | 结论 |
| --- | --- |
| **D06** 本地 busy 决定显式 steer | 2.1.1 两条路径都归为 steer（S5）。保留现状；不据本地 busy 推断服务端交付方式。 |
| **D11** 记忆同步失败阻断发送 | 保留 fail-closed。离线路径现在也会同步（B05 修复的直接结果）。 |
| **D12** 两种气泡顺序 | 保留：普通先出气泡、steer 先取回再合并，是为了不展示错误的合并结果。丢失缺口由 B06/B10 关闭。 |
| **D13** `!cmd` 带附件走普通 prompt | 保留现状（附件不被丢弃），保留提示的缺陷已修（B13A）。 |
| **D14** 未识别 slash 走文本 | 保留现状；「无回复」误判已修（B13B）。 |
| **D15** 20 页上限与容量防护 | 保留现状。 |
| **D16** 离线选择属产品语义 | 保留「按排队时选择恢复」，失败/取消的副作用已收窄（R16）。 |
| **D22** idle interrupt 视为完成 | 保留；「已停止 A」现在有目标身份（B04）。 |
| **R05** 选择未原子固定 | 语义明确为「会话的最新选择」；不塞 metadata 假装原子。 |

## 四、需要服务端/产品决定、本轮不做的

1. **原子取消指定执行**（E02）：`interrupt` 没有 expectedExecutionID。客户端只能本地屏障，
   旧 interrupt 仍可能停到后继执行。
2. **按 prompt 固定 model/agent**（E03 / R05）：协议不支持 per-prompt 选择。
3. **原子撤回替换**（B09）：客户端只能「确认后再合并」，做不到服务端事务。
4. **首条消息 attempt 持久化**（R08）：需要新增一条持久记录（profile + project + text + sessionID + messageID）。
5. **发送总 deadline**（R21）：需要先定超时语义，否则会制造迟到 POST。

## 五、回归覆盖

`test/send_pipeline_reliability_test.dart`：

- 回执：`user` / `prompt` / 非 prompt 类型、`time.created` 与 `timeCreated`。
- 精确 ID：ID 上送、回执 ID/session/type 不匹配即拒绝、准备链顺序（权限 → 记忆 → prompt）、准备失败必为「未发送」且零 POST。
- 取消：准入栅栏期间取消、准备完成前取消、请求在途中取消（判为「已停止」而非服务端错误）。
- 离线回执：走网关、不可精确 ID 的网关被拒绝而不是换路发送。
- 队列身份：`messageID` 持久化往返、重试复用同一身份、旧记录只铸造一次。
- 托管：跨重启保留、按会话隔离、同 item 不重复、单项释放、整会话释放、损坏数据不假装成功。
