package com.azx8788.opencode.mini.shizuku

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
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import rikka.shizuku.Shizuku
import java.io.File
import java.util.UUID
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.ScheduledThreadPoolExecutor
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * The single owner of Shizuku state in this app.
 *
 * Everything that changes state runs on one serial executor, so a status read
 * can never interleave with a bind or a revocation. Nothing here reports
 * "authorized" without a live server answer; nothing executes without a
 * handshaken UserService and readable operation records.
 */
internal object ShizukuRuntime {
    const val CHANNEL = "oc/shizuku"
    const val EVENTS = "oc/shizuku/events"
    private const val PREFS = "shizuku_settings"
    private const val ENABLED = "enabled"
    private const val DIRECT_READ_ONLY = "direct_read_only"
    private const val ADVANCED_MODE = "advanced_mode"
    private const val ALLOW_DELAY_SECONDS = "allow_delay_seconds"
    private const val OVERLAY_TIMEOUT_SECONDS = "overlay_timeout_seconds"
    private const val COMMAND_TIMEOUT_SECONDS = "command_timeout_seconds"
    private const val MAX_OUTPUT_KIB = "max_output_kib"
    private const val FIRST_REQUEST_CODE = 7412

    private val main = Handler(Looper.getMainLooper())
    private val control = ScheduledThreadPoolExecutor(1) { task ->
        Thread(task, "shizuku-state").apply { isDaemon = true }
    }.apply { removeOnCancelPolicy = true }
    private val ipc = ThreadPoolExecutor(
        3, 3, 0, TimeUnit.MILLISECONDS, ArrayBlockingQueue(16),
    ) { task -> Thread(task, "shizuku-ipc").apply { isDaemon = true } }

    private val initialized = AtomicBoolean(false)
    private val brokerInstance = UUID.randomUUID().toString()
    private var app: Context? = null
    private var sink: EventChannel.EventSink? = null

    private var environment: EnvironmentProbe? = null
    private val authorizationProbe = ServerAuthorizationProbe.fromSdk()
    private val identityProbe = ServerIdentityProbe { Shizuku.getBinder() }

    private val request = AuthorizationRequest()
    private val session = SessionState(SystemClock::elapsedRealtime)
    private var nextRequestCode = FIRST_REQUEST_CODE

    private var authorization = AuthorizationReading.unknown("not_checked", 0)
    private var identity = ServerIdentity.EMPTY
    private var binder = BinderState.ABSENT
    private var binderGeneration = 0L
    private var provider = ProviderKind.UNKNOWN
    private var manager = ManagerState.UNKNOWN
    private var registration = Registration("", false, false, false, null)
    private var lastSnapshot: ShizukuSnapshot? = null

    private var connection: Pair<Long, ServiceConnection>? = null
    private val waiters = mutableListOf<(Ready?, String?) -> Unit>()

    private val journal by lazy {
        OperationJournal(File(requireNotNull(app).filesDir, "shizuku-operations"), System::currentTimeMillis)
    }

    internal class Ready(
        val service: IShizukuCommandService,
        val instance: String,
        val uid: Int,
    )

    private class Operation(
        val id: String,
        val owner: Protocol.Owner,
        val command: String,
        val timeoutMs: Int,
        val limitBytes: Int,
        val ready: Ready,
    ) {
        val cancelled = AtomicBoolean(false)
    }

    private val operations = mutableMapOf<String, Operation>()
    private val nativeResults = mutableMapOf<String, MutableList<(JSONObject) -> Unit>>()

    private val serviceArgs by lazy {
        val context = requireNotNull(app)
        Shizuku.UserServiceArgs(ComponentName(context, CommandService::class.java))
            .daemon(false)
            .version(ShizukuContract.SERVICE_VERSION)
            .tag("${context.packageName}-${android.os.Process.myUid() / 100000}-shizuku")
            .processNameSuffix("shizuku")
    }

    private val received = Shizuku.OnBinderReceivedListener {
        control.execute {
            binderGeneration++
            request.interrupt("binder_replaced")
            invalidateSession("binder_replaced")
            refreshNow(bind = true)
        }
    }

    private val died = Shizuku.OnBinderDeadListener {
        control.execute {
            binderGeneration++
            binder = BinderState.DEAD
            authorization = AuthorizationReading.unknown("binder_dead", System.currentTimeMillis())
            request.interrupt("binder_died")
            invalidateSession("binder_died")
            publish()
        }
    }

    private val permissionListener = Shizuku.OnRequestPermissionResultListener { code, value ->
        control.execute {
            if (request.deliver(code, value == PackageManager.PERMISSION_GRANTED)) {
                refreshNow(bind = true)
            }
        }
    }

