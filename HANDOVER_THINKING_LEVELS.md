# 思考等级（Reasoning effort / variants）问题交接

> 状态：**方案 1 已实现（待 CI/真机验证）**。本文保留调查证据，并记录当前
> 通用修复：目录刷新/发送前对账失效的会话档位，识别 `VariantUnavailableError`。
> 分析基线：`fix/reconcile-unavailable-reasoning` @ `65db6e3`（修复候选版本 `0.3.20+28`），内置服务器 OpenCode `2.1.1`，`127.0.0.1:4097`。
> 适用对象：接手本仓库、要修模型选择/思考档位的人。

---

## 1. 现象

1. 有些模型在模型面板里最高只能选到「极高」（`xhigh`）甚至「高」（`high`），**没有「Max」**。
2. 同一个模型，**用着用着档位列表会变**：一开始有「极高」，中途只剩「高」或回落成「默认」。

这两件事看起来是同一个 bug，实际是**两个独立问题**（见第 4 节）。

---

## 2. 档位从哪里来（结论）

档位**不是 App 决定的**。模型面板列出的等级来自服务器 `GET /api/model` 返回的每个模型的 `variants`，App 只负责显示和把选中的 id 写回会话。

| 层 | 位置 | 作用 |
| --- | --- | --- |
| models.dev 元数据 | 服务器随包数据 | 按模型给出 `capabilities.reasoning.effort`，服务器据此生成 `variants` |
| `opencode.json` 覆盖 | `<配置>/opencode.json`、项目级 `opencode.json(c)` | `providers.<id>.models.<model>.variants` 可增删档位；`capabilities.reasoning` 可整体替换 |
| 服务器目录 | `GET /api/model` | 输出最终 `variants`（每项含 `settings`，如 `reasoningEffort: "xhigh"`） |
| App | `lib/state/connection/catalog.dart` | 读目录、校验所选档位、**档位消失时静默重置为默认** |
| App | `lib/ui/widgets/pickers_catalog_footer.dart` | 用 `drafted.variants` 生成「思考等级」菜单 |
| App | `lib/ui/widgets/pickers.dart` | `presentedEffort()` 把 id 映射成文案（none/minimal/low/medium/high/xhigh/max → 不思考/极低/低/中/高/极高/Max） |

**关键事实：App 支持并显示 `max`**（有映射、有 `modelEffortMax` 文案、有 `_variantLabel` 回退），不是 App 把 Max 藏了。

---

## 3. 已核实的事实（可复现）

### 3.1 不同模型、不同供应商，档位本来就不一样

同一台服务器 `/api/model` 的实测（节选，按 provider 分组）：

| 模型 | variants |
| --- | --- |
| `agentrouter/gpt-5.6-sol` | none, low, medium, high, **xhigh, max** |
| `agentrouter/gpt-6-astra`、`agentrouter/gpt-6.1-sol` | none, minimal, low, medium, high, **xhigh**（无 max） |
| `gpt1/gpt-6-astra`、`gpt1/gpt-6.1-sol` | none … **xhigh**（无 max） |
| `l/gpt-6-luna`、`l/gpt-5.6-luna` | none … **xhigh**（无 max） |
| `modelscope/deepseek-ai/*`、`moonshotai/Kimi-K3.1-Pro`、`Qwen/*`、`stepfun-ai/*`、`ZhipuAI/GLM-5.2` | low, medium, **high**（最高只有 high） |
| `amd/DeepSeek-V4.1-Flash`、`amd/GLM-5.3-Flash` | none … **max** |
| `opencode/*-free` 系列 | 多数到 **max** |

**同一个模型名，换一个 provider，档位完全不同**：例如 `DeepSeek-V4.1-Flash` 在 `amd` 有 max，在 `modelscope` 最高只有 high。这解释了现象 2 的一部分：「用到一半只剩高」往往不是档位被删，而是**会话/模型切到了另一个供应商的同名模型**，或目录刷新后读到了另一组元数据。

> 「Max 不是通用最高档」——它是部分模型元数据里才有的等级。`gpt-6.x` 系列在 models.dev 里最高就是 `xhigh`，所以没有 Max 是**元数据的结论**，不是配置遗漏。

### 3.2 服务器确实支持 `variants` 覆盖，且是逐模型深度合并

用项目级 `opencode.json`（分析期间临时创建、**已删除**）做实验：只给 `modelscope/ZhipuAI/GLM-5.2` 增加一个 `max` variant，重载后 `/api/model` 变成 `[low, medium, high, max]`，**其他模型全部原样保留**。给 `agentrouter`、`gpt1` 的 GPT-6 系列加法同理生效。

结论：配置层可以「只加档位、不动别处」；但**这不等于网关真的接受了这个档位**（见 3.4）。

### 3.3 App 会静默丢弃消失的档位（现象 2 的另一部分）

