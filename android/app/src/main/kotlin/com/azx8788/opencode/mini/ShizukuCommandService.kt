package com.azx8788.opencode.mini

import android.os.SystemClock
import android.system.Os
import android.system.OsConstants
import org.json.JSONObject
import java.io.IOException
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Semaphore
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
    private val executionSlot = Semaphore(1)

    override fun status(): String = JSONObject()
        .put("uid", Os.getuid())
        .put("backend", when (Os.getuid()) { 0 -> "root"; 2000 -> "adb"; else -> "unknown" })
        .put("serviceInstance", instance)
        .toString()

    override fun execute(operationId: String, command: String, timeoutMs: Int, outputLimitBytes: Int): String {
        require(operationId.matches(Regex("[A-Za-z0-9_-]{1,80}")))
        require(command.isNotBlank() && '\u0000' !in command && command.toByteArray(Charsets.UTF_8).size <= MAX_COMMAND_BYTES)
        require(timeoutMs in 1_000..120_000)
        require(outputLimitBytes in 1_024..MAX_OUTPUT_BYTES)
        check(executionSlot.tryAcquire()) { "busy" }

        var running: Running? = null
        try {
            // Only this wrapper emits the first stderr line. The command is a
            // positional argument, never interpolated into the wrapper script.
            val wrapper = "printf 'OCRPID=%s\\n' \"\$\$\" >&2; exec /system/bin/sh -c \"\$1\""
            var grouped = true
            val process = try {
                ProcessBuilder("/system/bin/setsid", "/system/bin/sh", "-c", wrapper, "oc-shizuku", command).start()
            } catch (_: IOException) {
                grouped = false
                ProcessBuilder("/system/bin/sh", "-c", wrapper, "oc-shizuku", command).start()
            }
            val owner = Running(process, SystemClock.elapsedRealtime(), grouped)
            running = owner
            check(active.putIfAbsent(operationId, owner) == null) { "duplicate_operation" }
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
                result(operationId, state, reason, exit, output.snapshot(), owner.startedAt)
            }
        } finally {
            running?.let { owner ->
                active.remove(operationId, owner)
                runCatching { owner.process.inputStream.close() }
                runCatching { owner.process.errorStream.close() }
            }
            executionSlot.release()
        }
    }

    override fun cancel(operationId: String): Boolean {
        val owner = active[operationId] ?: return false
        return synchronized(owner) {
            if (owner.finished) return@synchronized false
            owner.cancelRequested = true
            owner.terminationConfirmed = terminate(owner)
            owner.terminationConfirmed
        }
    }

    override fun destroy() {
        active.keys.toList().forEach { cancel(it) }
        System.exit(0)
    }

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
                       output: ShizukuCommandOutput.Snapshot, started: Long): String = JSONObject()
        .put("operationId", id).put("state", state).put("reason", reason ?: JSONObject.NULL)
        .put("exitCode", exit ?: JSONObject.NULL).put("stdout", output.stdout)
        .put("stderr", output.stderr).put("truncated", output.truncated)
        .put("elapsedMs", SystemClock.elapsedRealtime() - started).put("serviceInstance", instance).toString()

    companion object {
        private const val MAX_COMMAND_BYTES = 16 * 1024
        private const val MAX_OUTPUT_BYTES = 256 * 1024
        private val instance = java.util.UUID.randomUUID().toString()
    }
}
