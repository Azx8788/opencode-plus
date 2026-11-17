package com.azx8788.opencode.mini

import android.os.SystemClock
import android.system.Os
import android.system.OsConstants
import android.util.Base64
import org.json.JSONObject
import java.io.BufferedReader
import java.io.InputStream
import java.io.InputStreamReader
import java.io.ByteArrayOutputStream
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Semaphore
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlin.concurrent.thread

/**
 * Executes bounded commands in the Shizuku UserService identity.
 *
 * The process group leader is obtained from the shell itself: a tiny wrapper
 * prints `OCRPID=<pid>` as the first stderr line, which also equals the group
 * ID under `setsid`. `Process.pid()` is not used because it has no reliable
 * Android API surface, and parsing /proc at runtime is no more trustworthy
 * than the process reporting its own identity.
 */
class ShizukuCommandService : IShizukuCommandService.Stub() {
    private class Running(
        val process: Process,
        val startedAt: Long,
        val grouped: Boolean,
        val pid: AtomicInteger = AtomicInteger(0),
    )

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

        // The wrapper reports its own pid on stderr, then decodes and runs the
        // command body. Base64 keeps every user character out of the wrapper's
        // own quoting; the decoded body is parsed by sh exactly as before.
        val encoded = Base64.encodeToString(command.toByteArray(Charsets.UTF_8), Base64.NO_WRAP)
        val wrapped = "echo OCRPID=\$\$ >&2; exec sh -c \"\$(printf '%s' '$encoded' | base64 -d)\""

        var grouped = true
        val process = try {
            ProcessBuilder("setsid", "sh", "-c", wrapped).start()
        } catch (_: Throwable) {
            // setsid is part of Android's toybox, but if a platform lacks it we
            // still run the command; group termination is then reported
            // unconfirmed instead of inventing a success.
            grouped = false
            try { ProcessBuilder("sh", "-c", wrapped).start() }
            catch (error: Throwable) { executionSlot.release(); throw error }
        }
        val running = Running(process, SystemClock.elapsedRealtime(), grouped)
        if (active.putIfAbsent(operationId, running) != null) {
            executionSlot.release()
            terminate(running)
            error("duplicate_operation")
        }