`lib/state/connection/catalog.dart` 的 `_loadCatalogUntraced()`：

- 目录刷新后，如果 `selectedVariant` 不在新的 `variants` 里，就把它重置为 `''`（默认）并写回偏好；
- 刷新由多种信号触发：`catalog.updated`、`models-dev.refreshed`、`config.updated`、`agent.updated` 事件，以及 `catalogFreshFor = 10 分钟` 的过期、`catalogReuseWindow = 60 秒` 的复用窗口；
- 重置过程**没有任何提示**：用户看到的就是「极高突然没了」。

这属于「合理但不够好」：档位真的不存在时应该回落，但**静默**回落让现象 2 无法解释、无法追溯。

### 3.4 脚本直连探测不可靠

用 `POST {baseURL}/chat/completions` + `reasoning_effort: "max"` 直接探测：

| 网关 | 结果 |
| --- | --- |
| `l`（free.hiyo.top） | HTTP 200 |
| `modelscope` | HTTP 200 |
| `gpt1`（api.xingchiapi.com） | **HTTP 403 `client_not_allowed`**：站点只允许编码客户端（Codex/Claude Code/OpenCode 等），脚本、SDK 直连被拒 |
| `agentrouter` | 连接超时 / 拒绝（网络或同类过滤） |
| `amd` | HTTP 429（模型容量限制） |

**200 只说明「没拒绝这个参数」**，不代表按 max 实际调参；403/超时说明脚本探测对这类网关无效。要验证「档位真的生效」，必须**让服务器自己发请求**（见第 7 节）。

### 3.5 自定义供应商表单不写思考档位

`lib/domain/custom_provider.dart`：

- v1 写入布尔 `reasoning`（`protocol != responses`）；
- v2 **故意不写** `reasoning`（注释：网关既有推理模型也有普通模型，猜错会让请求带上端点不认的参数）；
- **没有** `variants` 或 `capabilities.reasoning.effort` 字段，也没有对应表单控件。

所以 App 里新增/编辑的供应商只能沿用服务器按 models.dev 推出的档位，用户无法在 App 内为某个模型加 `max`。

---

## 4. 根因拆解

| # | 问题 | 归属 | 现状 |
| --- | --- | --- | --- |
| A | 该模型元数据里最高就是 `xhigh`/`high`，没有 `max` | models.dev 数据 / 上游 | 不是本仓库 bug；可用配置覆盖强行加，但见 B |
| B | 网关是否真的接受某个档位，无法从元数据判断 | 网关行为 | 无通用探测手段；只能通过服务器实测或用户试错 |
| C | 目录刷新/切换供应商后，所选档位静默消失或回落 | **本仓库（App）** | 唯一可以在 App 内通用修复的部分 |

**A + B 决定了「不能靠给每个供应商写死 Max 解决」**：不同网关支持的档位不同、过滤策略不同（3.4），逐个适配既维护不起，也无法证明生效。

---

## 5. 已尝试并回退的方案（不要重复）

**逐供应商在配置里加 `max` variant**（项目级 `opencode.json`）：技术上可行（3.2 已证实），但——

1. 治标：只覆盖被点名的几个模型/供应商，新供应商还要再来一次；
2. 不可验证：脚本探测被过滤（3.4），无法确认网关真的按 max 工作；
3. 有风险：不认 `max` 的网关会在用户选中后返回 400，错误落在对话里，而不是配置阶段；
4. 覆盖用户数据：项目级 `opencode.json` 会叠加到该目录下**所有**会话，属于隐式全局行为。

该文件已在分析结束时删除，仓库与用户配置均未保留。

---

## 6. 通用方案与当前实现

### 方案 1（低风险，App 侧）：选择不静默丢失（已实现）

- 目录刷新完成后，对已加载的 OpenCode 2 会话重新检查当前模型的 variant；
- 每次发送前等待目录刷新并再次检查；若 variant 已不存在，只清空 variant，保留模型，
  发送使用服务器默认，而不是让下一步触发 `VariantUnavailableError`；
- 已经发生错误时，识别该错误、刷新目录并修正会话选择；错误行保留“重试”路径；
- `provider.updated` / `model.updated` 统一转成目录刷新信号，避免只处理旧的
  `catalog.updated`；
- 关键实现：`lib/state/connection/models.dart`、`catalog.dart`、
  `lib/ui/screens/chat/chat_stream.dart`、`lib/domain/models/models_messages.dart`；
  纯规则测试在 `test/variant_unavailable_test.dart`。

### 方案 2（中风险，App 侧，通用）：模型级档位自定义

- 在供应商表单里给**每个模型**一个「思考档位」字段（多选/逗号分隔），保存时写入
  `models.<id>.variants`（v2）或 `capabilities.reasoning.effort`；读取时合并回表单；
