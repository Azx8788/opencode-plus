Shizuku 授权问题修复：交接文档
================================

日期：2026-11-21
仓库：https://github.com/Azx8788/opencode-plus
分支：feat/local-usage-dashboard
交接基线：3940cae（fix(shizuku): report live authorization state accurately）
本次改动：见下方「本次提交内容」，提交后补记真实 commit 号。

一、任务背景
------------

用户真机反馈三类问题：

1. 申请 Shizuku 权限总是失败。
2. Shizuku 管理器的授权列表里，本应用的条目会自己消失。
3. 没有授权时界面却显示「已授权」。

前两次修复（919a288、6297e55、ed94494、3940cae）引入了授权状态机和
独立申请按钮，但 3940cae 推送后完整 CI（run 44560595049）三个任务全部失败，
且仍有未审查的连接/状态缺陷。本次按「逐文件审计 + 可执行回归」重做了一轮。

二、本次提交内容
----------------

A. 授权状态（Android）

- ShizukuController 不再使用 Shizuku.checkSelfPermission()：SDK 会缓存
  进程内的 GRANTED，撤销后仍可能报已授权。改为 ShizukuPermissionReader
  直接查 IShizukuService.checkSelfPermission()，失败返回 null（未知），
  不猜成授权或拒绝。
- 删除「shouldShowRequestPermissionRationale 视为永久拒绝」的判断：
  Shizuku 服务端对普通客户端并不提供可靠的 rationale 语义，沿用会误拒。
- 删除「Sui 环境一律不申请」的拦截：Sui 由 SystemUI 显示确认，
  与 Shizuku 走同一个官方 requestPermission 流程。
- 授权请求码每次递增，ShizukuPermissionRequest 按 code 匹配回调；
  超时/失败/重启后的旧回调不会污染新请求。
- permissionResult 只在实时查询成功时才给值；查询失败时为 null。

B. 授权状态（Flutter）

- 状态快照新增 statusRevision；Dart 忽略更旧的 revision，
  迟到的 status 方法响应不能覆盖更新的推送事件。
- ShizukuPlatform.changes 改为共享的单个广播流（原来每次 getter
  都新建 Stream，两个订阅者会互相顶掉 handler）。
- status 事件校验必需字段；设置读取/保存校验六个字段及范围，
  非法或缺失回包抛 invalid_shizuku_settings，不再把默认值当已保存。
- Binder 死亡/状态读取失败时清空旧快照（permission=unknown、
  executionReady=false），避免继续显示「已授权/服务运行中」。
- 「requestable」文案从「未申请」改为「未授权」；Sui 显示说明；
  中文搜索别名补齐。
- 只读诊断与 10 秒取消测试使用不同的启停条件：没有悬浮窗权限时
  只读诊断可用、取消测试禁用。
- 取消状态按 operationId 记录，迟到的取消回包不会把新命令标成已停止。
- 操作历史满时显示明确说明并禁用新命令。

C. UserService 连接生命周期（Android）

- 新增 ShizukuConnectionRegistry：只允许当前 epoch 的连接回调
  解绑自己，旧回调不会 unbind 新连接（SDK 按 tag 共享连接，
  旧 unbind 会清掉新连接的 callback）。
- bind/unbind 放入单线程 bindingRpc 串行执行，避免 SDK 连接状态竞争。
  注意：这里用有界 ThreadPoolExecutor(1,1)，不是无界单线程池。
- 绑定截止时间 35 秒（服务端 UserService 启动预算 30 秒），
  握手另有 10 秒独立期限；到期按 deadline 重新调度，不会误判慢启动。
- Binder 死亡后刷新状态（原来只 publish 旧快照）。

D. 命令执行与桥

- 命令启动必须成功使用 /system/bin/setsid；不再回退到无进程组的 shell，
  避免超时/取消后只杀掉 shell、遗留子进程。
- ShizukuCommandPolicy 的敏感路径增加 /proc/<pid>/(environ|cmdline|mem|maps|fd)。
- 私有 socket 目录初始化提取为 ShizukuBridgeDirectory：只有「目录为空、
  非符号链接、属主校验通过」时才补写缺失标记；有未知内容仍拒绝。
  这样初始化中途崩溃不会永久禁用桥。
