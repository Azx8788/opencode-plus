# 开发报告：双层 Agent 与消息可靠性

日期：2026-11-26 · 版本：0.3.32+41 · 提交：`d76cab4`、`d16cfdb`、`6a16da4`

## 1. 原有架构与新架构

| | 原来 | 现在 |
| --- | --- | --- |
| 谁决定用户看到什么 | 引擎按事件推断（`session.idle` → 最后一条 assistant 文本） | 管理模型通过 `send_message` 决定；关闭时退回原方式 |
| 任务是什么 | 内存里的 `ChannelTask`，随进程消失 | `ChannelTaskRecord`，持久化，有状态机 |
| 完成与送达 | 同一个布尔值 `running` | `status` 与 `delivery` 两个字段 |
| 一轮的归属 | 会话级的 `runtime.running` | `ChannelTurn`，自带 id、session、已投递消息 id |

## 2. 新增与修改的模块

| 文件 | 作用 |
| --- | --- |
| `lib/channels/channel_turn.dart` | 新增。一轮执行的身份与投递记录 |
| `lib/channels/channel_tasks.dart` | 新增。任务记录、状态机、持久化、台账接口 |
| `lib/channels/manager/manager_client.dart` | 新增。OpenAI 兼容 Chat Completions + 工具调用 |
| `lib/channels/manager/manager_agent.dart` | 新增。管理循环、7 个工具、`ManagerHost` 边界 |
| `lib/channels/manager/manager_config.dart` | 新增。独立配置；密钥进安全存储 |
| `lib/ui/screens/settings/manager_agent_screen.dart` | 新增。启用、地址、模型、密钥、步数、任务列表 |
| `lib/channels/channel_engine.dart` | 改写投递与收尾；接入台账与管理器 |
| `lib/channels/channel_hub.dart` | 装配台账、管理配置与两个引擎 |
| `lib/state/connection.dart` | `latestReplyInfo`：回复带消息 id |
| `lib/ui/screens/settings/channels_screen.dart` | 渠道中心增加「管理代理」入口 |
| `docs/CHANNELS_MANAGER.md` | 新增。设计与已知边界 |

## 3. Manager Agent 的实际流程

1. 收到渠道消息 → 策略、去重、命令解析（`/status` 等仍由引擎处理）。
2. 交给管理模型，系统提示写明规则（不得虚构、提交不等于完成、必须用 `send_message`）。
3. 模型调用工具，应用执行：`submit_task` 走原有 `promptAsync`；`send_message` 走原有 outbox；`get_task_status` / `get_task_result` 读台账；`cancel_task` 调 abort；`stay_silent` 记录主动沉默。
4. 模型不再调用工具即结束。若它既没说话也没选择沉默，引擎按原方式兜底发送。
5. 执行轮结束时，引擎把结果作为系统事件再交给管理模型，由它决定如何交付。

工具没有收件人参数：会话在构造 host 时固定，模型无法指定别人。

## 4. 任务状态机

```
created → submitted → running → completed / failed / cancelled
                         ↕
                  waitingPermission
```

投递独立：`pending → delivering → delivered / deferred / failed / unknown`。
转移集中在一张表里；`/stop` 之后的 `session.idle` 无法把 cancelled 改回 completed。

## 5. 丢答复竞态的根因与修复

根因：`_sendMilestone`（350 ms）与 `_finishTask`（500 ms）读同一个 `runtime.running`。下一轮在两者之间开始时，前者因 `running == false` 退出，后者因 `running == true` 退出，两处都不发送。

修复：不是加长延迟。一轮有自己的对象；投递按 assistant 消息 id 去重；只有「工具开始」才证明上一条消息是中间步骤，更新只从这里发出；收尾时轮询 `latestReplyInfo` 等服务器写完，但等待只决定发什么，不决定发不发。

| 下一轮开始 | 修复前 | 修复后 |
| --- | --- | --- |
| 10 ms | 发成「更新」 | 最终答复，恰好一次 |
| 200 ms | 发成「更新」 | 最终答复，恰好一次 |
| 400 ms | **丢失** | 最终答复，恰好一次 |
| 480 ms | **丢失** | 最终答复，恰好一次 |
| 700 ms | 最终答复 | 最终答复，恰好一次 |

## 6. `/stop` 与服务器 Inbox

已实现：`/stop` 先把任务标记为 cancelled 再 abort，并清空本地队列；此后到达的答复不再投递（PASS，`channel_turn_test.dart` 覆盖）。

**NOT VERIFIED**：已经进入 OpenCode 服务器 per-session inbox 的补充消息是否随 abort 一起清除，属于服务器行为，本构建无法观测。文档与界面不声称已撤回。

## 7. Outbox 与可观测性

- 每条待发消息关联 `taskId`；投递结果写回台账（`delivery`、`attempts`）。
- 失败不重跑 Agent；`unknown` 不重试。
- 管理代理页面列出最近任务，`completed + delivery != delivered` 显示为「未送达」。
- 尚未做：outbox 明细（每条重试记录）的独立页面。

## 8. 配置界面

消息渠道 → 管理代理：启用开关、接口地址、模型、API Key（安全存储，保存后只显示「已保存」）、每次请求的工具步数上限、任务列表。管理模型与执行模型完全独立；关闭时渠道行为不变。

## 9. 验证结果

| 项目 | 结果 |
| --- | --- |
| `flutter analyze` | PASS（无问题） |
| 本地全量测试 | PASS（755） |
| CI verify（`v0.3.32+41`） | PASS（755 tests passed） |
| CI native（Android 存储/引擎/凭据） | PASS |
| CI package（arm64 APK） | PASS（37.1 MB，仅 arm64-v8a） |
| Release 发布 | PASS（`v0.3.32+41`，APK + SHA256SUMS） |

## 10. 未完成 / 受限

| 项 | 状态 | 原因 |
| --- | --- | --- |
| 真实模型提供商下的管理代理 | NOT VERIFIED | 测试全部对本地 loopback 服务器；没有真实 API Key |
| `/stop` 撤回服务器 inbox | NOT VERIFIED | 需要真实 OpenCode 服务端观测 |
| 官方 QQ 超过 5 分钟的答复 | BLOCKED | 需要控制台申请主动消息权限；未获授权时如实报「窗口已过期」 |
| 新轮在收尾窗口内产生结果时的归属 | 已知限制 | 网关只提供「最后一条」回复，无法按 id 取历史消息；内容不丢、恰好一次，标签可能属于上一轮 |
| 管理模型的多轮记忆 | 已知限制 | 进程内、有上限；重启只丢寒暄，不丢任务 |
| `/queue` 的 queued 状态 | 未记录 | 排队项在真正提交时才建记录，避免留下永远 queued 的僵尸行 |
| 子代理任务归属 | 保持原状 | 现有 OpenCode 子会话机制未改动，未新增识别 |

## 11. 测试清单

| 文件 | 覆盖 |
| --- | --- |
| `test/channels/channel_turn_test.dart` | 七个时间点、恰好一次、更新与最终答复、取消、两种回执、多会话状态 |
| `test/channels/channel_tasks_test.dart` | 状态机、重启后仍在、拒绝非法转移、引擎写入、已答未达 |
| `test/channels/manager_agent_test.dart` | 线格式、401、`send_message`、`submit_task`、无工具回复、`stay_silent`、引擎集成、不可达兜底 |
| `test/channels/channels_screen_test.dart` | 管理代理入口与页面、未填模型时拒绝保存 |
