package com.azx8788.opencode.mini

import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayInputStream

class ShizukuCommandOutputTest {
    @Test fun `strips only the wrapper header and preserves stderr bytes`() {
        val output = ShizukuCommandOutput(1024)
        var pid = 0
        output.drainStderr(ByteArrayInputStream("OCRPID=1234\nfirst\nOCRPID=4321\nlast".toByteArray())) { pid = it }
        assertEquals(1234, pid)
        assertEquals("first\nOCRPID=4321\nlast", output.snapshot().stderr)
        assertFalse(output.snapshot().truncated)
    }

    @Test fun `invalid or oversized header never becomes a pid`() {
        for (header in listOf("OCRPID=0\n", "OCRPID=1\n", "OCRPID=-7\n", "OCRPID=9999999999\n", "x".repeat(100))) {
            val output = ShizukuCommandOutput(1024)
            var pid = 0
            output.drainStderr(ByteArrayInputStream(header.toByteArray())) { pid = it }
            assertEquals(header, output.snapshot().stderr)
            assertEquals(0, pid)
        }
    }

    @Test fun `newline-free output stays bounded and both streams drain fully`() {
        val output = ShizukuCommandOutput(1024)
        val stdout = ByteArrayInputStream(ByteArray(2 * 1024 * 1024) { 'o'.code.toByte() })
        val stderr = ByteArrayInputStream("OCRPID=123\n".toByteArray() + ByteArray(2 * 1024 * 1024) { 'e'.code.toByte() })
        output.drainStdout(stdout)
        output.drainStderr(stderr) {}
        val snapshot = output.snapshot()
        assertEquals(512, snapshot.stdout.toByteArray().size)
        assertEquals(512, snapshot.stderr.toByteArray().size)
        assertTrue(snapshot.truncated)
        assertEquals(0, stdout.available())
        assertEquals(0, stderr.available())
    }

    @Test fun `stdout truncation does not suppress stderr or pid capture`() {
        val output = ShizukuCommandOutput(32)
        output.drainStdout(ByteArrayInputStream(ByteArray(100)))
        var pid = 0
        output.drainStderr(ByteArrayInputStream("OCRPID=222\nerror".toByteArray())) { pid = it }
        assertEquals(222, pid)
        assertEquals("error", output.snapshot().stderr)
        assertTrue(output.snapshot().truncated)
    }
}