- Landlock 边界明确拒绝 AF_UNIX，因此该保护层下不对 guest 宣称桥可用
  （aiBridgeReady=false，理由 android_bridge_unavailable），
  避免出现「显示可用但实际连不上」。
- prepare 请求单独放宽桥超时（宿主 42 秒、Node 45 秒），
  其余请求保持 15 秒。
- 操作记录目录允许父目录别名（Android /data/user/0 与 /data/data），
  仍拒绝记录目录本身是符号链接。

E. 构建与 CI

- android/build.gradle.kts 为 dev.rikka.shizuku 增加两个 Maven Central 镜像
  （Google 镜像与 repo1），用 content { includeGroup } 限定范围；
  CI #144 的依赖失败是 Maven Central 返回 HTTP 429，不是包不存在。
- 修复 CI #144 的 Kotlin 编译错误：ProviderInfo 没有通用 permission 字段，
  改为校验 readPermission 与 writePermission。
- 修复 Dart analyzer 的 prefer_interpolation_to_compose_strings。
- 文档：docs/SHIZUKU_FIRST_IMPLEMENTATION_PLAN.txt 更新了已过时的
  「Sui 不申请」「绑定 10 秒」等描述，并记录 CI #144 结果。

三、已验证 / 未验证（务必如实转述）
------------------------------------

已验证（本机）：

- Kotlin/JUnit 纯逻辑子集，48 项通过。覆盖：绑定状态机、授权请求状态机、
  连接注册表、操作记录、命令策略、输出截断、协议、服务门闩、
  桥目录恢复。工具为临时下载的 Zulu 17 JRE + Kotlin 2.4.0 编译器，
  不是项目 Gradle 构建。
- Node 夹具测试通过（tool/qa/shizuku_plugin_test.mjs）：
  插件注册、权限、取消、去重、私有帧。注意是夹具，不是 Android Binder。
- dart format 通过；git diff --check 通过。

未验证：

- 完整 CI（native / verify / package）尚未在本次改动上跑通。
- 未在真机验证：授权弹窗、Sui 路径、管理器列表条目、UserService 启动、
  命令执行/取消、Landlock 与 proot 两种保护层。
- Robolectric 测试（ShizukuRegistrationManifestTest、ShizukuPermissionReaderTest、
  InternalStorageProviderTest 等）未在本机运行，依赖 CI。
- 本机没有 Flutter SDK，widget/契约测试未在本机执行。

结论：本次改动修掉了审计中发现的具体缺陷，但不能宣称「问题已修复」，
必须等新 CI 全绿并做真机验收。

四、CI #144 的三个失败与处理
----------------------------

1. native：Could not resolve dev.rikka.shizuku:api/provider:13.1.5。
   日志显示 repo.maven.apache.org 返回 HTTP 429（见更早 ci-140-package.log）。
   处理：限定范围的 Maven 镜像回退。若新 CI 仍失败，先看是否为 429/网络，
   不要改依赖版本。
2. package：ShizukuController.kt:196 Unresolved reference 'permission'。
   处理：改为 readPermission/writePermission 校验；Robolectric 清单测试同步。
3. verify：flutter analyze 的 prefer_interpolation_to_compose_strings。
   处理：已改为字符串插值。

五、接手者的第一步
------------------

1. 拉取最新分支与提交。
2. 触发完整 CI（仓库只在 main/tag 自动跑，feature 分支需手动）：

   gh workflow run build.yml --ref feat/local-usage-dashboard
   gh run watch

   或使用仓库 Settings → Actions → Android arm64 build → Run workflow，
   分支选 feat/local-usage-dashboard，package_only 保持 false。

3. CI 绿后安装 APK，按下面清单真机验收。

六、真机验收清单
----------------