- 这是**通用能力**，不绑定任何供应商：谁需要谁填；可提供「常见档位」预设；
- 实现面：`domain/custom_provider.dart` 记录与 v1/v2 写入、`custom_provider_record.dart` 回读、
  表单 UI、`app_en.arb`/`app_zh.arb` 文案、`test/custom_provider_test.dart` 契约测试；
- 仍解决不了 B：文档里要写明「档位是否生效取决于网关」，并在选中后错误时给出明确提示。

### 方案 3（研究性）：协议级归一

- 把内部统一档位映射到各协议字段：OpenAI Chat `reasoning_effort`、Responses `reasoning.effort`、
  Anthropic `thinking.budget_tokens`；
- 难点：**真正发请求的是服务器**，App 只能通过配置影响；除非上游支持或做一个服务器插件。
- 不建议在本仓库内先做，除非确认上游方向。

### 方案 4：数据/上游修复

- 若确认某个模型的真实最高档是 `max` 而元数据缺失，应向 models.dev / 上游提 issue；
- 本仓库无法单独修好 A。

**下一步**：先完成 CI/真机验证，再评估方案 2；方案 3 仍需上游配合。

---

## 7. 调试与复现

```sh
# 当前目录的模型目录（含每个模型的 variants 与 settings）
opencode2 api --server http://127.0.0.1:4097 get \
  '/api/model?location[directory]=/root/projects/opencode-plus'

# 改动配置后让服务器重读（也可以等文件监视自动重载）
opencode2 api --server http://127.0.0.1:4097 post /api/location/reload \
  --param 'location[directory]=/root/projects/opencode-plus'
```

**验证某个档位是否真的生效**：不要用脚本直连（会被 403/连接拒绝）。用服务器自身发一条极短提示：

1. `POST /api/session`（可带 `model`，含 `variant`），或创建后 `POST /api/session/{id}/model`；
2. `POST /api/session/{id}/prompt`（如 `"只回复 ok"`）；
3. 轮询 `GET /api/session/{id}/message`，看助手消息里的 `error` 与 `tokens.reasoning`；
4. 结束后 `DELETE /api/session/{id}`，避免在用户会话列表留下测试记录。

**现象 2 的取证**：应用内「诊断 → 日志」（JSONL）里筛 `catalog.load` 与 `session.model.selected`，
对比刷新前后的 `/api/model` 输出，即可区分「档位被元数据移除」还是「切了供应商/会话」。

---

## 8. 未决问题

1. `agentrouter`、`gpt1` 是否真的接受 `reasoning_effort: "max"`（需按第 7 节通过服务器实测）。
2. `modelscope` 的 DeepSeek/Kimi/Qwen/Step 是否接受 `xhigh`/`max`，还是只认 low/medium/high。
3. 现象 2 的真实触发序列：models.dev 刷新导致档位变化，还是用户/自动流程切换了供应商——
   需要一份真实 `app_log` 才能定论（本文未取得）。
4. 上游是否愿意把 `max` 作为通用档位，或按网关能力暴露「能力协商」。

---

## 9. 代码索引

| 关注点 | 文件 |
| --- | --- |
| 档位文案与菜单 | `lib/ui/widgets/pickers.dart`（`presentedEffort`）、`lib/ui/widgets/pickers_catalog_footer.dart`（`_chooseThinking`、`_setVariant`、`_applyDraft`） |
| 选择与持久化 | `lib/state/connection/models.dart`（`_variantAllowed`、`_selectModel`、`selectVariant`） |
| 目录刷新与静默重置 | `lib/state/connection/catalog.dart`（`_loadCatalogUntraced`、`catalogFreshFor`、`catalogReuseWindow`） |
| 目录映射 | `lib/api2/gateway_mappers.dart`（`mapApi2CatalogModel`）、`lib/api2/models/models_catalog.dart`（`Api2ModelInfo.variants/raw`） |
| 档位类型 | `lib/domain/server_gateway/value_types_core.dart`（`CatalogVariant.reasoningEffort`、`isFast`） |
| 供应商配置写入 | `lib/domain/custom_provider.dart`（`_v1Entry`、`_v2Entry`）、`lib/builtin/builtin_provider_store.dart` |
| 配置文件位置 | `.oc-opencode2/config/opencode/opencode.json`（App 写入，JSONC 会被拒绝合并） |

---

## 10. 注意事项

- **不要把临时实验用的项目级 `opencode.json` 提交进仓库**；它会影响该目录下所有会话。
- 不要手改 App 生成的全局配置来「修」档位：供应商编辑会按表单整体重写该条目。
- 不要用脚本直连探测有客户端过滤的网关（会得到 403 或被连接拒绝，结论无效）。
- 档位列表是**按模型**的：排查时先确认「同一个 provider 下的同一个 model id」，再比较前后差异。
- 本次分析期间创建的项目级配置与临时会话均已清理；当前修复候选等待 CI/真机验证。
