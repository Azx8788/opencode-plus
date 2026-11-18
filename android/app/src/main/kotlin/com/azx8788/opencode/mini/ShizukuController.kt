package com.azx8788.opencode.mini

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.SystemClock
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import rikka.shizuku.Shizuku
import rikka.sui.Sui
import java.io.File
import java.util.UUID
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.ScheduledThreadPoolExecutor
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/** One app-owned broker for both settings and AI. State and durable admission are serialized. */
internal object ShizukuController {
    private const val CHANNEL = "oc/shizuku"
    private const val REQUEST_CODE = 7412
    private const val PREFS = "shizuku_settings"
    private const val ENABLED = "enabled"
    private const val DIRECT_READ_ONLY = "direct_read_only"
    private const val ADVANCED_MODE = "advanced_mode"
    private const val ALLOW_DELAY_SECONDS = "allow_delay_seconds"
    private const val OVERLAY_TIMEOUT_SECONDS = "overlay_timeout_seconds"
    private const val COMMAND_TIMEOUT_SECONDS = "command_timeout_seconds"
    private const val MAX_OUTPUT_KIB = "max_output_kib"
    private val main = Handler(Looper.getMainLooper())
    private val control = ScheduledThreadPoolExecutor(1) { task -> Thread(task, "shizuku-state").apply { isDaemon = true } }
        .apply { removeOnCancelPolicy = true }
    private val rpc = ThreadPoolExecutor(3, 3, 0, TimeUnit.MILLISECONDS, ArrayBlockingQueue(16),
        { task -> Thread(task, "shizuku-ipc").apply { isDaemon = true } })
    private val binding = ShizukuBindingState<IShizukuCommandService>(SystemClock::elapsedRealtime)
    private val initialized = AtomicBoolean(false)
    private val brokerInstance = UUID.randomUUID().toString()
    private var app: Context? = null
    private var sink: EventChannel.EventSink? = null
    private val permission = ShizukuPermissionRequest()
    private var connection: Pair<Long, ServiceConnection>? = null
    private var status = emptyMap<String, Any?>()
    private val waiters = mutableListOf<(ShizukuBindingState.Ready<IShizukuCommandService>?, String?) -> Unit>()
    private val journal by lazy {
        ShizukuOperationJournal(File(requireNotNull(app).filesDir, "shizuku-operations"), System::currentTimeMillis)
    }
    private class Operation(val id: String, val owner: ShizukuProtocol.Owner, val command: String,
                            val timeout: Int, val limit: Int, val ready: ShizukuBindingState.Ready<IShizukuCommandService>) {
        val cancelled = AtomicBoolean(false)
    }
    private val operations = mutableMapOf<String, Operation>()
    private val nativeResults = mutableMapOf<String, MutableList<(JSONObject) -> Unit>>()

    private val serviceArgs by lazy {
        Shizuku.UserServiceArgs(ComponentName(requireNotNull(app), ShizukuCommandService::class.java))
            .daemon(false).version(ShizukuProtocol.SERVICE_VERSION)
            .tag("${requireNotNull(app).packageName}-${android.os.Process.myUid() / 100000}-shizuku")
            .processNameSuffix("shizuku")
    }
    private val received = Shizuku.OnBinderReceivedListener { control.execute {
        // A provider replacement can keep the same UID. It still invalidates the old execution endpoint.
        permission.interrupt("binder_replaced")
        invalidate("binder_replaced")
        refreshNow(true)
    } }
    private val died = Shizuku.OnBinderDeadListener { control.execute {
        permission.interrupt("binder_died")
        invalidate("binder_died")
        publish()
    } }
    private val permissionListener = Shizuku.OnRequestPermissionResultListener { code, value ->
        if (code == REQUEST_CODE) control.execute {
            permission.deliver(value == PackageManager.PERMISSION_GRANTED)
            refreshNow(true)
        }
    }

    fun initialize(context: Context) {
        if (initialized.compareAndSet(false, true)) {
            app = context.applicationContext
            Shizuku.addBinderReceivedListenerSticky(received)
            Shizuku.addBinderDeadListener(died)
            Shizuku.addRequestPermissionResultListener(permissionListener)
        }
    }

