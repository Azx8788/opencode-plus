# Shizuku 确认与回执改进

基线：`8b38011`（完整 CI #147 通过）。本文件记录后续候选改动，不把基线的 CI 或旧 APK 实测结果算作新代码验收。

## 真机证据与判断边界

- 手机已能以 Android UID 2000 执行读取；串行 `cat /dev/null` 的 stdout/stderr 均为空，仍返回 `succeeded`、exitCode 0。
- 一次 `mkdir /sdcard/opencode_shizuku_qa_e90294fa` 返回成功，随后 `ls -d` 确认目录从无到有。不能再把整个通道描述为“只读模式”或“空输出必丢回执”。
- 用户明确拒绝了清理该空目录的 `rmdir` 请求。Agent 当时只收到 `Tool execution interrupted`，未重发、未换通道；只读复查显示目录仍在。该目录按用户的拒绝保留。
- 目录状态只证明观察到的效果，不能定位命令有没有进入 shell。原生回执、审批事件和派发记录才可进一步定位。
- 单次 `shizuku_status` 中断和拒绝请求的中断不能合并成同一种故障。聊天 Core 审批与 Android 安全悬浮窗是两道不同的卡口。

## 当前候选实现

1. Android 确认不再只回 Boolean。主动拒绝、超时、取消、缺悬浮窗权限、确认不可用分别记录；允许仍必须满足等待时间、有效期限和权限。
2. 每个悬浮窗只有一个最终决定。迟到的允许、超时或取消不能改写它；关闭时移除本次计时回调。
3. 原生操作历史增加派发阶段 `executionStage`：`not_dispatched` 表示没有 Binder 派发标记；`dispatched` 表示可能已经执行，不等于已确认 shell 启动。
4. `confirmation_user_denied` 与 `confirmation_timeout` 保留为不同终态。后续工具取消、同 ID 重放或 App 重启不能把拒绝改成可执行状态。
5. 插件在审批前通过进度记录操作 ID；最终 metadata 保留 reason、派发阶段和退出码。中断后可以按原 ID 查询，不能重新提交命令。
6. 聊天及设置页共同解释原生回执。用户拒绝、确认超时、未执行、执行失败、取消、结果未确认分别显示。Android 成功回执优先于外围 AI 工具的 `executed` 标志；矛盾或缺失的数据显示未确认。
7. 聊天适配器保留原操作的进度 metadata。只在收到同 session、同 request、同 tool call 的 Core `permission.replied: reject` 时记录“用户拒绝”；不把其他调用的中断当成拒绝。该 fallback 不修改服务端会话正文或模型循环。
8. Shizuku 调用不显示盲目“重试”按钮。拒绝后不绕过卡口；缺失回执只能查询原操作。既有风险分类和高级模式规则保持不变。

## 不能承诺的事

- Core 的无附言拒绝按官方 V2 契约结束当前步骤；插件仍传播该拒绝，不伪造成功工具输出以强行续跑。
- 如果整个步骤在回执写入前中断，模型未必立即得到拒绝原因。原生历史和已收到的审批事件可以辅助核对；无证据仍显示未确认。
- 本次 live Core 审批关联是有界内存 fallback。App 重启后仍以服务端 transcript/原生历史为准；没有原生回执不能靠旧进度推断未执行。
- 单个有副作用的命令仍串行领取；并发占用返回 busy，而不是静默排队或重放。本候选不声称已解决所有桥偶发无响应问题。

## 验证

- Kotlin/JUnit：一次决定、延迟与超时边界、取消后迟到允许、拒绝/超时持久化、派发阶段、终态不重放。
- Node：拒绝/超时回执、回包丢失后的原 ID 查询、去重、空输出、Core 拒绝不提交、早期操作 ID。
- Flutter：纯回执规则、进度/审批事件关联、中英文聊天状态、320dp 大字体、设置诊断解释及不重发。
- 新候选需重新完整 CI，并安装新 APK 验收。不得用旧 APK 的行为证明这些改动已生效；不会为验收重复用户已拒绝的删除。

本机阶段结果：17 项纯 JVM JUnit 回归通过；7 项纯 Dart 回执规则通过（仅将测试 runner 从 `flutter_test` 换为 `test`，未运行 widget）；Node 插件/帧夹具通过；Dart 格式检查及回执规则单文件分析通过。完整 Flutter、Gradle 和新 APK 真机结果仍待确认。

CI #148：静态分析、原生回归、APK 编译/签名/ABI 校验通过；Flutter 553 通过、1 失败。失败位于新增事件测试：误把 `ToolState` 兼容归一化后的 `executed` 当原始标志。测试已改为分别核对 wire flag 和 Android 回执，并覆盖经过实际归一化后仍显示“未确认”；不删除断言，也不修改现有 beta 兼容行为。修订需下一轮完整 CI。

## 参考与许可

参考 [ExTV/rikkahub-agent](https://github.com/ExTV/rikkahub-agent/tree/a88f5854b4d2e2706ea2ae8304a7d66a3f9f2bbc) 的“拒绝作为终态并向模型返回明确原因”的处理思路，及 [OpenCode V2 插件的 Permissions 契约](https://opencode.ai/v2/docs/build/plugins/server#permissions)。

RikkaHub Agent 为 AGPL-3.0。本次只作行为对照，本项目实现独立编写，未复制其代码、测试或提示词；不将这种已阅读源码的对照称为洁净室实现。
