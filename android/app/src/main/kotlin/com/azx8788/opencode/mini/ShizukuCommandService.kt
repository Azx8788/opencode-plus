package com.azx8788.opencode.mini

import android.os.SystemClock
import android.system.Os
import android.system.OsConstants
import org.json.JSONObject
import java.io.IOException
import java.io.File
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlin.concurrent.thread

/** Bounded UserService execution. Android has no supported Process.pid() API. */
class ShizukuCommandService : IShizukuCommandService.Stub() {
    private class Running(val process: Process, val startedAt: Long, val grouped: Boolean) {
        val pid = AtomicInteger(0)
        var cancelRequested = false
        var terminationConfirmed = false
        var finished = false
    }

    private val active = ConcurrentHashMap<String, Running>()
    private val gate = ShizukuServiceGate()
    private val launchLock = Any()
    private val completed = linkedMapOf<String, String>()

    override fun status(): String = JSONObject()
        .put("protocolVersion", ShizukuProtocol.VERSION)
        .put("serviceVersion", ShizukuProtocol.SERVICE_VERSION)
        .put("uid", Os.getuid())
        .put("backend", when (Os.getuid()) { 0 -> "root"; 2000 -> "adb"; else -> "unknown" })
        .put("serviceInstance", instance)
        .toString()

    override fun execute(operationId: String, expectedInstance: String, expectedUid: Int,
                         command: String, timeoutMs: Int, outputLimitBytes: Int): String {
        require(operationId.matches(Regex("[A-Za-z0-9_-]{1,80}")))
        check(expectedInstance == instance && expectedUid == Os.getuid() && expectedUid in setOf(0, 2000)) { "identity_changed" }
        require(command.isNotBlank() && '\u0000' !in command && command.toByteArray(Charsets.UTF_8).size <= MAX_COMMAND_BYTES)
        require(timeoutMs in 1_000..120_000)
        require(outputLimitBytes in 1_024..MAX_OUTPUT_BYTES)
        val rejected = gate.claim(operationId)
        if (rejected != null) return noExecution(operationId, rejected)

        var running: Running? = null
        try {
            // Only this wrapper emits the first stderr line. The command is a
            // positional argument, never interpolated into the wrapper script.
            val wrapper = "printf 'OCRPID=%s\\n' \"\$\$\" >&2; exec /system/bin/sh -c \"\$1\""
            fun launch(argv: List<String>): Process = ProcessBuilder(argv).apply {
                directory(File("/")) // Android's filesystem, never an Ubuntu project directory.
                environment()["PATH"] = "/system/bin:/system/xbin:/vendor/bin"
            }.start()
            val process: Process
            synchronized(launchLock) {
                if (gate.cancelled(operationId)) return noExecution(operationId, "cancelled_before_start")
                // Never fall back to a shell without a process group: timeout/cancel
                // could kill only the shell while leaving command descendants running.
                process = launch(listOf("/system/bin/setsid", "/system/bin/sh", "-c", wrapper, "oc-shizuku", command))
                val owner = Running(process, SystemClock.elapsedRealtime(), grouped = true)
                running = owner
                active[operationId] = owner
            }
            val owner = checkNotNull(running)
            val startedAt = System.currentTimeMillis()
            process.outputStream.close() // stdin is not an interactive terminal
            val output = ShizukuCommandOutput(outputLimitBytes)
            val outThread = thread(isDaemon = true, name = "shizuku-stdout") {
                try { output.drainStdout(process.inputStream) } catch (_: IOException) { output.markIncomplete() }
            }
            val errThread = thread(isDaemon = true, name = "shizuku-stderr") {
                try { output.drainStderr(process.errorStream) { owner.pid.set(it) } }
                catch (_: IOException) { output.markIncomplete() }
            }
            var timedOut = false
            try {
                if (!process.waitFor(timeoutMs.toLong(), TimeUnit.MILLISECONDS)) {
                    timedOut = true
                    synchronized(owner) { owner.terminationConfirmed = terminate(owner) }
                }
            } catch (_: InterruptedException) {
                synchronized(owner) {
                    owner.cancelRequested = true
                    owner.terminationConfirmed = terminate(owner)
                }
                Thread.currentThread().interrupt()
            }
            runCatching { outThread.join(500); errThread.join(500) }
            if (outThread.isAlive || errThread.isAlive) output.markIncomplete()
            return synchronized(owner) {
                owner.finished = true
                val exit = if (process.isAlive) null else process.exitValue()
                val state: String
                val reason: String?
                when {
                    owner.cancelRequested -> {
                        state = if (owner.terminationConfirmed) "cancelled" else "unknown"
                        reason = if (owner.terminationConfirmed) "cancelled" else "cancel_unconfirmed"
                    }
                    timedOut -> {
                        state = if (owner.terminationConfirmed) "failed" else "unknown"
                        reason = if (owner.terminationConfirmed) "timeout" else "timeout_unconfirmed"
                    }
                    exit == null -> { state = "unknown"; reason = "exit_unconfirmed" }
                    else -> { state = if (exit == 0) "succeeded" else "failed"; reason = if (exit == 0) null else "nonzero_exit" }
                }
                val termination = if (!owner.cancelRequested && !timedOut) "not_requested"
                    else if (owner.terminationConfirmed) "confirmed" else "unconfirmed"
                val value = result(operationId, state, reason, exit, output.snapshot(), owner.startedAt, startedAt, termination)
                synchronized(completed) {
                    completed[operationId] = value
                    while (completed.size > 16) completed.remove(completed.keys.first())
                }
                value
            }
        } catch (_: IOException) {
            val owner = running
            if (owner == null) return noExecution(operationId, "process_start_failed")
            synchronized(owner) { owner.terminationConfirmed = terminate(owner) }
            return result(operationId, "unknown", "process_io_failed", null,
                ShizukuCommandOutput.Snapshot("", "", true), owner.startedAt, null,
                if (owner.terminationConfirmed) "confirmed" else "unconfirmed")
        } finally {
            running?.let { owner ->
                active.remove(operationId, owner)
                runCatching { owner.process.inputStream.close() }
                runCatching { owner.process.errorStream.close() }
            }
            gate.finish(operationId)
        }
    }