    fun register(context: Context, messenger: BinaryMessenger) {
        initialize(context)
        MethodChannel(messenger, CHANNEL).setMethodCallHandler(::handle)
        EventChannel(messenger, "$CHANNEL/events").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) { sink = events; refresh() }
            override fun onCancel(arguments: Any?) { sink = null }
        })
        refresh()
    }
    fun detach() { sink = null }
    fun refresh() { control.execute { refreshNow(true) } }

    private fun refreshNow(retry: Boolean) {
        val context = app ?: return
        val alive = runCatching { Shizuku.pingBinder() }.getOrDefault(false)
        val granted = alive && runCatching { Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED }.getOrDefault(false)
        val uid = if (granted) runCatching { Shizuku.getUid() }.getOrNull() else null
        val version = if (alive) runCatching { Shizuku.getVersion() }.getOrNull() else null
        val enabled = enabled()
        // A revocation made in the manager's list must be reported, not kept as granted.
        if (alive) permission.sync(granted)
        val request = permission.snapshot()
        val unavailable = when {
            !enabled -> "feature_disabled"
            !alive -> "shizuku_not_running"
            request.state == "requesting" -> "permission_request_pending"
            !granted -> "shizuku_permission_missing"
            uid !in setOf(0, 2000) -> "unsupported_identity"
            version == null || version < 11 -> "unsupported_server_version"
            else -> null
        }
        status = mapOf(
            "protocolVersion" to ShizukuProtocol.VERSION, "brokerInstance" to brokerInstance,
            "managerInstalled" to runCatching { context.packageManager.getPackageInfo("moe.shizuku.privileged.api", 0) }.isSuccess,
            "binderAlive" to alive, "overlayAllowed" to android.provider.Settings.canDrawOverlays(context),
            "provider" to if (!alive) "unknown" else if (Sui.isSui()) "sui" else "shizuku",
            "permission" to when { !alive -> "unknown"; granted -> "granted"; request.granted == false -> "denied"; else -> "requestable" },
            "enabled" to enabled, "serverUid" to uid, "serverVersion" to version,
            "selinuxContext" to if (granted) runCatching { Shizuku.getSELinuxContext() }.getOrNull() else null,
            "permissionResult" to request.granted?.let { if (it) PackageManager.PERMISSION_GRANTED else PackageManager.PERMISSION_DENIED },
            "availabilityReason" to unavailable,
            "permissionRequestState" to request.state, "permissionRequestReason" to request.reason,
        )
        if (unavailable != null && binding.snapshot().phase != "disconnected") invalidate(unavailable)
        else if (binding.snapshot().ready?.uid?.let { it != uid } == true) invalidate("identity_changed")
        if (unavailable == null && retry) bind()
        publish()
    }

    private fun snapshot(): Map<String, Any?> {
        val bound = binding.snapshot()
        return status + mapOf("binding" to bound.phase, "bindingReason" to bound.reason,
            "serviceInstance" to bound.ready?.instance, "uid" to bound.ready?.uid,
            "backend" to ShizukuProtocol.backend(bound.ready?.uid), "executionReady" to (bound.ready != null && enabled() && journal.available()),
            "operationStorageReady" to journal.available(), "environment" to "android", "fallback" to false,
            "aiBridgeReady" to ShizukuNativeBridge.available, "aiBridgeReason" to ShizukuNativeBridge.reason)
    }
    private fun publish() { val value = snapshot(); main.post { sink?.success(value) } }
    private fun enabled() = app?.getSharedPreferences(PREFS, Context.MODE_PRIVATE)?.getBoolean(ENABLED, false) == true

    /** Only explicit user actions call this. A cached GRANTED value never skips registration/consent. */
    private fun requestPermissionFromUser() {
        if (permission.snapshot().state == "requesting") return
        if (!runCatching { Shizuku.pingBinder() }.getOrDefault(false)) {
            permission.unavailable("shizuku_not_running")
            publish()
            throw IllegalStateException("shizuku_not_running")
        }
        // Sui has no manager to ask: the server answers a request with a denial that
        // would be reported as the person's own choice. Sui's list is the only owner.
        if (runCatching { Sui.isSui() }.getOrDefault(false)) {
            permission.unavailable("sui_managed_authorization")
            publish()
            throw IllegalStateException("sui_managed_authorization")
        }
        val epoch = permission.begin() ?: return
        // The confirmation is another app's foreground activity and the SDK delivers
        // its result on the main looper, so the call itself is issued there too.
        // A dialog a ROM refuses to show must not be recorded as a failed request.
        main.post {
            if (permission.snapshot().epoch != epoch || permission.snapshot().state != "requesting") return@post
            try { Shizuku.requestPermission(REQUEST_CODE) }
            catch (_: Exception) { control.execute { permission.failed("permission_request_failed"); publish() } }
        }
        // This reports a missing callback, not denial and not a fabricated grant.
        control.schedule({
            val serverGranted = runCatching {
                Shizuku.pingBinder() && Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED
            }.getOrDefault(false)
            if (permission.expire(epoch, serverGranted)) refreshNow(true)
        }, permission.timeoutMs, TimeUnit.MILLISECONDS)
        publish()
    }

    private fun bind() {
        val epoch = binding.begin() ?: return
        val conn = object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName?, service: IBinder?) {
                control.execute {
                    if (!binding.verifying(epoch)) { detachConnection(this, false); return@execute }
                    if (service == null || !service.pingBinder()) { bindFailed(epoch, "binding_died"); return@execute }
                    ipc({
                        val api = IShizukuCommandService.Stub.asInterface(service)
                        val identity = JSONObject(api.status())
                        check(identity.getInt("protocolVersion") == ShizukuProtocol.VERSION)
                        check(identity.getInt("serviceVersion") == ShizukuProtocol.SERVICE_VERSION)
                        val actualUid = identity.getInt("uid")
                        check(actualUid in setOf(0, 2000) && actualUid == Shizuku.getUid())
                        ShizukuBindingState.Ready(api, identity.getString("serviceInstance"), actualUid)
                    }) { ready, error ->
                        if (error != null || ready == null) bindFailed(epoch, "handshake_failed")
                        else if (enabled() && binding.connected(epoch, ready.service, ready.instance, ready.uid)) {
                            runCatching { service.linkToDeath({ control.execute { bindFailed(epoch, "service_died") } }, 0) }
                            resolveWaiters(ready, null)
                            publish()
                        } else { detachConnection(this, false); publish() }
                    }
                }
            }
            override fun onServiceDisconnected(name: ComponentName?) { control.execute { bindFailed(epoch, "binding_died") } }
            override fun onBindingDied(name: ComponentName?) { control.execute { bindFailed(epoch, "binding_died") } }
            override fun onNullBinding(name: ComponentName?) { control.execute { bindFailed(epoch, "binding_null") } }
        }
        connection = epoch to conn // Set before calling SDK: a fast callback must not race this assignment.
        control.schedule({
            if (binding.expire(epoch)) {
                connection?.takeIf { it.first == epoch }?.let { detachConnection(it.second, false); connection = null }
                resolveWaiters(null, binding.snapshot().reason)
                publish()
            }
        }, 10_000, TimeUnit.MILLISECONDS)
        ipc({ Shizuku.bindUserService(serviceArgs, conn) }) { _, error -> if (error != null) bindFailed(epoch, "bind_threw") }
    }

    private fun bindFailed(epoch: Long, reason: String) {
        val old = binding.snapshot().ready
        if (!binding.fail(epoch, reason)) return
        connection?.takeIf { it.first == epoch }?.let { detachConnection(it.second, false); connection = null }
        interruptOperations(old, reason)
        resolveWaiters(null, reason)
        publish()
    }
    private fun detachConnection(conn: ServiceConnection, remove: Boolean) {
        ipc({ Shizuku.unbindUserService(serviceArgs, conn, remove) }) { _, _ -> }
    }
    private fun invalidate(reason: String) {
        val old = binding.snapshot().ready
        binding.reset(reason)
        connection?.let { detachConnection(it.second, reason in setOf("feature_disabled", "user_stopped")) }
        connection = null
        interruptOperations(old, reason)
        resolveWaiters(null, reason)
    }
    private fun acquire(complete: (ShizukuBindingState.Ready<IShizukuCommandService>?, String?) -> Unit) {
        refreshNow(false)
        val why = status["availabilityReason"] as? String
        if (why != null) { complete(null, why); return }
        if (!journal.available()) { complete(null, "operation_storage_unavailable"); return }
        binding.snapshot().ready?.let { complete(it, null); return }
        if (waiters.size >= 4) { complete(null, "bridge_busy"); return }
        waiters.add(complete)
        bind()
    }
    private fun resolveWaiters(ready: ShizukuBindingState.Ready<IShizukuCommandService>?, why: String?) {
        val values = waiters.toList(); waiters.clear(); values.forEach { it(ready, why) }
    }

    /** Bounded workers; a stuck Binder call never allocates an unbounded series of threads. */
    private fun <T> ipc(work: () -> T, complete: (T?, Throwable?) -> Unit) {
        try { rpc.execute {
            val value = runCatching(work)
            control.execute { complete(value.getOrNull(), value.exceptionOrNull()) }
        } } catch (error: Exception) { complete(null, error) }
    }

    fun bridge(request: JSONObject, runtimeId: String, complete: (JSONObject) -> Unit) {
        control.execute {
            try {
                require(request.getInt("protocolVersion") == ShizukuProtocol.VERSION)
                if (!ShizukuNativeBridge.isCurrent(runtimeId, request.getString("bridgeInstance"))) {
                    complete(ShizukuProtocol.error("bridge_instance_changed")); return@execute
                }
                when (request.getString("method")) {
                    "status" -> { refreshNow(true); complete(JSONObject(snapshot())) }
                    "prepare" -> {
                        ShizukuProtocol.owner(request, runtimeId)
                        val command = request.getString("command")
                        val timeout = optionalInt(request, "timeoutMs")
                        ShizukuProtocol.validateCommand(command, timeout)
                        acquire { ready, why ->
                            if (ready == null) complete(ShizukuProtocol.error(why ?: "shizuku_not_ready"))
                            else {
                                val settings = readSettings()
                                val decision = ShizukuCommandPolicy.inspect(command)
                                val admission = ShizukuCommandPolicy.admission(decision, settings[DIRECT_READ_ONLY] == true,
                                    settings[ADVANCED_MODE] == true, settings[ALLOW_DELAY_SECONDS] as Int)
                                complete(JSONObject(snapshot()).put("risk", decision.risk.name.lowercase()).put("operationType", decision.kind)
                                    .put("automatic", admission.automatic).put("timeoutMs", timeout ?: (settings[COMMAND_TIMEOUT_SECONDS] as Int) * 1000))
                            }
                        }
                    }
                    "submit" -> {
                        val owner = ShizukuProtocol.owner(request, runtimeId)
                        val id = request.getString("operationId")
                        val command = request.getString("command")
                        val timeout = optionalInt(request, "timeoutMs")
                        ShizukuProtocol.validateCommand(command, timeout)
                        val expected = binding.snapshot().ready
                        val current = request.getString("brokerInstance") == brokerInstance && expected != null &&
                            request.getString("serviceInstance") == expected.instance && request.getInt("uid") == expected.uid
                        startOperation(id, owner, command, timeout, if (current) expected else null, "instance_changed")
                        complete(checkNotNull(journal.get(id, owner, true)))
                    }
                    "lookup" -> {
                        val owner = ShizukuProtocol.owner(request, runtimeId)
                        val command = request.getString("command")
                        val timeout = optionalInt(request, "timeoutMs")
                        ShizukuProtocol.validateCommand(command, timeout)
                        val id = request.getString("operationId")
                        require(ShizukuProtocol.idPattern.matches(id))
                        complete(journal.lookup(id, owner, ShizukuProtocol.fingerprint(command, timeout))
                            ?: ShizukuProtocol.error("operation_not_found"))
                    }
                    "result" -> {
                        val owner = ShizukuProtocol.owner(request, runtimeId)
                        val id = request.getString("operationId")
                        require(ShizukuProtocol.idPattern.matches(id))
                        reconcile(id, owner, complete)
                    }
                    "cancel" -> {
                        val owner = ShizukuProtocol.owner(request, runtimeId)
                        cancelOperation(request.getString("operationId"), owner)
                        complete(checkNotNull(journal.get(request.getString("operationId"), owner, true)))
                    }
                    else -> complete(ShizukuProtocol.error("unknown_method"))
                }
            } catch (error: Exception) {
                val failure = ShizukuProtocol.error(errorCode(error))
                if (request.optString("method") == "result") failure.put("state", "unknown")
                complete(failure)
            }
        }
    }

    private fun startOperation(id: String, owner: ShizukuProtocol.Owner, command: String, timeout: Int?,
                               expected: ShizukuBindingState.Ready<IShizukuCommandService>?, unavailable: String) {
        require(ShizukuProtocol.idPattern.matches(id))
        if (!journal.admit(id, owner, ShizukuProtocol.fingerprint(command, timeout))) return
        if (expected == null || !current(expected)) { journal.failBeforeDispatch(id, unavailable); return }
        if (operations.isNotEmpty()) { journal.failBeforeDispatch(id, "busy"); return }
        val settings = readSettings()
        val op = Operation(id, owner, command, timeout ?: (settings[COMMAND_TIMEOUT_SECONDS] as Int) * 1000,
            (settings[MAX_OUTPUT_KIB] as Int) * 1024, expected)
        operations[id] = op
        val decision = ShizukuCommandPolicy.inspect(command)
        val admission = ShizukuCommandPolicy.admission(decision, settings[DIRECT_READ_ONLY] == true,
            settings[ADVANCED_MODE] == true, settings[ALLOW_DELAY_SECONDS] as Int)
        if (admission.automatic) { dispatch(op); return }
        if (!android.provider.Settings.canDrawOverlays(requireNotNull(app))) { deny(op, "overlay_permission_missing"); return }
        journal.waiting(id)
        ShizukuSafetyOverlay.confirm(app!!, command, decision, admission.allowDelaySeconds,
            settings[OVERLAY_TIMEOUT_SECONDS] as Int, operationId = id, requestSource = owner.source) { allowed ->
            control.execute {
                if (op.cancelled.get() || operations[id] !== op) return@execute
                if (!allowed) deny(op, "confirmation_denied_or_timeout")
                else if (!current(op.ready)) deny(op, "instance_changed")
                else dispatch(op)
            }
        }
    }
    private fun current(expected: ShizukuBindingState.Ready<IShizukuCommandService>): Boolean {
        val ready = binding.snapshot().ready
        return enabled() && ready != null && ready.service === expected.service && ready.instance == expected.instance && ready.uid == expected.uid
    }
    private fun deny(op: Operation, why: String) {
        journal.failBeforeDispatch(op.id, why)
        operations.remove(op.id, op)
        deliverNative(op.id, op.owner)
    }
    private fun dispatch(op: Operation) {
        refreshNow(false) // Recheck permission and actual server UID after the confirmation wait.
        if (operations[op.id] !== op) return
        if (op.cancelled.get() || !current(op.ready)) { deny(op, "instance_changed"); return }
        if (!journal.dispatch(op.id, op.ready.instance, op.ready.uid)) { operations.remove(op.id, op); deliverNative(op.id, op.owner); return }
        val deadline = control.schedule({
            if (operations[op.id] !== op) return@schedule
            journal.uncertain(op.id, "service_call_timeout")
            op.cancelled.set(true)
            ipc({ op.ready.service.cancel(op.id) }) { _, _ -> }
            operations.remove(op.id, op)
            deliverNative(op.id, op.owner)
            invalidate("service_call_timeout")
            publish()
        }, op.timeout.toLong() + 5000, TimeUnit.MILLISECONDS)
        ipc({
            if (op.cancelled.get()) JSONObject().put("operationId", op.id).put("serviceInstance", op.ready.instance)
                .put("uid", op.ready.uid).put("state", "cancelled").put("reason", "cancelled_before_service_call")
                .put("termination", "confirmed").put("stdout", "").put("stderr", "").put("truncated", false)
            else JSONObject(op.ready.service.execute(op.id, op.ready.instance, op.ready.uid, op.command, op.timeout, op.limit))
        }) { response, error ->
            deadline.cancel(false)
            try {
                if (error != null || response == null) journal.uncertain(op.id, "execution_result_unconfirmed")
                else journal.finish(op.id, op.ready.instance, op.ready.uid, response)
            } catch (_: Exception) { runCatching { journal.uncertain(op.id, "invalid_execution_result") } }
            operations.remove(op.id, op)
            deliverNative(op.id, op.owner)
            publish()
        }
    }

    private fun cancelOperation(id: String, owner: ShizukuProtocol.Owner) {
        val value = journal.cancel(id, owner) // Commit before dismissing or sending Binder cancellation.
        val op = operations[id]
        op?.cancelled?.set(true)
        ShizukuSafetyOverlay.cancel(id)
        if (value.getString("state") == "cancelled") {
            if (op != null) operations.remove(id, op)
            deliverNative(id, owner)
        } else if (op != null) ipc({ op.ready.service.cancel(id) }) { _, _ -> }
        else binding.snapshot().ready?.takeIf { value.optString("serviceInstance") == it.instance }?.let {
            ipc({ it.service.cancel(id) }) { _, _ -> } // Reconnected operations are inspected/cancelled, never re-launched.
        }
    }

    private fun interruptOperations(old: ShizukuBindingState.Ready<IShizukuCommandService>?, why: String) {
        for (op in operations.values.toList()) {
            if (old != null && op.ready.service !== old.service) continue
            op.cancelled.set(true)
            ShizukuSafetyOverlay.cancel(op.id)
            runCatching { journal.failBeforeDispatch(op.id, why); journal.uncertain(op.id, why) }
            ipc({ op.ready.service.cancel(op.id) }) { _, _ -> }
            operations.remove(op.id, op)
            deliverNative(op.id, op.owner)
        }
    }
    fun stopRuntime() { control.execute {
        for (op in operations.values.toList()) if (op.owner.source == "opencode_tool") runCatching { cancelOperation(op.id, op.owner) }
    } }
    fun stopAll() { control.execute { permission.interrupt("user_stopped"); invalidate("user_stopped"); publish() } }

    private fun reconcile(id: String, owner: ShizukuProtocol.Owner, complete: (JSONObject) -> Unit) {
        val row = journal.get(id, owner) ?: run { complete(ShizukuProtocol.error("operation_not_found")); return }
        val ready = binding.snapshot().ready
        if (row.getString("state") != "unknown" || ready == null || row.optString("serviceInstance") != ready.instance) {
            complete(row); return
        }
        val delivered = AtomicBoolean(false)
        val watchdog = control.schedule({ if (delivered.compareAndSet(false, true)) complete(row) }, 2000, TimeUnit.MILLISECONDS)
        ipc({ JSONObject(ready.service.result(id)) }) { value, error ->
            if (error == null && value != null && value.optString("state") in setOf("succeeded", "failed", "cancelled", "unknown") && value.has("stdout")) {
                runCatching { journal.finish(id, ready.instance, ready.uid, value) }
            }
            if (delivered.compareAndSet(false, true)) {
                watchdog.cancel(false)
                val knownRunning = error == null && value != null && value.optString("state") == "running" &&
                    value.optString("operationId") == id && value.optString("serviceInstance") == ready.instance && value.optInt("uid", -1) == ready.uid
                complete(if (knownRunning) JSONObject(row.toString()).put("state", "running").put("reason", "reconnected_running")
                    else runCatching { journal.get(id, owner) }.getOrNull() ?: row)
            }
        }
    }
    private fun deliverNative(id: String, owner: ShizukuProtocol.Owner) {
        val callbacks = nativeResults.remove(id) ?: return
        val value = runCatching { journal.get(id, owner, true) }.getOrNull() ?: ShizukuProtocol.error("operation_storage_unavailable")
        callbacks.forEach { it(value) }
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        fun respond(value: JSONObject) { main.post { result.success(jsonMap(value)) } }
        when (call.method) {
            "overlaySettings", "openManager" -> {
                try {
                    val context = requireNotNull(app)
                    val intent = if (call.method == "overlaySettings") Intent(android.provider.Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                        Uri.parse("package:${context.packageName}"))
                    else context.packageManager.getLaunchIntentForPackage("moe.shizuku.privileged.api")
                        ?: Intent(Intent.ACTION_VIEW, Uri.parse("https://shizuku.rikka.app/download/"))
                    context.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)); result.success(true)
                } catch (_: Exception) { result.error("settings_unavailable", "Could not open system settings or Shizuku manager.", null) }
            }
            else -> control.execute {
                try {
                    when (call.method) {
                        "status" -> { refreshNow(true); respond(JSONObject(snapshot())) }
                        "settings" -> main.post { result.success(readSettings()) }
                        "saveSettings" -> saveSettings(call, result)
                        "requestPermission" -> {
                            requestPermissionFromUser()
                            main.post { result.success(true) }
                        }
                        "setEnabled" -> {
                            val requested = call.argument<Boolean>("enabled") == true
                            check(app!!.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
                                .putBoolean(ENABLED, requested).commit())
                            if (requested) runCatching { requestPermissionFromUser() }
                            else permission.interrupt("feature_disabled")
                            refreshNow(true); respond(JSONObject(snapshot()))
                        }
                        "startService" -> acquire { ready, why ->
                            if (ready == null) main.post { result.error(why ?: "shizuku_not_ready", "Shizuku UserService is not ready.", null) }
                            else main.post { result.success(true) }
                        }
                        "execute", "diagnostic" -> {
                            val id = call.argument<String>("operationId") ?: UUID.randomUUID().toString()
                            val command = if (call.method == "diagnostic") ShizukuCommandPolicy.DIAGNOSTIC else call.argument<String>("command") ?: ""
                            val timeout = call.argument<Int>("timeoutMs")
                            ShizukuProtocol.validateCommand(command, timeout)
                            require(ShizukuProtocol.idPattern.matches(id))
                            val owner = ShizukuProtocol.settingsOwner()
                            acquire { ready, why ->
                                try {
                                    startOperation(id, owner, command, timeout, ready, why ?: "shizuku_not_ready")
                                    val row = checkNotNull(journal.get(id, owner, true))
                                    if (row.getString("state") in setOf("queued", "waiting", "running")) {
                                        val callbacks = nativeResults.getOrPut(id) { mutableListOf() }
                                        if (callbacks.size < 4) callbacks.add(::respond)
                                        else main.post { result.error("operation_waiters_full", "This operation already has waiting callers.", null) }
                                    } else respond(row)
                                } catch (error: Exception) { main.post { result.error(errorCode(error), "Shizuku command was not admitted.", null) } }
                            }
                        }
                        "cancel" -> {
                            val id = call.argument<String>("operationId") ?: ""
                            cancelOperation(id, ShizukuProtocol.settingsOwner())
                            val row = journal.get(id, ShizukuProtocol.settingsOwner(), true)
                            main.post { result.success(row?.optString("state") == "cancelled") }
                        }
                        else -> main.post { result.notImplemented() }
                    }
                } catch (error: Exception) { main.post { result.error(errorCode(error), "Shizuku request failed. No fallback was used.", null) } }
            }
        }
    }

    private fun readSettings(): Map<String, Any> {
        val prefs = requireNotNull(app).getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        return mapOf(DIRECT_READ_ONLY to prefs.getBoolean(DIRECT_READ_ONLY, true), ADVANCED_MODE to prefs.getBoolean(ADVANCED_MODE, false),
            ALLOW_DELAY_SECONDS to prefs.getInt(ALLOW_DELAY_SECONDS, 10).coerceIn(0, 60),
            OVERLAY_TIMEOUT_SECONDS to prefs.getInt(OVERLAY_TIMEOUT_SECONDS, 30).coerceIn(10, 120),
            COMMAND_TIMEOUT_SECONDS to prefs.getInt(COMMAND_TIMEOUT_SECONDS, 30).coerceIn(1, 120),
            MAX_OUTPUT_KIB to prefs.getInt(MAX_OUTPUT_KIB, 64).coerceIn(4, 256))
    }
    private fun saveSettings(call: MethodCall, result: MethodChannel.Result) {
        val direct = call.argument<Boolean>(DIRECT_READ_ONLY)
        val advanced = call.argument<Boolean>(ADVANCED_MODE)
        val delay = call.argument<Int>(ALLOW_DELAY_SECONDS)
        val overlay = call.argument<Int>(OVERLAY_TIMEOUT_SECONDS)
        val timeout = call.argument<Int>(COMMAND_TIMEOUT_SECONDS)
        val output = call.argument<Int>(MAX_OUTPUT_KIB)
        require(direct != null && advanced != null && delay != null && delay in 0..60 && overlay != null && overlay in 10..120 &&
            timeout != null && timeout in 1..120 && output != null && output in 4..256 && overlay > delay) { "invalid_settings" }
        check(app!!.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putBoolean(DIRECT_READ_ONLY, direct).putBoolean(ADVANCED_MODE, advanced)
            .putInt(ALLOW_DELAY_SECONDS, delay).putInt(OVERLAY_TIMEOUT_SECONDS, overlay).putInt(COMMAND_TIMEOUT_SECONDS, timeout)
            .putInt(MAX_OUTPUT_KIB, output).commit())
        main.post { result.success(readSettings()) }
    }
    private fun optionalInt(value: JSONObject, key: String): Int? = if (!value.has(key) || value.isNull(key)) null else {
        val raw = value.get(key); require(raw is Number && raw.toDouble() == raw.toInt().toDouble()); raw.toInt()
    }
    private fun errorCode(error: Exception): String = error.message?.takeIf { it in setOf("operation_conflict", "operation_history_full",
        "operation_storage_unavailable", "invalid_settings", "shizuku_not_running", "permission_request_failed",
        "sui_managed_authorization") } ?: "invalid_request"
    private fun jsonMap(value: JSONObject): Map<String, Any?> = value.keys().asSequence().associateWith {
        if (value.isNull(it)) null else value.get(it)
    }
}
