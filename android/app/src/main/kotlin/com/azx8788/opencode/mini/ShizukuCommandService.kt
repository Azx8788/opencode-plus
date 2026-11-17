package com.azx8788.opencode.mini

import android.os.SystemClock
import android.system.Os
import android.system.OsConstants
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Semaphore
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread

/** Executes bounded commands in the Shizuku UserService identity. */
class ShizukuCommandService : IShizukuCommandService.Stub() {
    private data class Running(val process: Process, val startedAt: Long, val grouped: Boolean)
    private val active = ConcurrentHashMap<String, Running>()
    private val executionSlot = Semaphore(1)

    override fun status(): String = JSONObject()
        .put("uid", Os.getuid())
        .put("backend", when (Os.getuid()) { 0 -> "root"; 2000 -> "adb"; else -> "unknown" })
        .put("serviceInstance", instance)
        .toString()

    override fun execute(operationId: String, command: String, timeoutMs: Int, outputLimitBytes: Int): String {
        require(operationId.matches(Regex("[A-Za-z0-9_-]{1,80}")))
        require(command.isNotBlank() && command.toByteArray(Charsets.UTF_8).size <= MAX_COMMAND_BYTES)
        require(timeoutMs in 1_000..120_000)
        require(outputLimitBytes in 1_024..MAX_OUTPUT_BYTES)
        check(executionSlot.tryAcquire()) { "busy" }

        var grouped = true
        val process = try {
            ProcessBuilder("setsid", "sh", "-c", command).start()
        } catch (_: Throwable) {
            // setsid is part of Android's toybox, but if a platform lacks it we
            // still run the command; cancellation is then reported unconfirmed.
            grouped = false
            try { ProcessBuilder("sh", "-c", command).start() }
            catch (error: Throwable) { executionSlot.release(); throw error }
        }
        val running = Running(process, SystemClock.elapsedRealtime(), grouped)
        if (active.putIfAbsent(operationId, running) != null) {
            executionSlot.release()
            terminate(process, grouped)
            error("duplicate_operation")
        }
        val stdout = ByteArrayOutputStream()
        val stderr = ByteArrayOutputStream()
        var truncated = false
        val outThread = drain(process.inputStream, stdout, outputLimitBytes / 2) { truncated = true }
        val errThread = drain(process.errorStream, stderr, outputLimitBytes - outputLimitBytes / 2) { truncated = true }
        try {
            val finished = process.waitFor(timeoutMs.toLong(), TimeUnit.MILLISECONDS)
            if (!finished) {
                val stopped = terminate(process, running.grouped)
                return result(operationId, if (stopped) "failed" else "unknown",
                    if (stopped) "timeout" else "timeout_unconfirmed", null, stdout, stderr, truncated, running.startedAt)
            }
            outThread.join(1_000)
            errThread.join(1_000)
            val exit = process.exitValue()
            return result(operationId, if (exit == 0) "succeeded" else "failed",
                if (exit == 0) null else "nonzero_exit", exit, stdout, stderr, truncated, running.startedAt)
        } catch (_: InterruptedException) {
            val stopped = terminate(process, running.grouped)
            Thread.currentThread().interrupt()
            return result(operationId, if (stopped) "cancelled" else "unknown",
                if (stopped) "cancelled" else "binder_call_interrupted", null, stdout, stderr, truncated, running.startedAt)
        } finally {
            active.remove(operationId, running)
            executionSlot.release()
            runCatching { process.inputStream.close() }
            runCatching { process.errorStream.close() }
        }
    }

    override fun cancel(operationId: String): Boolean {
        val running = active[operationId] ?: return false
        return terminate(running.process, running.grouped)
    }

    override fun destroy() {
        active.values.forEach { terminate(it.process, it.grouped) }
        active.clear()
        System.exit(0)
    }

    private fun drain(input: java.io.InputStream, output: ByteArrayOutputStream, limit: Int, hitLimit: () -> Unit) =
        thread(isDaemon = true) {
            val buffer = ByteArray(4096)
            while (true) {
                val count = runCatching { input.read(buffer) }.getOrDefault(-1)
                if (count <= 0) break
                val remaining = limit - output.size()
                if (remaining > 0) output.write(buffer, 0, minOf(count, remaining))
                if (count > remaining) hitLimit()
            }
        }

    private fun terminate(process: Process, grouped: Boolean): Boolean {
        if (!grouped) {
            process.destroy()
            if (!process.waitFor(300, TimeUnit.MILLISECONDS)) process.destroyForcibly()
            return false // children cannot be proven gone without a process group
        }
        val group = -process.pid()
        runCatching { Os.kill(group, OsConstants.SIGTERM) }
        runCatching { process.waitFor(500, TimeUnit.MILLISECONDS) }
        if (groupExists(group)) runCatching { Os.kill(group, OsConstants.SIGKILL) }
        runCatching { process.waitFor(500, TimeUnit.MILLISECONDS) }
        if (process.isAlive) process.destroyForcibly()
        return !groupExists(group)
    }

    private fun groupExists(group: Int): Boolean = try {
        Os.kill(group, 0)
        true
    } catch (_: android.system.ErrnoException) {
        false
    }

    private fun result(id: String, state: String, reason: String?, exit: Int?, out: ByteArrayOutputStream,
                       err: ByteArrayOutputStream, truncated: Boolean, started: Long): String = JSONObject()
        .put("operationId", id).put("state", state).put("reason", reason ?: JSONObject.NULL)
        .put("exitCode", exit ?: JSONObject.NULL).put("stdout", out.toString("UTF-8"))
        .put("stderr", err.toString("UTF-8")).put("truncated", truncated)
        .put("elapsedMs", SystemClock.elapsedRealtime() - started).put("serviceInstance", instance).toString()

    companion object {
        private const val MAX_COMMAND_BYTES = 16 * 1024
        private const val MAX_OUTPUT_BYTES = 64 * 1024
        private val instance = java.util.UUID.randomUUID().toString()
    }
}