        val stdout = ByteArrayOutputStream()
        val errOutput = ErrorCapture(outputLimitBytes)
        val outThread = drainStdout(process.inputStream, stdout, outputLimitBytes / 2) { errOutput.markTruncated() }
        val errThread = drainStderr(process.errorStream, errOutput) { running.pid.set(it) }
        try {
            val finished = process.waitFor(timeoutMs.toLong(), TimeUnit.MILLISECONDS)
            if (!finished) {
                val stopped = terminate(running)
                return result(operationId, if (stopped) "failed" else "unknown",
                    if (stopped) "timeout" else "timeout_unconfirmed", null,
                    stdout, errOutput, running.startedAt)
            }
            outThread.join(1_000)
            errThread.join(1_000)
            val exit = process.exitValue()
            return result(operationId, if (exit == 0) "succeeded" else "failed",
                if (exit == 0) null else "nonzero_exit", exit,
                stdout, errOutput, running.startedAt)
        } catch (_: InterruptedException) {
            val stopped = terminate(running)
            Thread.currentThread().interrupt()
            return result(operationId, if (stopped) "cancelled" else "unknown",
                if (stopped) "cancelled" else "cancel_unconfirmed", null,
                stdout, errOutput, running.startedAt)
        } finally {
            active.remove(operationId, running)
            executionSlot.release()
            runCatching { process.inputStream.close() }
            runCatching { process.errorStream.close() }
        }
    }

    override fun cancel(operationId: String): Boolean {
        val running = active[operationId] ?: return false
        return terminate(running)
    }

    override fun destroy() {
        active.values.forEach(::terminate)
        active.clear()
        System.exit(0)
    }

    /** Bounded stderr with the OCRPID header stripped from user-visible text. */
    private class ErrorCapture(val limit: Int) {
        private val buffer = ByteArrayOutputStream()
        @Volatile private var truncated = false
        @Volatile var pid = -1
        fun markTruncated() { truncated = true }
        fun pidLine(line: String) = runCatching {
            val value = line.removePrefix("OCRPID=").trim().toInt()
            if (value in 1..999_999) pid = value
        }.isSuccess
        fun append(line: String) {
            val bytes = (line + "\n").toByteArray(Charsets.UTF_8)
            val remaining = limit - buffer.size()
            if (remaining > 0) buffer.write(bytes, 0, minOf(bytes.size, remaining))
            if (bytes.size > remaining) truncated = true
        }
        fun text(): String = buffer.toString("UTF-8")
        fun truncated(): Boolean = truncated
    }

    private fun drainStdout(input: InputStream, output: ByteArrayOutputStream, limit: Int,
                            hitLimit: () -> Unit) = thread(isDaemon = true) {
        val buffer = ByteArray(4096)
        while (true) {
            val count = runCatching { input.read(buffer) }.getOrDefault(-1)
            if (count <= 0) break
            val remaining = limit - output.size()
            if (remaining > 0) output.write(buffer, 0, minOf(count, remaining))
            if (count > remaining) hitLimit()
        }
    }

    private fun drainStderr(input: InputStream, capture: ErrorCapture,
                            onPid: (Int) -> Unit) = thread(isDaemon = true) {
        val reader = BufferedReader(InputStreamReader(input, Charsets.UTF_8))
        var line = runCatching { reader.readLine() }.getOrNull()
        var first = true
        while (line != null) {
            if (first && line.startsWith("OCRPID=") && capture.pidLine(line)) {
                onPid(capture.pid) // header never counts as output
            } else {
                capture.append(line)
            }
            first = false
            if (capture.truncated()) {
                // Keep draining so the process never blocks on a full pipe.
                while (line != null) line = runCatching { reader.readLine() }.getOrNull()
                return@thread
            }
            line = runCatching { reader.readLine() }.getOrNull()
        }
    }

    /**
     * Confirmed termination requires proof of the process group's death.
     * Returns true only when that proof exists; otherwise unknown.
     */
    private fun terminate(running: Running): Boolean {
        if (!running.grouped) {
            runCatching { running.process.destroy() }
            if (!running.process.waitFor(300, TimeUnit.MILLISECONDS)) {
                runCatching { running.process.destroyForcibly() }
            }
            return false // children cannot be proven gone without a process group
        }
        val deadline = SystemClock.elapsedRealtime() + 1_500
        var pid = running.pid.get()
        while (pid <= 0 && SystemClock.elapsedRealtime() < deadline) {
            Thread.sleep(100)
            pid = running.pid.get()
        }
        if (pid <= 0) {
            runCatching { running.process.destroy() }
            runCatching { running.process.destroyForcibly() }
            return false
        }
        val group = -pid
        runCatching { Os.kill(group, OsConstants.SIGTERM) }
        runCatching { running.process.waitFor(500, TimeUnit.MILLISECONDS) }
        if (groupExists(group)) runCatching { Os.kill(group, OsConstants.SIGKILL) }
        runCatching { running.process.waitFor(500, TimeUnit.MILLISECONDS) }
        if (running.process.isAlive) runCatching { running.process.destroyForcibly() }
        return !groupExists(group)
    }

    private fun groupExists(group: Int): Boolean = try {
        Os.kill(group, 0)
        true
    } catch (_: android.system.ErrnoException) {
        false
    }

    private fun result(id: String, state: String, reason: String?, exit: Int?,
                       out: ByteArrayOutputStream, err: ErrorCapture, started: Long): String = JSONObject()
        .put("operationId", id).put("state", state).put("reason", reason ?: JSONObject.NULL)
        .put("exitCode", exit ?: JSONObject.NULL).put("stdout", out.toString("UTF-8"))
        .put("stderr", err.text()).put("truncated", err.truncated())
        .put("elapsedMs", SystemClock.elapsedRealtime() - started).put("serviceInstance", instance).toString()

    companion object {
        private const val MAX_COMMAND_BYTES = 16 * 1024
        private const val MAX_OUTPUT_BYTES = 256 * 1024
        private val instance = java.util.UUID.randomUUID().toString()
    }
}