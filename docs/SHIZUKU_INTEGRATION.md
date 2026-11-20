# Shizuku integration (rewritten)

> ## 状态：实验性功能（Beta）· 禁止合并
>
> 本文件描述的是 `rewrite/shizuku-integration` 分支上的**全新重写**，
> 与 `main` 上的 Shizuku 实现没有继承关系，是**实验性（Beta）功能**。
>
> 在维护者明确确认之前：
>
> - **不得合并到 `main`**，不得打 tag，不得发布 Release；
> - 不得视为稳定功能，接口、状态模型与数据契约都可能继续变化；
> - 安装、测试、评估均只应视为实验行为，不代表可交付状态；
> - 任何合并决定都必须来自人工确认，而不是 CI 通过。
>
> CI 通过只证明「这个分支能构建、测试能过」，**不构成合并许可**。

This document describes the module that replaced the previous implementation in
`rewrite/shizuku-integration`. It records what the code depends on, why each
fact is kept apart, and what has actually been verified.

> **Status: experimental (beta), not mergeable.** This branch is a fresh
> rewrite with no inheritance from `main`. Do not merge, tag or release it
> before an explicit human decision. A green CI run proves the branch builds
> and its tests pass; it is not approval to merge.


## Why the old implementation could not be patched

Three concrete defects, each traceable to source rather than to a symptom:

1. **A cached grant was read as a live one.** `rikka.shizuku.Shizuku.checkSelfPermission()`
   stores the first `true` in a static field (`permissionGranted`) and returns it
   for the rest of the process. A revocation in the manager therefore stayed
   invisible: the app kept reporting "authorized" while the server would refuse
   every call. This is the direct cause of "I never granted it, but the app says
   authorized".
2. **The listing condition was modelled as one boolean.** The manager builds its
   list in `ShizukuService.getApplications()` from exactly two conditions — the
   `moe.shizuku.client.V3_SUPPORT` meta-data and the
   `moe.shizuku.manager.permission.API_V23` permission. The provider is *not*
   part of that filter. The old code folded all three into `listable`, so a
   provider mistake was reported as "the manager will not list you" and vice
   versa.
3. **The rationale field was read as "not granted".** Server-side,
   `shouldShowRequestPermissionRationale()` means *explicitly denied*, not
   *never asked*. Using it to decide "permanently denied" produced wrong
   messages and wrong retry behaviour.

The old test suite also named `ProviderInfo.permission`, a field that does not
exist on `android.content.pm.ProviderInfo` (only `readPermission` and
`writePermission` do), so the tests could not compile. That is why the previous
attempt never reached a green CI run.

## Facts are kept apart

`Model.kt` defines one value per question, and `ShizukuSnapshot` carries all of
them at once:

| Fact | Type | Meaning |
| --- | --- | --- |
| manager installed | `ManagerState` | is `moe.shizuku.privileged.api` installed |
| package listed | `Registration.listed` | V3_SUPPORT + API_V23, the manager's own filter |
| provider configured | `Registration.providerConfigured` | authority, exported, not multiprocess, `INTERACT_ACROSS_USERS_FULL` |
| binder | `BinderState` | absent / alive / dead, plus a generation counter |
| provider kind | `ProviderKind` | shizuku / sui / unknown |
| authorization | `AuthorizationState` + `AuthorizationEvidence` | granted / denied / **unknown**, and where the answer came from |
| request | `RequestStatus` | idle / pending / granted / denied / unavailable / **unconfirmed** / interrupted |
| identity | `ServerIdentity` | live `uid`, API level, SELinux context, `supported` |
| UserService | `SessionStatus` | stopped / binding / handshaking / ready / failed |
| operation store | `storageReady` | records readable; independent of authorization |
| AI bridge | `bridgeReady` | socket accepted; independent of everything else |

`blockedBy` names the first unmet condition in the order a person can act on it,
and `executionAdmitted` requires all of them. Authorization has **three**
outcomes, and `grantsExecution` is true only for `GRANTED` with `SERVER`
evidence — an SDK-cached answer can be displayed but never admits a command.

## How authorization is read

`ServerAuthorizationProbe` transacts `checkSelfPermission` on the binder the SDK
already holds, which asks the running server every time:

- `api < 11` → unknown (`server_too_old`)
- `api > 14` → unknown (`server_newer_than_sdk`); the transaction id is pinned to
  the AIDL in `dev.rikka.shizuku:aidl:13.1.5` (explicit id 15, wire code 16)