- [ ] 未授权时：界面显示「未授权/未知」，不显示「已授权」。
- [ ] 点「申请 Shizuku 授权」：管理器出现确认，允许后状态变「已授权」。
- [ ] 在管理器里撤销：回到设置页/切换后台再回来，状态变为未授权。
- [ ] 管理器授权列表：应用条目存在，重启管理器后仍在。
- [ ] 关掉 Shizuku 服务：显示未运行，恢复后能重新连接。
- [ ] 只读诊断：返回真实 UID（2000 或 0）与 Android 版本。
- [ ] 红色命令：出现悬浮窗，超时拒绝；允许后执行。
- [ ] 10 秒取消测试：取消后进程确实结束（可用 ps 确认无残留）。
- [ ] 操作记录目录：多次执行后仍能执行（不应出现「记录不可读」）。
- [ ] Sui 设备（如有）：点申请出现 SystemUI 确认；无回调时显示未确认。

七、已知风险与待决问题
----------------------

1. Sui 的确认 UI 由 SystemUI 提供，不同 ROM/版本可能不出现；
   无回调时只记「未确认」，不会伪造拒绝或授权。需要真机确认。
2. MediaTek/HyperOS 上 UserService 初始化崩溃是 Shizuku 上游已知问题
   （RikkaApps/Shizuku-API#299 未合并），本项目不反射私有 API 规避。
3. Landlock 保护层与 Unix socket 桥不兼容：该层下 AI 工具桥显示不可用，
   设置页 Binder 路径不受影响。若产品需要该层可用，需另设计传输。
4. 持久化操作记录上限 4096 条，满后拒绝新命令（fail-closed），
   目前没有清理入口；如需长期使用要设计保留/归档策略。
5. 桥目录「空目录补标记」是恢复窗口，只对空目录生效；
   已有未知文件仍拒绝，避免接管非本应用数据。
6. 授权状态现在绕过 SDK 缓存直接查服务端，代价是每次刷新多一次 Binder 调用；
   若未来出现性能问题，可加短 TTL 缓存，但撤销必须能及时反映。

八、代码地图
------------

Android（android/app/src/main/kotlin/com/azx8788/opencode/mini/）

- ShizukuController.kt：状态机、授权申请、绑定、操作分发、MethodChannel。
- ShizukuPermissionRequest.kt：授权请求状态机（纯 Kotlin，可主机测试）。
- ShizukuPermissionReader.kt：实时权限 Binder 查询（null=未知）。
- ShizukuConnectionRegistry.kt：epoch 化连接注册表。
- ShizukuBindingState.kt：绑定/握手两段期限。
- ShizukuCommandService.kt：UserService 执行、超时/取消、进程组。
- ShizukuCommandPolicy.kt：风险分级与只读语法。
- ShizukuOperationJournal.kt：持久化去重与结果缓存。
- ShizukuNativeBridge.kt + ShizukuBridgeDirectory.kt：私有 Unix socket 桥。
- ShizukuSafetyOverlay.kt：红色命令悬浮窗确认。

Flutter（lib/）

- platform/shizuku.dart：MethodChannel/EventChannel 封装与回包校验。
- ui/screens/settings/shizuku_screen.dart：状态展示、策略设置、诊断/取消。
- builtin/shizuku/*.dart：内置 Ubuntu 的 OpenCode 插件与帧桥。

测试

- android/app/src/test/kotlin/.../Shizuku*Test.kt：纯 JVM 逻辑测试。
- test/shizuku_settings_widget_test.dart：设置页 widget 测试。
- test/shizuku_integration_contract_test.dart：清单/契约/代码约束检查。
- tool/qa/shizuku_plugin_test.mjs：Node 插件夹具。

九、已知未完成项
----------------

- 未新增「清理操作历史」入口。
- 未做真机自动化；上述验收清单需人工执行。
- CI 通过后仍建议再跑一次带 package_only=false 的完整构建，
  确认 APK 内 provider、权限与 meta-data 正确（可用 apkanalyzer 检查）。

十、沟通提醒
------------

- 不要把本机 48 项 JVM 测试或 Node 夹具结果描述为「Android 已验证」。
- 不要把 CI #144 的失败归因于用户设备；其中两项是本项目代码/构建问题。
- 本次提交前请确认工作区无未提交文件；提交信息建议沿用
  fix(shizuku): ... 前缀。