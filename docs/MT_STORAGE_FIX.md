# MT 管理器添加本地存储时没有 OpenCode Plus

## 原因与已有修复

MT 官方的“注入文件提供器”说明写明：走“添加本地存储”时，系统界面会让
你在侧栏选中目标应用再授权，这条标准 DocumentsUI 流程用 Android SAF 目录
授权。DocumentsUI 在 `ACTION_OPEN_TREE` 下会隐藏不支持父子关系检查的存储根：
[`ProvidersAccess.getMatchingRoots()`](https://android.googlesource.com/platform/packages/apps/DocumentsUI/+/refs/heads/android12-release/src/com/android/documentsui/roots/ProvidersAccess.java)。

`main` @ `0355410` 和整改分支 `audit/quality-fixes-20261115` @ `71d4161`
的 Manifest 已正确注册 `InternalStorageProvider`，但 `queryRoots()` 缺少
`Root.FLAG_SUPPORTS_IS_CHILD`，也没有实现 `isChildDocument()`。这会让目录
授权界面隐藏入口；打开“所有文件访问权限”不能补上这个 provider 能力。

以前的修复仍在远端：

| 分支 / 提交 | 修复内容 |
| --- | --- |
| `fix/saf-storage-tree-access` / `3f4caa2` | 声明目录授权能力，实现后代检查 |
| `fix/storage-provider-projection` / `479e2d3`、`8a0132c` | 按请求的列及顺序返回名称、类型、大小等元数据 |
| `fix/storage-provider-projection` / `c992b4e` | 上述修复及最终回归测试的分支顶点 |

旧分支的 [CI 43674492629](https://github.com/Azx8788/opencode-plus/actions/runs/43674492629)
中 `storage-provider` 和 `build` 均通过。用于验证整改分支 CI 流程的临时
`ci/verify-20261115` 分支构建 [`43700051452`](https://github.com/Azx8788/opencode-plus/actions/runs/43700051452)
基于较早的整改提交 `036482e`，不包含 SAF 修复；它也不能证明手机安装了
哪个构建。版本号来自不同分支，不能仅凭“0.3.14”判断是否修过。截图本身
不足以确定手机已安装 APK 的提交来源。

## 本次集成

`fix/mt-storage-discovery` 基于整改分支 `71d4161`，移植上述 provider 和
Android 12 回归测试。存储入口及根目录名称读取安装包的应用标签，显示
OpenCode Plus（预览包显示 OpenCode Plus Preview）。Manifest 检查加入 Dart
测试；CI 的 APK 构建依赖原生存储测试成功，避免只验证 Flutter 而漏掉 SAF。

包名仍是 `com.azx8788.opencode.mini`，authority 仍是
`com.azx8788.opencode.mini.internalstorage`，根 document ID 仍是 `root`。
授权覆盖的是应用 `filesDir`（含内置 Linux），不是整个 Android 私有数据目录。

## 验证

- 自动测试入口：`test/android_manifest_provider_test.dart`、
  `android/app/src/test/kotlin/com/azx8788/opencode/mini/InternalStorageProviderTest.kt`。
- 原生测试覆盖根能力、树 URI 访问与读写、目录边界、单列/乱序 projection、
  空 projection，以及正式/预览包名称。
- 本次环境没有 Flutter、JDK 和 Android SDK；旧分支 CI 成功不等于本次集成
  已编译通过。本分支需运行 `.github/workflows/build.yml` 完成构建验证。

真机步骤：覆盖安装同签名且 versionCode 足够高的修复 APK，先启动一次应用，
退出旧的文件选择器，再从 MT 重新进入“添加本地存储”。左侧应出现
OpenCode Plus；选择目录并授权后，用新建的临时文件验证读写、重命名和删除。
若仍不出现，记录安装版本、构建提交、Android/ColorOS 版本以及应用内
“浏览应用存储”的结果，以继续区分包来源与系统选择器行为。
