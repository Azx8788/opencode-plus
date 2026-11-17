package com.azx8788.opencode.mini

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.content.ServiceConnection
import android.content.pm.PackageManager
import android.os.IBinder
import android.os.Looper
import android.os.Handler
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import rikka.shizuku.Shizuku
import rikka.sui.Sui
import java.util.concurrent.atomic.AtomicBoolean

/** App-owned Shizuku state and UserService binding; Flutter screens are only observers. */
internal object ShizukuController {
    private const val CHANNEL = "oc/shizuku"
    private const val REQUEST_CODE = 7412
    private const val PREFS = "shizuku_settings"
    private const val ENABLED = "enabled"
    private const val SERVICE_VERSION = 1
    private val main = Handler(Looper.getMainLooper())
    private var app: Context? = null
    private var sink: EventChannel.EventSink? = null
    private var binder: IShizukuCommandService? = null
    private var permissionResult: Int? = null
    private var userServiceBound = false
    private val initialized = AtomicBoolean(false)

    private val received = Shizuku.OnBinderReceivedListener { refresh() }
    private val died = Shizuku.OnBinderDeadListener {
        binder = null
        userServiceBound = false
        emit()
    }
    private val permissionListener = Shizuku.OnRequestPermissionResultListener { code, result ->
        if (code == REQUEST_CODE) {
            permissionResult = result
            refresh()
        }
    }
    private val serviceArgs by lazy {
        Shizuku.UserServiceArgs(ComponentName(requireNotNull(app), ShizukuCommandService::class.java))
            .daemon(false).version(SERVICE_VERSION)
            .tag("${requireNotNull(app).packageName}-${android.os.Process.myUid() / 100000}-shizuku")
            .processNameSuffix("shizuku")
    }
    private val connection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, service: IBinder?) {
            binder = IShizukuCommandService.Stub.asInterface(service)
            userServiceBound = binder != null
            emit()
        }
        override fun onServiceDisconnected(name: ComponentName?) {
            binder = null
            userServiceBound = false
            emit()
        }
    }

    fun initialize(context: Context) {
        app = context.applicationContext
        if (initialized.compareAndSet(false, true)) {
            Shizuku.addBinderReceivedListenerSticky(received)
            Shizuku.addBinderDeadListener(died)
            Shizuku.addRequestPermissionResultListener(permissionListener)
        }
    }

    fun register(context: Context, messenger: BinaryMessenger) {
        initialize(context)
        MethodChannel(messenger, CHANNEL).setMethodCallHandler(::handle)
        EventChannel(messenger, "$CHANNEL/events").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                sink = events
                emit()
            }
            override fun onCancel(arguments: Any?) { sink = null }
        })
        refresh()
    }

    fun detach() { sink = null }

    fun refresh() {
        val context = app ?: return
        val alive = runCatching { Shizuku.pingBinder() }.getOrDefault(false)
        val granted = alive && runCatching {
            Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED
        }.getOrDefault(false)
        val remoteUid = if (granted) runCatching { Shizuku.getUid() }.getOrNull() else null
        val supportedUid = remoteUid == 0 || remoteUid == 2000
        val enabled = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean(ENABLED, false)
        if (alive && granted && supportedUid && enabled && binder == null && !userServiceBound) bind()
        if ((!alive || !granted || !supportedUid || !enabled) && userServiceBound) unbind(remove = true)
        emit()
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "status" -> { refresh(); result.success(snapshot()) }
            "overlaySettings" -> {
                try {
                    app!!.startActivity(Intent(android.provider.Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                        Uri.parse("package:${app!!.packageName}")).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                    result.success(true)
                } catch (_: Exception) { result.error("overlay_settings_unavailable", "Could not open overlay settings.", null) }
            }
            "openManager" -> {
                val context = app!!
                val launch = context.packageManager.getLaunchIntentForPackage("moe.shizuku.privileged.api")
                try {
                    val intent = launch ?: Intent(Intent.ACTION_VIEW, Uri.parse("https://shizuku.rikka.app/download/"))
                    intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    context.startActivity(intent)
                    result.success(true)
                } catch (_: Throwable) {
                    result.error("manager_unavailable", "Could not open Shizuku manager or download page.", null)
                }
            }
            "requestPermission" -> {
                if (!runCatching { Shizuku.pingBinder() }.getOrDefault(false)) {
                    result.error("shizuku_unavailable", "Shizuku service is not running.", null)
                } else {
                    permissionResult = null
                    runCatching { Shizuku.requestPermission(REQUEST_CODE) }
                        .onSuccess { result.success(true) }
                        .onFailure { result.error("permission_request_failed", "Could not request Shizuku permission.", null) }
                }
            }
            "setEnabled" -> {
                val enabled = call.argument<Boolean>("enabled") ?: false
                app!!.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putBoolean(ENABLED, enabled).apply()
                refresh()
                result.success(snapshot())
            }
            "startService" -> {
                if (!ready()) result.error("shizuku_not_ready", "Enable Shizuku and grant permission first.", null)
                else { bind(); result.success(true) }
            }
            "diagnostic" -> executeDiagnostic(call, result)
            "execute" -> execute(call, result)
            "cancel" -> {
                val id = call.argument<String>("operationId")
                result.success(runCatching { id != null && binder?.cancel(id) == true }.getOrDefault(false))
            }
            else -> result.notImplemented()
        }
    }

    private fun executeDiagnostic(call: MethodCall, result: MethodChannel.Result) {
        val id = call.argument<String>("operationId")
        if (id.isNullOrBlank() || id.length > 80) {
            result.error("invalid_request", "Invalid operation ID.", null)
            return
        }
        executeCommand(id, "id; getprop ro.build.version.release", 10_000, 16_384, result)
    }

    private fun execute(call: MethodCall, result: MethodChannel.Result) {
        val command = call.argument<String>("command")
        val id = call.argument<String>("operationId") ?: java.util.UUID.randomUUID().toString()
        val timeout = call.argument<Int>("timeoutMs") ?: 30_000
        if (command.isNullOrBlank() || command.toByteArray().size > 16 * 1024 || timeout !in 1_000..120_000) {
            result.error("invalid_request", "Invalid command or timeout.", null)
            return
        }
        executeCommand(id, command, timeout, 64 * 1024, result)
    }

    private fun executeCommand(id: String, command: String, timeout: Int, limit: Int, result: MethodChannel.Result) {
        if (!ready() || binder == null) {
            result.error("shizuku_not_ready", "Shizuku UserService is not connected.", null)
            return
        }
        if (!android.provider.Settings.canDrawOverlays(app)) {
            result.error("overlay_permission_missing",
                "Safety overlay permission is required. Grant it in system settings, then retry.", null)
            return
        }
        val expectedService = binder
        val decision = ShizukuCommandPolicy.inspect(command)
        // Every command — read, write, destructive — goes through the overlay.
        // The person sees the full command text, risk colour and countdown,
        // then decides. No silent allow, no silent block.
        ShizukuSafetyOverlay.confirm(app!!, command, decision) { allowed ->
            if (!allowed) {
                result.error("shizuku_denied",
                    "Command was not executed: denied or timed out.", null)
            } else if (!ready() || binder !== expectedService) {
                result.error("shizuku_instance_changed",
                    "Shizuku state changed during confirmation. Command was not executed.", null)
            } else Thread {
                val response = runCatching { expectedService!!.execute(id, command, timeout, limit) }
                main.post {
                    response.onSuccess { result.success(jsonMap(it)) }
                        .onFailure { result.error("shizuku_execution_failed",
                            "Shizuku command failed or the service disconnected.", null) }
                }
            }.start()
        }
    }

    private fun bind() {
        if (userServiceBound || !ready()) return
        try {
            Shizuku.bindUserService(serviceArgs, connection)
            userServiceBound = true
        } catch (_: Throwable) {
            userServiceBound = false
        }
    }

    private fun unbind(remove: Boolean) {
        if (userServiceBound && runCatching { Shizuku.pingBinder() }.getOrDefault(false)) {
            runCatching { Shizuku.unbindUserService(serviceArgs, connection, remove) }
        }
        binder = null
        userServiceBound = false
    }

    private fun ready(): Boolean = runCatching {
        Shizuku.pingBinder() && Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED &&
            (Shizuku.getUid() == 0 || Shizuku.getUid() == 2000)
    }.getOrDefault(false) && app?.getSharedPreferences(PREFS, Context.MODE_PRIVATE)?.getBoolean(ENABLED, false) == true

    private fun snapshot(): Map<String, Any?> {
        val context = app ?: return emptyMap()
        val alive = runCatching { Shizuku.pingBinder() }.getOrDefault(false)
        val granted = alive && runCatching { Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED }.getOrDefault(false)
        val uid = if (granted) runCatching { Shizuku.getUid() }.getOrNull() else null
        val manager = runCatching { context.packageManager.getPackageInfo("moe.shizuku.privileged.api", 0) }.isSuccess
        return mapOf(
            "managerInstalled" to manager, "binderAlive" to alive,
            "overlayAllowed" to android.provider.Settings.canDrawOverlays(context),
            "overlayNeedsSettings" to true,
            // Provider initializes Sui automatically. Never infer Sui from UID 0:
            // Shizuku itself can also be launched with root.
            "provider" to if (!alive) "unknown" else if (Sui.isSui()) "sui" else "shizuku",
            "permission" to when { !alive -> "unknown"; granted -> "granted"; !runCatching { permissionResult == PackageManager.PERMISSION_DENIED }.getOrDefault(false) -> "requestable"; else -> "denied" },
            "enabled" to context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean(ENABLED, false),
            "binding" to if (binder != null) "connected" else if (userServiceBound) "connecting" else "disconnected",
            "uid" to uid, "backend" to when (uid) { 0 -> "root"; 2000 -> "adb"; null -> "unknown"; else -> "unsupported" },
            "serverVersion" to if (alive) runCatching { Shizuku.getVersion() }.getOrNull() else null,
            "selinuxContext" to if (granted) runCatching { Shizuku.getSELinuxContext() }.getOrNull() else null,
            "permissionResult" to permissionResult,
        )
    }

    private fun emit() { main.post { sink?.success(snapshot()) } }

    private fun jsonMap(raw: String): Map<String, Any?> {
        val json = JSONObject(raw)
        return json.keys().asSequence().associateWith { key ->
            if (json.isNull(key)) null else json.get(key)
        }
    }
}
