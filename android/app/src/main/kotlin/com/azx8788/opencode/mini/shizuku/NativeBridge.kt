package com.azx8788.opencode.mini.shizuku

import android.content.Context
import android.net.LocalServerSocket
import android.net.LocalSocket
import android.net.LocalSocketAddress
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.system.Os
import android.system.OsConstants
import org.json.JSONObject
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.File
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.Semaphore
import java.util.concurrent.atomic.AtomicBoolean

/** Private filesystem socket shared with the app's Ubuntu. No LAN listener or model-visible credential. */
internal object NativeBridge {
    const val GUEST_SOCKET = "/tmp/.oc-shizuku/s"
    const val GUEST_DESCRIPTOR = "/root/.oc-builtin/shizuku-bridge.json"
    @Volatile var available = false
        private set
    @Volatile var reason: String? = null
        private set
    private var endpoint: Endpoint? = null
    @Volatile private var liveRuntime: String? = null
    @Volatile private var liveInstance: String? = null
    fun isCurrent(runtimeId: String, instance: String) = available && runtimeId == liveRuntime && instance == liveInstance

    @Synchronized fun start(context: Context, rootfs: File) {
        if (endpoint != null) return
        ShizukuRuntime.initialize(context)
        try {
            val canonical = File(context.filesDir.canonicalFile, "linux/ubuntu")
            check(rootfs.canonicalFile == canonical)
            val config = File(canonical, "root/.oc-builtin")
            privateDirectory(config)
            val runtimeFile = File(config, "shizuku-runtime-id")
            val runtimeId = if (runtimeFile.exists()) {
                safeFile(runtimeFile, 80)
                runtimeFile.readText().trim().also { check(it.matches(Regex("[a-f0-9-]{36}"))) }
            } else UUID.randomUUID().toString().also { OperationJournal.atomicFile(runtimeFile, "$it\n") }
            val socketDir = File(canonical, "tmp/.oc-shizuku")
            val marker = File(socketDir, "opencode-plus-owned")
            if (socketDir.exists()) {
                check(socketDir.canonicalFile == socketDir.absoluteFile)
                safeFile(marker, 80)
                check(marker.readText() == "shizuku-bridge-v1\n")
            }
            privateDirectory(socketDir)
            if (!marker.exists()) OperationJournal.atomicFile(marker, "shizuku-bridge-v1\n")
            val file = File(socketDir, "s")
            check(file.path.toByteArray(Charsets.UTF_8).size < 108)
            // The main app is the only socket owner. A cold start may leave its old filesystem inode.
            if (file.exists()) {
                val info = Os.lstat(file.path)
                check(OsConstants.S_ISSOCK(info.st_mode) && info.st_uid == Process.myUid())
                check(file.delete())
            }
            val value = Endpoint(file, File(config, "shizuku-bridge.json"), runtimeId)
            try { value.start(); endpoint = value; liveRuntime = runtimeId; liveInstance = value.instance; available = true; reason = null }
            catch (error: Exception) { value.close(); throw error }
        } catch (_: Exception) {
            available = false
            reason = "android_bridge_unavailable" // No paths, commands or credentials in diagnostics.
        }
        ShizukuRuntime.refresh()
    }

    @Synchronized fun stop() {
        available = false
        liveRuntime = null
        liveInstance = null
        endpoint?.close()
        endpoint = null
        reason = null
        ShizukuRuntime.stopRuntime()
    }

    private fun privateDirectory(file: File) {
        if (!file.exists()) check(file.mkdirs())
        check(file.canonicalFile == file.absoluteFile)
        val info = Os.lstat(file.path)
        check(OsConstants.S_ISDIR(info.st_mode) && info.st_uid == Process.myUid())
        Os.chmod(file.path, 0x1c0)
    }
    private fun safeFile(file: File, max: Int) {
        val info = Os.lstat(file.path)
        check(OsConstants.S_ISREG(info.st_mode) && info.st_uid == Process.myUid() && info.st_nlink == 1L && info.st_size in 1..max.toLong())
        check(info.st_mode and 0x3f == 0)
    }