    override fun cancel(operationId: String): Boolean {
        require(ShizukuProtocol.idPattern.matches(operationId))
        val owner: Running?
        synchronized(launchLock) {
            if (!gate.cancel(operationId)) return false
            owner = active[operationId]
        }
        if (owner == null) return synchronized(completed) { !completed.containsKey(operationId) }
        return synchronized(owner) {
            if (owner.finished) return@synchronized false
            owner.cancelRequested = true
            owner.terminationConfirmed = terminate(owner)
            owner.terminationConfirmed
        }
    }

    override fun destroy() {
        synchronized(launchLock) { gate.stop() }
        active.keys.toList().forEach { cancel(it) }
        System.exit(0)
    }

    override fun result(operationId: String): String {
        require(ShizukuProtocol.idPattern.matches(operationId))
        synchronized(completed) { completed[operationId]?.let { return it } }
        return JSONObject().put("operationId", operationId).put("serviceInstance", instance).put("uid", Os.getuid())
            .put("state", if (active.containsKey(operationId)) "running" else "unknown").toString()
    }

    private fun noExecution(id: String, reason: String): String = result(id,
        if (reason == "cancelled_before_start") "cancelled" else "failed", reason, null,
        ShizukuCommandOutput.Snapshot("", "", false), null, null,
        if (reason == "cancelled_before_start") "confirmed" else "not_requested")

    /** ESRCH alone proves absence; permission/other errors are not success. */
    private fun groupExists(group: Int): Boolean = try {
        Os.kill(group, 0)
        true
    } catch (error: android.system.ErrnoException) {
        error.errno != OsConstants.ESRCH
    }

    private fun terminate(owner: Running): Boolean {
        val process = owner.process
        if (owner.grouped) {
            val deadline = SystemClock.elapsedRealtime() + 500
            while (owner.pid.get() <= 1 && SystemClock.elapsedRealtime() < deadline) {
                try { Thread.sleep(20) } catch (_: InterruptedException) {
                    Thread.currentThread().interrupt()
                    break
                }
            }
            val pid = owner.pid.get()
            if (pid > 1) {
                val group = -pid
                runCatching { Os.kill(group, OsConstants.SIGTERM) }
                runCatching { process.waitFor(300, TimeUnit.MILLISECONDS) }
                if (groupExists(group)) runCatching { Os.kill(group, OsConstants.SIGKILL) }
                runCatching { process.waitFor(300, TimeUnit.MILLISECONDS) }
                if (!process.isAlive && !groupExists(group)) return true
            }
        }
        runCatching { process.destroy() }
        runCatching { process.waitFor(300, TimeUnit.MILLISECONDS) }
        if (process.isAlive) runCatching { process.destroyForcibly() }
        return false // no verified group, or descendants still unconfirmed
    }

    private fun result(id: String, state: String, reason: String?, exit: Int?,
                       output: ShizukuCommandOutput.Snapshot, started: Long?, startedAt: Long?, termination: String): String {
        val value = JSONObject().put("protocolVersion", ShizukuProtocol.VERSION).put("uid", Os.getuid())
            .put("operationId", id).put("state", state).put("reason", reason ?: JSONObject.NULL)
            .put("exitCode", exit ?: JSONObject.NULL).put("stdout", output.stdout).put("stderr", output.stderr)
            .put("truncated", output.truncated).put("termination", termination)
            .put("startedAt", startedAt ?: JSONObject.NULL)
            .put("elapsedMs", started?.let { SystemClock.elapsedRealtime() - it } ?: JSONObject.NULL)
            .put("serviceInstance", instance)
        // Binder strings use UTF-16, and JSON escapes can multiply binary output.
        // The configured byte cap is an upper limit, not permission to exceed Binder's frame budget.
        var text = value.toString()
        while (text.length > 180_000 || text.toByteArray(Charsets.UTF_8).size > 500_000) {
            for (key in listOf("stdout", "stderr")) value.put(key, value.getString(key).take(value.getString(key).length / 2))
            value.put("truncated", true)
            text = value.toString()
        }
        return text
    }

    companion object {
        private const val MAX_COMMAND_BYTES = 16 * 1024
        private const val MAX_OUTPUT_BYTES = 256 * 1024
        private val instance = java.util.UUID.randomUUID().toString()
    }
}
