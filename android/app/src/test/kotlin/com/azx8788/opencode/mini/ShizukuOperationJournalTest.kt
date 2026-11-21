package com.azx8788.opencode.mini

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.nio.file.Files

class ShizukuOperationJournalTest {
    @get:Rule val temporary = TemporaryFolder()
    private val owner = ShizukuProtocol.Owner("opencode_tool", "runtime", "/project", "ses1", "msg1", "call1", "build")
    private val fingerprint = ShizukuProtocol.fingerprint("id", null)
    private fun journal(directory: File, capacity: Int = 4096, cached: Int = 16) =
        ShizukuOperationJournal(directory, { 1000L }, capacity, cached)

    @Test fun `identical operation is admitted exactly once and changed input or scope conflicts`() {
        val value = journal(temporary.newFolder())
        assertTrue(value.admit("op", owner, fingerprint))
        assertFalse(value.admit("op", owner, fingerprint))
        assertEquals("queued", value.lookup("op", owner, fingerprint)!!.getString("state"))
        assertThrows(IllegalStateException::class.java) { value.admit("op", owner, ShizukuProtocol.fingerprint("getprop", null)) }
        assertThrows(IllegalStateException::class.java) { value.admit("op", owner.copy(sessionId = "ses2"), fingerprint) }
        assertThrows(IllegalStateException::class.java) { value.get("op", owner.copy(directory = "/other")) }
    }

    @Test fun `cancel before admission survives restart and blocks a late submit`() {
        val directory = temporary.newFolder()
        journal(directory).cancel("op", owner)
        val restored = journal(directory)
        assertFalse(restored.admit("op", owner, fingerprint))
        assertFalse(restored.dispatch("op", "service", 2000))
        val row = restored.get("op", owner)!!
        assertEquals("cancelled", row.getString("state"))
        assertTrue(row.isNull("uid"))
        assertFalse(row.has("elapsedMs"))
        assertFalse(row.has("exitCode"))
    }

    @Test fun `cancel while waiting prevents dispatch and no time or exit is invented`() {
        val value = journal(temporary.newFolder())
        value.admit("op", owner, fingerprint)
        assertTrue(value.waiting("op"))
        value.cancel("op", owner)
        assertFalse(value.dispatch("op", "service", 0))
        assertEquals("cancelled", value.get("op", owner)!!.getString("state"))
    }

    @Test fun `after a process restart an in-flight command is uncertain not safe to rerun`() {
        val directory = temporary.newFolder()
        val value = journal(directory)
        value.admit("op", owner, fingerprint)
        assertTrue(value.dispatch("op", "service", 2000))
        val restored = journal(directory)
        assertEquals("unknown", restored.get("op", owner)!!.getString("state"))
        assertFalse(restored.admit("op", owner, fingerprint))
        assertFalse(restored.dispatch("op", "other-service", 0))
    }

    private fun response(id: String, instance: String = "service", uid: Int = 2000) = JSONObject()
        .put("operationId", id).put("serviceInstance", instance).put("uid", uid).put("state", "succeeded")
        .put("stdout", "real fixture output").put("stderr", "").put("truncated", false)
        .put("exitCode", 0).put("elapsedMs", 17).put("termination", "not_requested")

    @Test fun `only the original identity can complete an uncertain operation`() {
        val value = journal(temporary.newFolder())
        value.admit("op", owner, fingerprint)
        value.dispatch("op", "service", 2000)
        value.uncertain("op", "binder_died")
        assertThrows(IllegalStateException::class.java) { value.finish("op", "other", 0, response("op", "other", 0)) }
        assertThrows(IllegalStateException::class.java) { value.finish("op", "service", 2000, response("another")) }
        value.finish("op", "service", 2000, response("op"))
        assertEquals(17L, value.get("op", owner)!!.getLong("elapsedMs"))
        assertEquals("succeeded", value.get("op", owner)!!.getString("state"))
    }

    @Test fun `output cache eviction does not evict dedup metadata`() {
        val directory = temporary.newFolder()
        val value = journal(directory, cached = 0)
        value.admit("op", owner, fingerprint)
        value.dispatch("op", "service", 2000)
        value.finish("op", "service", 2000, response("op"))
        val restored = journal(directory)
        assertFalse(restored.admit("op", owner, fingerprint))
        assertTrue(restored.get("op", owner)!!.getBoolean("outputUnavailable"))
        assertEquals("succeeded", restored.get("op", owner)!!.getString("state"))
    }

    @Test fun `history exhaustion does not silently delete a previous operation`() {
        val value = journal(temporary.newFolder(), capacity = 1)
        assertFalse(value.full())
        value.admit("op", owner, fingerprint)
        assertTrue(value.full())
        assertThrows(IllegalStateException::class.java) { value.admit("new", owner, fingerprint) }
        assertFalse(value.admit("op", owner, fingerprint))
    }

    @Test fun `an Android filesDir parent alias does not disable a safe journal`() {
        val files = temporary.newFolder("real-files")
        val alias = File(temporary.root, "files-alias")
        Files.createSymbolicLink(alias.toPath(), files.toPath())
        val value = journal(File(alias, "shizuku-operations"))
        assertTrue(value.available())
        assertTrue(value.admit("op", owner, fingerprint))
        val restored = journal(File(files, "shizuku-operations"))
        assertTrue(restored.available())
        assertFalse(restored.admit("op", owner, fingerprint))
    }

    @Test fun `unreadable metadata and symlinked storage are not overwritten`() {
        val directory = temporary.newFolder()
        val corrupt = File(directory, "${ShizukuProtocol.hash("op")}.json").apply { writeText("not json") }
        val value = journal(directory)
        assertFalse(value.available())
        assertThrows(IllegalStateException::class.java) { value.admit("new", owner, fingerprint) }
        assertEquals("not json", corrupt.readText())
        val link = File(temporary.root, "link")
        Files.createSymbolicLink(link.toPath(), directory.toPath())
        assertFalse(journal(link).available())
    }

    @Test fun `another tool call may inspect a result only inside the same session and agent`() {
        val value = journal(temporary.newFolder())
        value.admit("op", owner, fingerprint)
        assertNotNull(value.get("op", owner.copy(messageId = "msg2", callId = "call2")))
        assertThrows(IllegalStateException::class.java) { value.cancel("op", owner.copy(callId = "other")) }
        assertThrows(IllegalStateException::class.java) { value.get("op", owner.copy(agentId = "other")) }
    }
    @Test fun `dedup metadata contains no command or captured output`() {
        val directory = temporary.newFolder()
        val value = journal(directory)
        value.admit("op", owner, ShizukuProtocol.fingerprint("PRIVATE_COMMAND_FIXTURE", null))
        value.dispatch("op", "service", 2000)
        value.finish("op", "service", 2000, response("op"))
        val metadata = File(directory, "${ShizukuProtocol.hash("op")}.json").readText()
        assertFalse(metadata.contains("PRIVATE_COMMAND_FIXTURE"))
        assertFalse(metadata.contains("real fixture output"))
    }
}