    private class Endpoint(private val file: File, private val descriptor: File, private val runtimeId: String) {
        private val listener = LocalSocket()
        private var server: LocalServerSocket? = null
        private val workers = Executors.newFixedThreadPool(2) { task -> Thread(task, "shizuku-bridge").apply { isDaemon = true } }
        private val clients = ConcurrentHashMap.newKeySet<LocalSocket>()
        private val permits = Semaphore(4)
        private val main = Handler(Looper.getMainLooper())
        val instance = UUID.randomUUID().toString()
        @Volatile private var active = false
        private var bound = false

        fun start() {
            if (descriptor.exists()) {
                safeFile(descriptor, 1024)
                val prior = JSONObject(descriptor.readText())
                check(prior.getInt("protocolVersion") == 1 && prior.getString("runtimeId") == runtimeId && prior.getString("socketPath") == GUEST_SOCKET)
            }
            listener.bind(LocalSocketAddress(file.path, LocalSocketAddress.Namespace.FILESYSTEM))
            bound = true
            Os.chmod(file.path, 0x180)
            server = LocalServerSocket(listener.fileDescriptor)
            OperationJournal.atomicFile(descriptor, JSONObject().put("protocolVersion", Protocol.VERSION)
                .put("socketPath", GUEST_SOCKET).put("runtimeId", runtimeId).put("bridgeInstance", instance).toString())
            active = true
            Thread({
                while (active) {
                    val client = try { server!!.accept() } catch (_: Exception) { break }
                    if (!permits.tryAcquire()) { client.close(); continue }
                    clients.add(client)
                    try { workers.execute { serve(client) } }
                    catch (_: Exception) { release(client) }
                }
            }, "shizuku-accept").apply { isDaemon = true; start() }
        }

        private fun serve(client: LocalSocket) {
            val done = AtomicBoolean(false)
            val timeout = Runnable { done.set(true); release(client) }
            main.postDelayed(timeout, 15_000)
            fun reply(value: JSONObject) {
                if (!done.compareAndSet(false, true)) return
                try { workers.execute {
                    try {
                        value.put("runtimeId", runtimeId).put("bridgeInstance", instance)
                        val bytes = value.toString().toByteArray(Charsets.UTF_8)
                        check(bytes.size <= Protocol.MAX_RESPONSE_BYTES)
                        DataOutputStream(client.outputStream).apply { writeInt(bytes.size); write(bytes); flush() }
                    } catch (_: Exception) { /* A lost reply is reconciled by operation ID, never resubmitted. */ }
                    finally { main.removeCallbacks(timeout); release(client) }
                } } catch (_: Exception) { main.removeCallbacks(timeout); release(client) }
            }
            try {
                check(client.peerCredentials.uid == Process.myUid())
                client.soTimeout = 5000
                val input = DataInputStream(client.inputStream)
                val size = input.readInt()
                check(size in 1..Protocol.MAX_REQUEST_BYTES)
                val bytes = ByteArray(size).also { input.readFully(it) }
                val text = Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(bytes)).toString()
                val request = JSONObject(text)
                if (!active || request.getString("bridgeInstance") != instance) { reply(Protocol.error("bridge_instance_changed")); return }
                ShizukuRuntime.bridge(request, runtimeId, ::reply)
            } catch (_: Exception) {
                reply(Protocol.error("invalid_bridge_request"))
            }
        }
        private fun release(client: LocalSocket) {
            if (!clients.remove(client)) return
            runCatching { client.close() }
            permits.release()
        }
        fun close() {
            active = false
            runCatching { server?.close() }; runCatching { listener.close() }
            clients.toList().forEach(::release)
            workers.shutdownNow()
            if (bound) runCatching { file.delete() }
            runCatching {
                safeFile(descriptor, 1024)
                if (JSONObject(descriptor.readText()).getString("bridgeInstance") == instance) descriptor.delete()
            }
        }
    }
}
