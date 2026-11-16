# 记忆 / Memory

## 用户流程

- 设置 → 对话 → 记忆：手动新增、编辑、停用、删除和搜索。
- 当前对话：用户主动要求 AI 总结本会话记忆，或使用会话菜单的“总结本会话记忆”。
  后者说明 Token 费用，再通过正常会话发送，不导出/裁剪一份聊天文本另行请求模型。
- AI 调用 MCP `oc-ui` 的 `memory_write`，参数为
  `{"memories":["候选内容"],"scope":"global"}`，也可选择 `project`。
- 工具只返回“待用户确认，未保存”，没有记忆库的文件或密钥访问权限。
  原生对话卡片提供预览入口；用户可以编辑、选择范围、勾选条目。
- 只有点击“保存所选记忆”才串行写入本机加密记忆库。打开/关闭预览、模型的
  “已保存”文字、普通 JSON 或代码块都不会触发写入。
- 不后台提取、不自动保存；不引入独立记忆服务，不写 AGENTS.md 代替记忆。

## 范围和存储

全局记忆适用于本应用的 OpenCode 发送；项目记忆按保存服务器 id、地址和
服务端项目 id 隔离。项目未知时，项目候选不会自动降为全局，必须用户明确切换。
正文只存 `flutter_secure_storage`；普通偏好只存存在标记。读写损坏/失败时不
当成空库、不替换已有快照。工具调用的候选仍留在原服务器的会话历史里。

每条最多 1024 UTF-8 字节，工具每次最多 8 条，最多保存 100 条；每组适用记忆
连同格式的 JSON 编码上限 7168 字节。超限明确报错，不隐式删减。相同范围的
完全重复内容拒绝写入，同一工具调用的并发重复确认也拒绝。

发送时把已启用的适用内容同步到独立会话指令键 `mobile.long-term-memory`，
不占用会话说明键 `mobile.note`。同步失败不会继续发送或改成普通用户提示词。
关闭/删除后，后续本应用发送会清掉该键，但不能抹掉已经发送给服务器/模型的
旧内容。其他客户端、定时任务、外部智能体不读取此本机加密库。

## 运行边界

记忆提交工具复用应用内置 `oc-ui` MCP 的安装和适配器，供应商/模型无特例。
内置运行时需要加载更新后的工具目录（已启动的 MCP 子进程需要在安全时重启）；
不擅自修改用户的外部服务器。远程/不支持 MCP 的智能体没有此工具时应明确告知，
手动记忆管理仍可使用；对话的记忆注入目前仅接入 OpenCode 2 指令 API。

## 验证

- `test/long_term_memory_test.dart`：存储、范围、并发、损坏保护、工具调用解析。
- `test/long_term_memory_api_test.dart`：先同步再发送、删除、变更重同步、失败不发送。
- `test/memory_write_mcp_test.dart`：执行真实生成的 Node MCP 脚本，验证目录和协议。
- `test/long_term_memory_widget_test.dart`：预览不写入、勾选保存、失败重试、未知范围、
  手动编辑/删除确认、主题/字号/窄屏及截图。

## 设计参考

参考 RikkaHub 的“设置管理记忆 + 对话 memory 工具”职责划分：
[MemoryTools.kt](https://github.com/rikkahub/rikkahub/blob/a75f3f9cd7863bf571642044112e9bf443263f73/app/src/main/java/me/rerere/rikkahub/data/ai/tools/MemoryTools.kt)、
[AssistantMemoryPage.kt](https://github.com/rikkahub/rikkahub/blob/a75f3f9cd7863bf571642044112e9bf443263f73/app/src/main/java/me/rerere/rikkahub/ui/pages/assistant/detail/AssistantMemoryPage.kt)。
未复制其 AGPL 实现；本项目按用户选择额外保留“预览后确认”，不采用后台整理。