    // ---------------------------------------------------------------- lifecycle

    fun initialize(context: Context) {
        if (!initialized.compareAndSet(false, true)) return
        val application = context.applicationContext
        app = application
        environment = EnvironmentProbe(application)
        Shizuku.addBinderReceivedListenerSticky(received)
        Shizuku.addBinderDeadListener(died)
        Shizuku.addRequestPermissionResultListener(permissionListener)
    }

    fun register(context: Context, messenger: BinaryMessenger) {
        initialize(context)
        MethodChannel(messenger, CHANNEL).setMethodCallHandler(::handle)
        EventChannel(messenger, EVENTS).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                sink = events
                refresh()
            }

            override fun onCancel(arguments: Any?) {
                sink = null
            }
        })
        refresh()
    }

    fun detach() {
        sink = null
    }

    fun refresh() {
        control.execute { refreshNow(bind = true) }
    }

    /** Called when the built-in server stops: only the AI-owned operations are stopped. */
    fun stopRuntime() {
        control.execute {
            for (operation in operations.values.toList()) {
                if (operation.owner.source == SOURCE_TOOL) {
                    runCatching { cancelOperation(operation.id, operation.owner) }
                }
            }
        }
    }

    /** Called when the feature is turned off or the app tears the runtime down. */
    fun stopAll() {
        control.execute {
            request.interrupt("feature_stopped")
            invalidateSession("feature_stopped")
            publish()
        }
    }

    // ------------------------------------------------------------------ state

    private fun refreshNow(bind: Boolean) {
        val context = app ?: return
        val now = System.currentTimeMillis()
        binder = binderState()
        provider = environment?.provider() ?: ProviderKind.UNKNOWN
        manager = environment?.manager() ?: ManagerState.UNKNOWN
        registration = environment?.registration() ?: registration

        authorization = if (binder == BinderState.ALIVE) {
            authorizationProbe.read(now)
        } else {
            AuthorizationReading.unknown("binder_absent", now)
        }
        request.sync(authorization)
        identity = if (binder == BinderState.ALIVE) identityProbe.read() else ServerIdentity.EMPTY

        val snapshot = snapshotNow(context, now)
        lastSnapshot = snapshot

        val blocked = snapshot.blockedBy
        if (blocked != null && session.status().phase != SessionPhase.STOPPED &&
            session.status().phase != SessionPhase.FAILED
        ) {
            invalidateSession(blocked)
        }
        if (blocked == null && bind) bindSession()
        publishSnapshot(snapshot)
    }

    private fun binderState(): BinderState {
        val raw = try {
            Shizuku.getBinder()
        } catch (_: Throwable) {
            null
        } ?: return BinderState.ABSENT
        return if (try { raw.pingBinder() } catch (_: Throwable) { false }) BinderState.ALIVE else BinderState.DEAD
    }

    private fun snapshotNow(context: Context, now: Long): ShizukuSnapshot {
        val storageReady = runCatching { journal.available() }.getOrDefault(false)
        return ShizukuSnapshot(
            observedAt = now,
            featureEnabled = enabled(),
            manager = manager,
            registration = registration,
            binder = binder,
            binderGeneration = binderGeneration,
            provider = provider,
            authorization = authorization,
            request = request.status(),
            identity = identity,
            session = session.status(),
            storageReady = storageReady,
            storageReason = if (storageReady) null else "operation_storage_unavailable",
            bridgeReady = NativeBridge.available,
            bridgeReason = NativeBridge.reason,
            overlayAllowed = runCatching { Settings.canDrawOverlays(context) }.getOrDefault(false),
        )
    }

    private fun currentSnapshot(): ShizukuSnapshot =
        snapshotNow(requireNotNull(app), System.currentTimeMillis())

    private fun publish() = publishSnapshot(currentSnapshot())

    private fun publishSnapshot(snapshot: ShizukuSnapshot) {
        lastSnapshot = snapshot
        val value = bridgeJson(snapshot)
        main.post { sink?.success(value) }
    }

    /**
     * The status the settings page and the AI tool both read. The flat fields
     * at the end are the bridge contract the installed plugin already uses.
     */
    private fun bridgeJson(snapshot: ShizukuSnapshot): Map<String, Any?> {
        val ready = session.status().phase == SessionPhase.READY
        val value = plain(snapshot.toJson()) as MutableMap<String, Any?>
        value["brokerInstance"] = brokerInstance
        value["executionReady"] = snapshot.executionAdmitted && ready
        value["uid"] = snapshot.session.uid ?: snapshot.identity.uid
        value["backend"] = snapshot.identity.backend
        value["serviceInstance"] = snapshot.session.instance
        value["enabled"] = snapshot.featureEnabled
        value["environment"] = "android"
        value["fallback"] = false
        return value
    }

    /** StandardMethodCodec carries maps and lists, not JSONObject/JSONArray. */
    private fun plain(value: Any?): Any? = when (value) {
        is JSONObject -> value.keys().asSequence().associateWithTo(mutableMapOf()) { key ->
            if (value.isNull(key)) null else plain(value.get(key))
        }
        is org.json.JSONArray -> (0 until value.length()).map { plain(value.get(it)) }
        JSONObject.NULL -> null
        else -> value
    }

    private fun enabled(): Boolean =
        app?.getSharedPreferences(PREFS, Context.MODE_PRIVATE)?.getBoolean(ENABLED, false) == true

    // ---------------------------------------------------------- authorization

    /**
     * Only an explicit user action reaches this. A cached grant never skips it,
     * and a missing callback never becomes a decision.
     */
    private fun requestAuthorization() {
        if (request.pending()) throw IllegalStateException("request_already_pending")
        if (binder != BinderState.ALIVE) {
            request.unavailable("shizuku_not_running")
            publish()
            throw IllegalStateException("shizuku_not_running")
        }
        if (!registration.listed) {
            request.unavailable("app_not_listed")
            publish()
            throw IllegalStateException("app_not_listed")
        }
        if (authorization.state == AuthorizationState.GRANTED) {
            // Already allowed: there is nothing to ask, and pretending to ask
            // would produce a dialog the server answers instantly.
            refreshNow(bind = true)
            return
        }
        val refusal = request.refusal(System.currentTimeMillis())
        if (refusal != null) throw IllegalStateException(refusal)

        val code = nextRequestCode
        nextRequestCode = if (code == Int.MAX_VALUE) FIRST_REQUEST_CODE else code + 1
        val epoch = request.begin(code, System.currentTimeMillis()) ?: return
        // The confirmation is another app's activity and the SDK delivers the
        // result on the main looper.
        main.post {
            if (request.status().requestCode != code) return@post
            try {
                Shizuku.requestPermission(code)
            } catch (error: Throwable) {
                control.execute {
                    val reason = if (error is IllegalStateException && error.message == "Not an attached client") {
                        "client_not_attached"
                    } else {
                        "permission_request_failed"
                    }
                    if (request.failed(epoch, code, reason)) publish()
                }
            }
        }
        // A dialog that never answers is "unconfirmed", never a denial.
        control.schedule({
            val live = if (binder == BinderState.ALIVE) {
                authorizationProbe.read(System.currentTimeMillis())
            } else {
                AuthorizationReading.unknown("binder_absent", System.currentTimeMillis())
            }
            if (request.expire(epoch, live)) refreshNow(bind = live.state == AuthorizationState.GRANTED)
        }, AuthorizationRequest.DEFAULT_TIMEOUT_MS, TimeUnit.MILLISECONDS)
        publish()
    }

    // -------------------------------------------------------------- UserService

    private fun bindSession() {
        if (!authorization.grantsExecution) return
        val epoch = session.begin() ?: return
        val connectionObject = object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName?, service: IBinder?) {
                control.execute {
                    if (!session.handshaking(epoch)) {
                        release(this, false)
                        return@execute
                    }
                    if (service == null || !runCatching { service.pingBinder() }.getOrDefault(false)) {
                        failSession(epoch, "binding_died")
                        return@execute
                    }
                    ipc({
                        val api = IShizukuCommandService.Stub.asInterface(service)
                        val status = JSONObject(api.status())
                        Handshake(
                            protocol = status.getInt("protocolVersion"),
                            serviceVersion = status.getInt("serviceVersion"),
                            instance = status.getString("serviceInstance"),
                            uid = status.getInt("uid"),
                        )
                    }) { handshake, error ->
                        val serverUid = identity.uid
                        if (error != null || handshake == null) {
                            failSession(epoch, "handshake_failed")
                        } else if (handshake.protocol != Protocol.VERSION) {
                            failSession(epoch, "protocol_mismatch")
                        } else if (serverUid == null || handshake.uid != serverUid) {
                            failSession(epoch, "identity_mismatch")
                        } else if (session.connected(epoch, handshake.instance, handshake.uid, handshake.serviceVersion)) {
                            runCatching {
                                service.linkToDeath({ control.execute { failSession(epoch, "service_died") } }, 0)
                            }
                            resolveWaiters(Ready(IShizukuCommandService.Stub.asInterface(service), handshake.instance, handshake.uid), null)
                            publish()
                        } else {
                            release(this, false)
                        }
                    }
                }
            }

            override fun onServiceDisconnected(name: ComponentName?) {
                control.execute { failSession(epoch, "binding_died") }
            }

            override fun onBindingDied(name: ComponentName?) {
                control.execute { failSession(epoch, "binding_died") }
            }

            override fun onNullBinding(name: ComponentName?) {
                control.execute { failSession(epoch, "binding_null") }
            }
        }
        connection = epoch to connectionObject
        control.schedule({
            if (session.expire(epoch)) {
                connection?.takeIf { it.first == epoch }?.let {
                    release(it.second, false)
                    connection = null
                }
                resolveWaiters(null, session.status().reason)
                publish()
            }
        }, 10_000, TimeUnit.MILLISECONDS)
        ipc({ Shizuku.bindUserService(serviceArgs, connectionObject) }) { _, error ->
            if (error != null) failSession(epoch, "bind_threw")
        }
    }

    private data class Handshake(val protocol: Int, val serviceVersion: Int, val instance: String, val uid: Int)

    private fun failSession(epoch: Long, reason: String) {
        if (!session.fail(epoch, reason)) return
        connection?.takeIf { it.first == epoch }?.let {
            release(it.second, false)
            connection = null
        }
        interruptOperations(reason)
        resolveWaiters(null, reason)
        publish()
    }

    private fun invalidateSession(reason: String) {
        session.reset(reason)
        connection?.let { release(it.second, reason == "feature_stopped") }
        connection = null
        interruptOperations(reason)
        resolveWaiters(null, reason)
    }

    private fun release(conn: ServiceConnection, remove: Boolean) {
        ipc({ Shizuku.unbindUserService(serviceArgs, conn, remove) }) { _, _ -> }
    }

    private fun acquire(complete: (Ready?, String?) -> Unit) {
        refreshNow(bind = false)
        val snapshot = currentSnapshot()
        val blocked = snapshot.blockedBy
        if (blocked != null) {
            complete(null, blocked)
            return
        }
        if (session.status().phase == SessionPhase.READY) {
            val ready = lastReady
            if (ready != null) {
                complete(ready, null)
                return
            }
            // Ready without a service handle cannot be true; rebind instead of
            // leaving the caller waiting for an answer that cannot arrive.
            invalidateSession("ready_without_service")
        }
        if (waiters.size >= 4) {
            complete(null, "bridge_busy")
            return
        }
        waiters.add(complete)
        bindSession()
    }

    private var lastReady: Ready? = null

    private fun resolveWaiters(ready: Ready?, why: String?) {
        lastReady = ready
        val values = waiters.toList()
        waiters.clear()
        values.forEach { it(ready, why) }
    }

    private fun <T> ipc(work: () -> T, complete: (T?, Throwable?) -> Unit) {
        try {
            ipc.execute {
                val value = runCatching(work)
                control.execute { complete(value.getOrNull(), value.exceptionOrNull()) }
            }
        } catch (error: Exception) {
            complete(null, error)
        }
    }

    // --------------------------------------------------------------- execution

    /**
     * Records the admission decision and starts the operation. Returns the row
     * as it stands right after admission (queued, waiting, running, denied...).
     * A caller that wants the final result registers in [nativeResults].
     */
    private fun admit(
        id: String,
        owner: Protocol.Owner,
        command: String,
        timeout: Int?,
        ready: Ready?,
        why: String?,
    ): JSONObject {
        if (!journal.admit(id, owner, Protocol.fingerprint(command, timeout))) {
            return row(id, owner)
        }
        if (ready == null) {
            journal.failBeforeDispatch(id, why ?: "shizuku_not_ready")
            return row(id, owner)
        }
        // Re-read the live answer: the confirmation below can take a minute,
        // and a revocation during it must not be followed by a command.
        val live = if (binder == BinderState.ALIVE) {
            authorizationProbe.read(System.currentTimeMillis())
        } else {
            AuthorizationReading.unknown("binder_absent", System.currentTimeMillis())
        }
        authorization = live
        request.sync(live)
        if (!live.grantsExecution) {
            journal.failBeforeDispatch(
                id,
                if (live.state == AuthorizationState.DENIED) "authorization_denied" else "authorization_unconfirmed",
            )
            return row(id, owner)
        }
        if (operations.isNotEmpty()) {
            journal.failBeforeDispatch(id, "busy")
            return row(id, owner)
        }
        val settings = readPolicy()
        val operation = Operation(
            id, owner, command,
            timeout ?: (settings[COMMAND_TIMEOUT_SECONDS] as Int) * 1000,
            (settings[MAX_OUTPUT_KIB] as Int) * 1024,
            ready,
        )
        operations[id] = operation
        val decision = CommandPolicy.inspect(command)
        val admission = CommandPolicy.admission(
            decision,
            settings[DIRECT_READ_ONLY] == true,
            settings[ADVANCED_MODE] == true,
            settings[ALLOW_DELAY_SECONDS] as Int,
        )
        if (admission.automatic) {
            dispatch(operation)
            return row(id, owner)
        }
        if (!runCatching { Settings.canDrawOverlays(requireNotNull(app)) }.getOrDefault(false)) {
            deny(operation, "overlay_permission_missing")
            return row(id, owner)
        }
        journal.waiting(id)
        SafetyOverlay.confirm(
            requireNotNull(app), command, decision, admission.allowDelaySeconds,
            settings[OVERLAY_TIMEOUT_SECONDS] as Int,
            operationId = id,
            requestSource = owner.source,
        ) { allowed ->
            control.execute {
                if (operation.cancelled.get() || operations[id] !== operation) return@execute
                when {
                    !allowed -> deny(operation, "confirmation_denied_or_timeout")
                    !isCurrent(operation.ready) -> deny(operation, "instance_changed")
                    else -> dispatch(operation)
                }
            }
        }
        return row(id, owner)
    }

    private fun row(id: String, owner: Protocol.Owner): JSONObject =
        runCatching { journal.get(id, owner, true) }.getOrNull()
            ?: Protocol.error("operation_storage_unavailable")

    private fun isCurrent(ready: Ready): Boolean {
        val status = session.status()
        return enabled() && status.phase == SessionPhase.READY && status.instance == ready.instance &&
            status.uid == ready.uid && lastReady?.service === ready.service
    }

    private fun deny(operation: Operation, why: String) {
        journal.failBeforeDispatch(operation.id, why)
        operations.remove(operation.id, operation)
        deliverNative(operation.id, operation.owner)
    }

    private fun dispatch(operation: Operation) {
        refreshNow(bind = false)
        if (operations[operation.id] !== operation) return
        if (operation.cancelled.get() || !isCurrent(operation.ready)) {
            deny(operation, "instance_changed")
            return
        }
        if (!journal.dispatch(operation.id, operation.ready.instance, operation.ready.uid)) {
            operations.remove(operation.id, operation)
            deliverNative(operation.id, operation.owner)
            return
        }
        val watchdog = control.schedule({
            if (operations[operation.id] !== operation) return@schedule
            journal.uncertain(operation.id, "service_call_timeout")
            operation.cancelled.set(true)
            ipc({ operation.ready.service.cancel(operation.id) }) { _, _ -> }
            operations.remove(operation.id, operation)
            deliverNative(operation.id, operation.owner)
            invalidateSession("service_call_timeout")
            publish()
        }, operation.timeoutMs.toLong() + 5_000, TimeUnit.MILLISECONDS)
        ipc({
            if (operation.cancelled.get()) {
                JSONObject().put("operationId", operation.id).put("serviceInstance", operation.ready.instance)
                    .put("uid", operation.ready.uid).put("state", "cancelled")
                    .put("reason", "cancelled_before_service_call").put("termination", "confirmed")
                    .put("stdout", "").put("stderr", "").put("truncated", false)
            } else {
                JSONObject(
                    operation.ready.service.execute(
                        operation.id, operation.ready.instance, operation.ready.uid,
                        operation.command, operation.timeoutMs, operation.limitBytes,
                    ),
                )
            }
        }) { response, error ->
            watchdog.cancel(false)
            try {
                if (error != null || response == null) {
                    journal.uncertain(operation.id, "execution_result_unconfirmed")
                } else {
                    journal.finish(operation.id, operation.ready.instance, operation.ready.uid, response)
                }
            } catch (_: Exception) {
                runCatching { journal.uncertain(operation.id, "invalid_execution_result") }
            }
            operations.remove(operation.id, operation)
            deliverNative(operation.id, operation.owner)
            publish()
        }
    }

    private fun cancelOperation(id: String, owner: Protocol.Owner) {
        val value = journal.cancel(id, owner)
        val operation = operations[id]
        operation?.cancelled?.set(true)
        SafetyOverlay.cancel(id)
        if (value.getString("state") == "cancelled") {
            if (operation != null) operations.remove(id, operation)
            deliverNative(id, owner)
        } else if (operation != null) {
            ipc({ operation.ready.service.cancel(id) }) { _, _ -> }
        } else {
            // A reconnected operation is inspected and cancelled, never relaunched.
            lastReady?.takeIf { value.optString("serviceInstance") == it.instance }?.let {
                ipc({ it.service.cancel(id) }) { _, _ -> }
            }
        }
    }

    private fun interruptOperations(why: String) {
        for (operation in operations.values.toList()) {
            operation.cancelled.set(true)
            SafetyOverlay.cancel(operation.id)
            runCatching {
                journal.failBeforeDispatch(operation.id, why)
                journal.uncertain(operation.id, why)
            }
            ipc({ operation.ready.service.cancel(operation.id) }) { _, _ -> }
            operations.remove(operation.id, operation)
            deliverNative(operation.id, operation.owner)
        }
    }

    private fun reconcile(id: String, owner: Protocol.Owner, complete: (JSONObject) -> Unit) {
        val row = journal.get(id, owner) ?: run {
            complete(Protocol.error("operation_not_found"))
            return
        }
        val ready = lastReady
        if (row.getString("state") != "unknown" || ready == null ||
            row.optString("serviceInstance") != ready.instance
        ) {
            complete(row)
            return
        }
        val delivered = AtomicBoolean(false)
        val watchdog = control.schedule({
            if (delivered.compareAndSet(false, true)) complete(row)
        }, 2_000, TimeUnit.MILLISECONDS)
        ipc({ JSONObject(ready.service.result(id)) }) { value, error ->
            if (error == null && value != null &&
                value.optString("state") in setOf("succeeded", "failed", "cancelled", "unknown") &&
                value.has("stdout")
            ) {
                runCatching { journal.finish(id, ready.instance, ready.uid, value) }
            }
            if (delivered.compareAndSet(false, true)) {
                watchdog.cancel(false)
                val running = error == null && value != null && value.optString("state") == "running" &&
                    value.optString("operationId") == id &&
                    value.optString("serviceInstance") == ready.instance &&
                    value.optInt("uid", -1) == ready.uid
                complete(
                    if (running) {
                        JSONObject(row.toString()).put("state", "running").put("reason", "reconnected_running")
                    } else {
                        runCatching { journal.get(id, owner) }.getOrNull() ?: row
                    },
                )
            }
        }
    }

    private fun deliverNative(id: String, owner: Protocol.Owner) {
        val callbacks = nativeResults.remove(id) ?: return
        val value = runCatching { journal.get(id, owner, true) }.getOrNull()
            ?: Protocol.error("operation_storage_unavailable")
        callbacks.forEach { it(value) }
    }

    // --------------------------------------------------------------- AI bridge

    fun bridge(requestBody: JSONObject, runtimeId: String, complete: (JSONObject) -> Unit) {
        control.execute {
            try {
                require(requestBody.getInt("protocolVersion") == Protocol.VERSION)
                if (!NativeBridge.isCurrent(runtimeId, requestBody.getString("bridgeInstance"))) {
                    complete(Protocol.error("bridge_instance_changed"))
                    return@execute
                }
                when (requestBody.getString("method")) {
                    "status" -> {
                        refreshNow(bind = true)
                        complete(JSONObject(bridgeJson(currentSnapshot())))
                    }
                    "prepare" -> {
                        val owner = Protocol.owner(requestBody, runtimeId)
                        val command = requestBody.getString("command")
                        val timeout = optionalInt(requestBody, "timeoutMs")
                        Protocol.validateCommand(command, timeout)
                        acquire { ready, why ->
                            if (ready == null) {
                                complete(Protocol.error(why ?: "shizuku_not_ready"))
                                return@acquire
                            }
                            val settings = readPolicy()
                            val decision = CommandPolicy.inspect(command)
                            val admission = CommandPolicy.admission(
                                decision,
                                settings[DIRECT_READ_ONLY] == true,
                                settings[ADVANCED_MODE] == true,
                                settings[ALLOW_DELAY_SECONDS] as Int,
                            )
                            val snapshot = currentSnapshot()
                            complete(
                                JSONObject(bridgeJson(snapshot))
                                    .put("risk", decision.risk.name.lowercase())
                                    .put("operationType", decision.kind)
                                    .put("automatic", admission.automatic)
                                    .put("timeoutMs", timeout ?: (settings[COMMAND_TIMEOUT_SECONDS] as Int) * 1000),
                            )
                        }
                    }
                    "submit" -> {
                        val owner = Protocol.owner(requestBody, runtimeId)
                        val id = requestBody.getString("operationId")
                        val command = requestBody.getString("command")
                        val timeout = optionalInt(requestBody, "timeoutMs")
                        Protocol.validateCommand(command, timeout)
                        require(Protocol.idPattern.matches(id))
                        val expected = lastReady
                        val current = requestBody.getString("brokerInstance") == brokerInstance &&
                            expected != null &&
                            requestBody.getString("serviceInstance") == expected.instance &&
                            requestBody.getInt("uid") == expected.uid
                        val ready = if (current) expected else null
                        complete(admit(id, owner, command, timeout, ready, "instance_changed"))
                    }
                    "lookup" -> {
                        val owner = Protocol.owner(requestBody, runtimeId)
                        val command = requestBody.getString("command")
                        val timeout = optionalInt(requestBody, "timeoutMs")
                        Protocol.validateCommand(command, timeout)
                        val id = requestBody.getString("operationId")
                        require(Protocol.idPattern.matches(id))
                        complete(
                            journal.lookup(id, owner, Protocol.fingerprint(command, timeout))
                                ?: Protocol.error("operation_not_found"),
                        )
                    }
                    "result" -> {
                        val owner = Protocol.owner(requestBody, runtimeId)
                        val id = requestBody.getString("operationId")
                        require(Protocol.idPattern.matches(id))
                        reconcile(id, owner, complete)
                    }
                    "cancel" -> {
                        val owner = Protocol.owner(requestBody, runtimeId)
                        val id = requestBody.getString("operationId")
                        require(Protocol.idPattern.matches(id))
                        cancelOperation(id, owner)
                        complete(
                            runCatching { journal.get(id, owner, true) }.getOrNull()
                                ?: Protocol.error("operation_storage_unavailable"),
                        )
                    }
                    else -> complete(Protocol.error("unknown_method"))
                }
            } catch (error: Exception) {
                val failure = Protocol.error(errorCode(error))
                if (requestBody.optString("method") == "result") failure.put("state", "unknown")
                complete(failure)
            }
        }
    }

    // ------------------------------------------------------------ method calls

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "manager.open", "overlay.open" -> {
                try {
                    val context = requireNotNull(app)
                    val intent = if (call.method == "overlay.open") {
                        Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:${context.packageName}"))
                    } else {
                        context.packageManager.getLaunchIntentForPackage(EnvironmentProbe.MANAGER_PACKAGE)
                            ?: Intent(Intent.ACTION_VIEW, Uri.parse("https://shizuku.rikka.app/download/"))
                    }
                    context.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                    result.success(true)
                } catch (_: Exception) {
                    result.error("settings_unavailable", "Could not open the system settings or the Shizuku manager.", null)
                }
            }
            else -> control.execute {
                try {
                    when (call.method) {
                        "snapshot" -> {
                            refreshNow(bind = true)
                            respond(result, currentSnapshot())
                        }
                        "diagnostics" -> {
                            refreshNow(bind = false)
                            respond(result, currentSnapshot())
                        }
                        "policy.read" -> main.post { result.success(readPolicy()) }
                        "policy.write" -> writePolicy(call, result)
                        "authorization.request" -> {
                            requestAuthorization()
                            main.post { result.success(true) }
                        }
                        "authorization.cancel" -> {
                            request.interrupt("cancelled_by_user")
                            publish()
                            main.post { result.success(true) }
                        }
                        "feature.setEnabled" -> {
                            val requested = call.argument<Boolean>("enabled") == true
                            check(
                                requireNotNull(app).getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
                                    .putBoolean(ENABLED, requested).commit(),
                            )
                            if (!requested) {
                                request.interrupt("feature_disabled")
                                invalidateSession("feature_disabled")
                            }
                            refreshNow(bind = requested)
                            respond(result, currentSnapshot())
                        }
                        "service.connect" -> acquire { ready, why ->
                            if (ready == null) {
                                main.post {
                                    result.error(why ?: "shizuku_not_ready", "The Shizuku UserService is not ready.", null)
                                }
                            } else {
                                main.post { result.success(true) }
                            }
                        }
                        "service.disconnect" -> {
                            invalidateSession("user_disconnected")
                            publish()
                            main.post { result.success(true) }
                        }
                        "command.execute", "command.diagnostic" -> {
                            val id = call.argument<String>("operationId") ?: UUID.randomUUID().toString()
                            val command = if (call.method == "command.diagnostic") {
                                CommandPolicy.DIAGNOSTIC
                            } else {
                                call.argument<String>("command") ?: ""
                            }
                            val timeout = call.argument<Int>("timeoutMs")
                            Protocol.validateCommand(command, timeout)
                            require(Protocol.idPattern.matches(id))
                            val owner = Protocol.settingsOwner()
                            acquire { ready, why ->
                                try {
                                    val initial = admit(id, owner, command, timeout, ready, why ?: "shizuku_not_ready")
                                    if (initial.optString("state") in setOf("queued", "waiting", "running")) {
                                        val callbacks = nativeResults.getOrPut(id) { mutableListOf() }
                                        if (callbacks.size < 4) callbacks.add { row -> respondRow(result, row) }
                                        else main.post {
                                            result.error("operation_waiters_full", "This operation already has waiting callers.", null)
                                        }
                                    } else {
                                        respondRow(result, initial)
                                    }
                                } catch (error: Exception) {
                                    main.post { result.error(errorCode(error), "The command was not admitted.", null) }
                                }
                            }
                        }
                        "command.cancel" -> {
                            val id = call.argument<String>("operationId") ?: ""
                            cancelOperation(id, Protocol.settingsOwner())
                            val row = journal.get(id, Protocol.settingsOwner(), true)
                            main.post { result.success(row?.optString("state") == "cancelled") }
                        }
                        else -> main.post { result.notImplemented() }
                    }
                } catch (error: Exception) {
                    main.post { result.error(errorCode(error), "Shizuku request failed. No fallback was used.", null) }
                }
            }
        }
    }

    private fun respond(result: MethodChannel.Result, snapshot: ShizukuSnapshot) {
        val value = bridgeJson(snapshot)
        main.post { result.success(value) }
    }

    private fun respondRow(result: MethodChannel.Result, row: JSONObject) {
        val value = plain(row)
        main.post { result.success(value) }
    }

    private fun readPolicy(): Map<String, Any> {
        val prefs = requireNotNull(app).getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        return mapOf(
            DIRECT_READ_ONLY to prefs.getBoolean(DIRECT_READ_ONLY, true),
            ADVANCED_MODE to prefs.getBoolean(ADVANCED_MODE, false),
            ALLOW_DELAY_SECONDS to prefs.getInt(ALLOW_DELAY_SECONDS, 10).coerceIn(0, 60),
            OVERLAY_TIMEOUT_SECONDS to prefs.getInt(OVERLAY_TIMEOUT_SECONDS, 30).coerceIn(10, 120),
            COMMAND_TIMEOUT_SECONDS to prefs.getInt(COMMAND_TIMEOUT_SECONDS, 30).coerceIn(1, 120),
            MAX_OUTPUT_KIB to prefs.getInt(MAX_OUTPUT_KIB, 64).coerceIn(4, 256),
        )
    }

    private fun writePolicy(call: MethodCall, result: MethodChannel.Result) {
        val direct = call.argument<Boolean>(DIRECT_READ_ONLY)
        val advanced = call.argument<Boolean>(ADVANCED_MODE)
        val delay = call.argument<Int>(ALLOW_DELAY_SECONDS)
        val overlay = call.argument<Int>(OVERLAY_TIMEOUT_SECONDS)
        val timeout = call.argument<Int>(COMMAND_TIMEOUT_SECONDS)
        val output = call.argument<Int>(MAX_OUTPUT_KIB)
        require(
            direct != null && advanced != null && delay != null && delay in 0..60 &&
                overlay != null && overlay in 10..120 && timeout != null && timeout in 1..120 &&
                output != null && output in 4..256 && overlay > delay,
        ) { "invalid_policy" }
        check(
            requireNotNull(app).getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
                .putBoolean(DIRECT_READ_ONLY, direct).putBoolean(ADVANCED_MODE, advanced)
                .putInt(ALLOW_DELAY_SECONDS, delay).putInt(OVERLAY_TIMEOUT_SECONDS, overlay)
                .putInt(COMMAND_TIMEOUT_SECONDS, timeout).putInt(MAX_OUTPUT_KIB, output).commit(),
        )
        main.post { result.success(readPolicy()) }
    }

    private fun optionalInt(value: JSONObject, key: String): Int? {
        if (!value.has(key) || value.isNull(key)) return null
        val raw = value.get(key)
        require(raw is Number && raw.toDouble() == raw.toInt().toDouble())
        return raw.toInt()
    }

    private fun errorCode(error: Exception): String = error.message?.takeIf {
        it in setOf(
            "operation_conflict", "operation_history_full", "operation_storage_unavailable",
            "invalid_policy", "shizuku_not_running", "permission_request_failed",
            "request_already_pending", "request_too_soon", "too_many_attempts",
            "app_not_listed", "provider_misconfigured", "shizuku_not_ready", "busy",
        )
    } ?: "invalid_request"

    private const val SOURCE_TOOL = "opencode_tool"
}