- `IllegalStateException` from the server's `requireClient()` → unknown
  (`client_not_attached`), never "denied"
- any other failure → unknown (`server_unreachable`)

This is an internal interface, not a documented public API. It is used because
the public call is cached; the version gate above keeps it from guessing on a
server it was not verified against. If a future server moves the transaction,
the result is `unknown` and the UI says so — it does not silently allow.

## Request, session and execution

- `AuthorizationRequest` never issues the same request twice, never turns a
  missing callback into a denial (`UNCONFIRMED` + `callback_missing`), accepts a
  grant the server confirms after the deadline, and lets a binder change end the
  wait (`INTERRUPTED`) instead of leaving it pending forever. Attempts are
  replenished only by an explicit re-enable.
- `SessionState` treats a received Binder as `HANDSHAKING`, not ready. `READY`
  requires the service's own instance id, protocol version and a UID equal to
  the server's. Late callbacks from an older epoch cannot overwrite a newer
  attempt, and both bind and handshake have deadlines.
- Before dispatch, `Runtime.admit()` re-reads the live authorization, so a
  revocation during a one-minute confirmation overlay cannot be followed by a
  command. `dispatch()` then re-checks the instance and the feature switch.
- Execution needs readable operation records. If the store cannot be read the
  command is refused with `operation_storage_unavailable`, which is reported as
  its own reason — not as an authorization failure.

## Layout

```
android/app/src/main/kotlin/com/azx8788/opencode/mini/shizuku/
  Model.kt         the facts, the snapshot and its JSON
  Probes.kt        environment, server authorization, server identity
  Authorization.kt the authorization request state machine
  Session.kt       the UserService connection state machine
  Runtime.kt       the single owner of state: channels, bridge, admission
  Protocol.kt      wire contract, owner identity, fingerprints  (kept, renamed)
  Policy.kt        command risk grammar and admission            (kept, renamed)
  Gate.kt          per-instance execution gate                   (kept, renamed)
  Journal.kt       durable operation records                     (kept, renamed)
  Output.kt        bounded process output                        (kept, renamed)
  Overlay.kt       fail-closed confirmation overlay               (kept, renamed)
  CommandService.kt the UserService itself                       (kept, renamed)
  NativeBridge.kt  filesystem socket for the AI tool             (kept, renamed)
```

The eight kept components were inspected before reuse; each is self-contained
and none of them made an authorization decision. Everything that did decide
authorization was replaced.

`ShizukuController.kt`, `ShizukuPermissionRequest.kt` and
`ShizukuBindingState.kt` are deleted, so no second set of logic can run.

## Contract

`contractVersion = 2`. Dart refuses a snapshot whose version differs rather than
interpreting it, so an older APK cannot be displayed as a newer state. The flat
fields the installed AI plugin already uses (`executionReady`, `uid`, `backend`,
`serviceInstance`, `brokerInstance`, `enabled`, `environment`, `fallback`) are
still emitted next to the structured ones.

## Verification performed

| Check | Result |
| --- | --- |
| `:app:compileDebugKotlin` | pass |
| `:app:testDebugUnitTest --tests 'com.azx8788.opencode.mini.*'` | 102 tests, 0 failures |
| `flutter analyze` | no issues |
| `flutter test` | 526 tests, 0 failures |
| `:app:assembleRelease` (R8 + minify + proguard) | pass, `app-release.apk` 38 MB |
| `CommandService` / `IShizukuCommandService` present in the release dex | yes |
| Provider in the built manifest | `com.azx8788.opencode.mini.shizuku`, exported, not multiprocess, `INTERACT_ACROSS_USERS_FULL` |
| `API_V23` and `V3_SUPPORT=true` in the built manifest | yes |

New tests: `SnapshotTest` (admission rules, JSON shape), `AuthorizationRequestTest`
(request lifecycle), `SessionStateTest` (bind/handshake/epoch), plus the rewritten
settings widget test and the packaging contract test.

## Known limits

- The `checkSelfPermission` transaction is verified for server API 13 and 14
  only. Anything newer reports `unknown` instead of guessing.
- No physical device was available, so the real dialog, the manager list and a
  live revocation are covered by source analysis and unit tests, not by an
  on-device run.
- One command runs at a time; a second request is refused with `busy` rather
  than queued.
- The app never starts, stops or configures Shizuku, and never grants itself
  anything. Every authorization step needs the person's answer in the manager.
