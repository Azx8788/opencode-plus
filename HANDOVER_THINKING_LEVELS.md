# 思考等级问题交接（2026-11-16 更新）

> 当前候选版本：`0.3.22+30`，尚待完整 CI 和升级后的真机验收。
> 本文替换前一版的错误判断；不能将“目录没有 Max”推断为“网关不支持 Max”。

## 用户实际要解决的事

- 模型菜单最高只有高/极高，没有 Max；希望能稳定选用更高等级。
- 同一个供应商/模型使用途中，等级变少或选择被降回默认。
- 不接受逐供应商写特例，也不接受偷偷降级作为解决方案。

用户已经确认：临时添加 Max 后正常获得了模型响应，后来删除临时配置才
使保留 `variant: max` 的会话出现 `VariantUnavailableError`。该错误是服务端
目录解析失败，发生在供应商调用前，**不是供应商拒绝 Max 的证据**。
一次正常响应也不能单独证明供应商内部投入了更多推理算力。

## 已查到的具体代码问题

1. `CustomProviderDraft.mergeInto` 过去整条替换 provider。表单只读少量字段，
   所以 Save / Fetch models 会丢掉 `variants`、`capabilities.reasoning`、
   `modelID` 别名等未进入表单的配置。这是可直接从代码复现的丢失路径。
2. `BuiltinLinux.serverScript()` 将全局配置复制进 `OPENCODE_CONFIG_CONTENT`。
   通过当前服务的 `/api/config` 核实：它既读文件，又读无路径的启动快照。
   快照优先级更高，热重载不能修改已有进程的环境，旧值可能覆盖新值。
3. `reloadServerConfig` 过去没有携带当前 directory/workspace。模型目录和
   会话按 location 解析，写文件后必须重载正确的项目。
4. 旧的模型菜单仅显示服务器 `variants`，没有通用的持久覆盖入口。
5. 全局 `selectedVariant` 在刷新后缺失时被静默清空。`0.3.20+28` 候选又
   增加了会话自动降级；用户试用证实这没有满足原始需求，现已撤掉。

没有捕获原始故障前后的完整相同模型目录，因此不能把所有“中途消失”都
归因于上述任一路径，也不能声称用户自动切换了供应商。

## 当前通用修复

### 可见的自定义等级入口

路径：对话模型选择器 → 全部模型 → 思考 → Max → 应用。

根据用户的截图反馈，撤掉 `0.3.21` 候选里的“自定义”分组和逐项重复说明。
现为一个低到高排序的紧凑列表；额外请求等级仅在选中后说明一次。

- 对已广告 `reasoningEffort` / `reasoning_effort` 的模型，列出缺失的常见
  effort ID，包括 Max。按参数能力处理，不检查供应商名字或 GPT 型号。
- 现有自定义 variant 保持原样，明确 disabled 的等级不会被重新启用。
- 只有可以写入本机内置服务器配置时才显示新增入口。远程服务器不能
  仅在手机上显示一个无法实际选择的 Max。
- 不把 token-budget 型 thinking 当成 reasoningEffort；未知模型不猜能力。
- 这些入口标注为**显式请求覆盖**，不是宣称所有供应商都支持这些档位。

### 持久保存及确认

- `withModelReasoningEffort` 只向目标模型加一个 variant，不动其他配置。
- v2 写 `variants: [{id: "max", settings: {reasoningEffort: "max"}}]`。
- `BuiltinProviderStore.setModelReasoningEffort` 写入服务器实际全局 JSON，
  先备份再用现有原生写入通道原子替换。不会创建仓库或父目录影子配置。
- Apply 的顺序是：写文件 → 重载当前 location → 刷新目录 → 确认 Max
  在目录中 → 写会话 model/variant。未确认则留在面板上说明原因。
- Save / Fetch models 合并到最新文件，保留未被表单编辑的模型字段。
- 新启动脚本不再导出配置正文快照，仍保留原有 XDG/DB 路径。

### 不再偷偷降低用户所选等级

- 同一模型的元数据刷新不再清空所选 variant。
- 缺失的当前等级在菜单中明确显示，不伪装成“默认”。可恢复它或手选别的。
- `VariantUnavailableError` 保留专用提示及打开模型菜单的处理入口，只刷新
  目录，不自动重发提示、不把 Max 强改为 default。
- `model.updated` / `provider.updated` 都会使模型目录刷新。

## 验证与边界

测试（不向真实供应商发送收费请求）：

| 文件 | 覆盖 |
| --- | --- |
| `test/model_reasoning_test.dart` | 无供应商特例、v1/v2 序列化、保留字段、disabled、重复保存、表单往返 |
| `test/model_reasoning_picker_test.dart` | 菜单可见 Max、先保存后选择、保存失败、未加载、项目切换、只读服务器 |
| `test/reasoning_selection_refresh_test.dart` | 目录刷新不静默降低已选 Max |
| `test/model_reasoning_api_test.dart` | 会话选择请求真正发送 `variant: max` |
| `test/builtin_provider_store_test.dart` | 原生配置写入及再次编辑后 Max 仍在、启动脚本不冻结配置 |
| `test/server_config_reload_test.dart` | 重载请求携带正确 directory/workspace |
| `test/variant_unavailable_test.dart` | 错误分类、模型/供应商变更触发刷新 |

**真机验收必须另做**：安装 `0.3.22+30` 后，当前任务完成再重启内置
服务器一次（运行中的旧进程仍有配置快照），选择自定义 Max 并应用；随后
刷新模型、编辑供应商并保存、重启 App，检查 Max 仍可选并保持已选。
同时检查菜单无重复分组/大段文案，点 Max 后勾选与芯片同步变为 Max。
没有这个流程的成功结果，不应把 CI 通过说成用户问题已彻底解决。

目录/请求参数正确，也不能保证第三方代理内部不会忽略或改写 effort。
供应商拒绝某等级时应保留清楚错误，让用户自行选择，不自动降低。

## 现场与安全

- 之前的人工 `/root/projects/opencode.json` 在用户切为 Max 后曾被恢复，
  仍可能影响现场目录。不要未经同意再次删除或重载它；也不提交此文件。
- 全局配置和环境中含供应商密钥，日志只打印字段名、档位和提交，不打印正文。
- 不读取/修改现有会话数据库进行修复，不强制重启正在工作的服务器。
- 本机没有 Flutter/JDK/Android SDK，Flutter 分析、测试、APK 构建靠 CI。
- 上一个 #92 的原生失败来自 Robolectric 下载 SDK 的 `MavenArtifactFetcher`
  IOException；同提交的 verify/package 已成功。应先取具体日志，勿跳过测试。

## 主要实现位置

- `lib/domain/model_reasoning.dart`：候选 effort 与只改 variant 的配置变换。
- `lib/domain/custom_provider.dart`：provider 编辑时保留未编辑字段。
- `lib/builtin/builtin_provider_store.dart`：持久化及备份。
- `lib/builtin/builtin_linux.dart`：新服务器启动使用活文件。
- `lib/api2/server_config_reload.dart`：按 location 重载。
- `lib/ui/widgets/pickers_reasoning.dart`：保存/确认后才应用会话选择。
- `lib/ui/widgets/pickers_catalog_footer.dart`：可见入口和缺失等级提示。
- `lib/state/connection/catalog.dart`：元数据刷新保留同一模型的所选等级。
