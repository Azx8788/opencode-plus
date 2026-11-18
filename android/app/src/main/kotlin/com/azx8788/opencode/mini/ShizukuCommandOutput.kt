package com.azx8788.opencode.mini

import java.io.ByteArrayOutputStream
import java.io.InputStream

/** Byte-bounded, thread-safe capture. Draining never allocates a complete line. */
internal class ShizukuCommandOutput(limitBytes: Int) {
    private val stdoutLimit = limitBytes / 2
    private val stderrLimit = limitBytes - stdoutLimit
    private val stdout = ByteArrayOutputStream()
    private val stderr = ByteArrayOutputStream()
    private var truncated = false

    init { require(limitBytes > 0) }

    data class Snapshot(val stdout: String, val stderr: String, val truncated: Boolean)

    @Synchronized
    fun snapshot(): Snapshot = Snapshot(
        stdout.toString("UTF-8"), stderr.toString("UTF-8"), truncated,
    )

    @Synchronized
    fun markIncomplete() { truncated = true }

    fun drainStdout(input: InputStream) = drain(input, stdout, stdoutLimit)

    /** Only the wrapper's first, length-limited stderr line may set the PID. */
    fun drainStderr(input: InputStream, onPid: (Int) -> Unit) {
        val header = ByteArrayOutputStream()
        while (header.size() < MAX_HEADER_BYTES) {
            val byte = input.read()
            if (byte < 0) break
            header.write(byte)
            if (byte == '\n'.code) break
        }
        val bytes = header.toByteArray()
        val line = String(bytes, Charsets.US_ASCII)
        val match = Regex("OCRPID=([1-9][0-9]{0,9})\\n").matchEntire(line)
        val pid = match?.groupValues?.get(1)?.toIntOrNull()?.takeIf { it > 1 }
        if (pid != null) onPid(pid) else append(stderr, stderrLimit, bytes, bytes.size)
        drain(input, stderr, stderrLimit)
    }

    private fun drain(input: InputStream, output: ByteArrayOutputStream, limit: Int) {
        val buffer = ByteArray(4096)
        while (true) {
            val count = input.read(buffer)
            if (count < 0) return
            if (count > 0) append(output, limit, buffer, count)
        }
    }

    @Synchronized
    private fun append(output: ByteArrayOutputStream, limit: Int, bytes: ByteArray, count: Int) {
        val retained = minOf(count, (limit - output.size()).coerceAtLeast(0))
        if (retained > 0) output.write(bytes, 0, retained)
        if (retained < count) truncated = true
    }

    companion object { private const val MAX_HEADER_BYTES = 64 }
}
