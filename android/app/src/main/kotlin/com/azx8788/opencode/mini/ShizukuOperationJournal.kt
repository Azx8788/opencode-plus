package com.azx8788.opencode.mini

import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.nio.channels.FileChannel
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.nio.file.StandardOpenOption

/** Permanent bounded dedup metadata; only the separate recent output cache is pruned. */
internal class ShizukuOperationJournal(directory: File, private val now: () -> Long,
                                       private val capacity: Int = 4096, private val cachedResults: Int = 16) {
    private var directory = directory.absoluteFile
    private val rows = linkedMapOf<String, JSONObject>()
    private var healthy = true
    private val terminal = setOf("succeeded", "failed", "denied", "cancelled", "unknown")

    init {
        try {
            // Android can expose its app-owned filesDir through /data/user/0
            // or another alias. Canonicalize that parent, never the journal itself.
            val path = this.directory
            this.directory = File(checkNotNull(path.parentFile).canonicalFile, path.name)
            val canonical = this.directory
            check(!Files.isSymbolicLink(canonical.toPath()))
            if (!canonical.exists()) check(canonical.mkdirs())
            check(canonical.canonicalFile == canonical && canonical.isDirectory)
            privateMode(canonical)
            val entries = checkNotNull(canonical.listFiles()).filter { it.name.endsWith(".json") }
            check(entries.size <= capacity)
            for (file in entries) {
                check(file.name.matches(Regex("[a-f0-9]{64}\\.json")))
                val row = JSONObject(read(file, 8192))
                validate(row)
                check(file.name == "${ShizukuProtocol.hash(row.getString("operationId"))}.json")
                rows[row.getString("operationId")] = row
            }
            // A dispatch marker was committed before IPC. No result means uncertain, not safe to retry.
            for (row in rows.values) {
                when (row.getString("state")) {
                    "running" -> { row.put("state", "unknown").put("reason", "app_restarted"); writeRow(row) }
                    "queued", "waiting" -> {
                        row.put("state", "cancelled").put("reason", "interrupted_before_dispatch")
                            .put("finishedAt", now()); writeRow(row)
                    }
                }
            }
        } catch (_: Exception) { healthy = false }
    }

    @Synchronized fun available() = healthy

    @Synchronized fun full() = healthy && rows.size >= capacity

    /** true only for a newly durably admitted operation. */
    @Synchronized fun admit(id: String, owner: ShizukuProtocol.Owner, digest: String): Boolean {
        checkHealthy()
        require(ShizukuProtocol.idPattern.matches(id) && ShizukuProtocol.validDigest(digest))
        rows[id]?.let {
            check(it.getString("ownerHash") == owner.ownerHash) { "operation_conflict" }
            check(it.isNull("fingerprint") || it.getString("fingerprint") == digest) { "operation_conflict" }
            return false
        }
        check(rows.size < capacity) { "operation_history_full" }
        val row = base(id, owner).put("fingerprint", digest).put("state", "queued")
        persist(row)
        return true
    }

    @Synchronized fun get(id: String, owner: ShizukuProtocol.Owner, exact: Boolean = false): JSONObject? {
        checkHealthy()
        val row = rows[id] ?: return null
        check(row.getString(if (exact) "ownerHash" else "sessionHash") ==
            if (exact) owner.ownerHash else owner.sessionHash) { "operation_conflict" }
        return try { expose(row) } catch (error: Exception) { healthy = false; throw error }
    }

    @Synchronized fun lookup(id: String, owner: ShizukuProtocol.Owner, digest: String): JSONObject? {
        checkHealthy()
        val row = rows[id] ?: return null
        check(row.getString("ownerHash") == owner.ownerHash &&
            (row.isNull("fingerprint") || row.getString("fingerprint") == digest)) { "operation_conflict" }
        return get(id, owner, true)
    }

    @Synchronized fun active(): List<JSONObject> = rows.values.filter {
        it.getString("state") in setOf("queued", "waiting", "running")
    }.map { copy(it) }

    @Synchronized fun waiting(id: String): Boolean = changeBeforeDispatch(id, "waiting")

    /** Serializes the irreversible IPC boundary against cancellation, with a durable marker first. */
    @Synchronized fun dispatch(id: String, instance: String, uid: Int): Boolean {
        checkHealthy()
        val row = checkNotNull(rows[id])
        if (row.getString("state") !in setOf("queued", "waiting") || row.optBoolean("cancelRequested")) return false
        persist(copy(row).put("state", "running").put("serviceInstance", instance).put("uid", uid)
            .put("dispatchAt", now()))
        return true
    }

    @Synchronized fun cancel(id: String, owner: ShizukuProtocol.Owner): JSONObject {
        checkHealthy()
        require(ShizukuProtocol.idPattern.matches(id))
        val row = rows[id]
        if (row == null) {
            check(rows.size < capacity) { "operation_history_full" }
            // A late submit with this ID is now rejected, even after an app restart.
            val tombstone = base(id, owner).put("state", "cancelled").put("reason", "cancelled_before_admission")
                .put("cancelRequested", true).put("finishedAt", now())
            persist(tombstone)
            return expose(tombstone)
        }
        check(row.getString("ownerHash") == owner.ownerHash) { "operation_conflict" }
        val changed = copy(row)
        if (row.getString("state") in setOf("queued", "waiting")) {
            changed.put("state", "cancelled").put("reason", "cancelled_before_dispatch").put("finishedAt", now())
        }
        if (row.getString("state") !in terminal || row.getString("state") == "unknown") {
            changed.put("cancelRequested", true).put("termination", "requested")
        }
        persist(changed)
        return expose(changed)
    }

    @Synchronized fun failBeforeDispatch(id: String, reason: String) {
        checkHealthy()
        val row = rows[id] ?: return
        if (row.getString("state") !in setOf("queued", "waiting")) return
        persist(copy(row).put("state", "denied").put("reason", reason).put("finishedAt", now()))
    }

    @Synchronized fun uncertain(id: String, reason: String) {
        checkHealthy()
        val row = rows[id] ?: return
        if (row.getString("state") != "running") return
        persist(copy(row).put("state", "unknown").put("reason", reason).put("observedAt", now()))
    }

    @Synchronized fun finish(id: String, instance: String, uid: Int, result: JSONObject) {
        checkHealthy()
        val row = checkNotNull(rows[id])
        check(row.getString("serviceInstance") == instance && row.getInt("uid") == uid)
        check(result.getString("operationId") == id && result.getString("serviceInstance") == instance && result.getInt("uid") == uid)
        check(result.getString("state") in terminal && result.getString("state") != "denied")
        if (row.getString("state") !in setOf("running", "unknown")) return
        val value = copy(result)
        value.put("protocolVersion", ShizukuProtocol.VERSION).put("environment", "android").put("backend", ShizukuProtocol.backend(uid))
        val text = value.toString()
        check(text.toByteArray(Charsets.UTF_8).size <= ShizukuProtocol.MAX_RESPONSE_BYTES)
        try {
            atomicFile(resultFile(id), text)
            val next = copy(row).put("state", value.getString("state")).put("reason", value.opt("reason") ?: JSONObject.NULL)
                .put("finishedAt", now()).put("termination", value.optString("termination", "not_requested"))
            for (key in listOf("exitCode", "elapsedMs", "startedAt")) next.put(key, value.opt(key) ?: JSONObject.NULL)
            persist(next)
            pruneResults()
        } catch (error: Exception) { healthy = false; throw error }
    }

    private fun changeBeforeDispatch(id: String, state: String): Boolean {
        checkHealthy()
        val row = checkNotNull(rows[id])
        if (row.getString("state") !in setOf("queued", "waiting")) return false
        persist(copy(row).put("state", state))
        return true
    }

    private fun base(id: String, owner: ShizukuProtocol.Owner) = JSONObject().put("version", 1)
        .put("operationId", id).put("ownerHash", owner.ownerHash).put("sessionHash", owner.sessionHash)
        .put("source", owner.source).put("fingerprint", JSONObject.NULL).put("acceptedAt", now())
        .put("reason", JSONObject.NULL).put("serviceInstance", JSONObject.NULL).put("uid", JSONObject.NULL)
        .put("cancelRequested", false).put("termination", "not_requested")

    private fun expose(row: JSONObject): JSONObject {
        val public = copy(row)
        for (key in listOf("ownerHash", "sessionHash", "fingerprint", "version")) public.remove(key)
        public.put("protocolVersion", ShizukuProtocol.VERSION).put("environment", "android").put("fallback", false)
            .put("backend", ShizukuProtocol.backend(if (row.isNull("uid")) null else row.getInt("uid")))
        // The marker precedes Binder dispatch. Absence is evidence of no
        // dispatch; presence alone cannot prove the shell actually started.
        public.put("executionStage", if (row.has("dispatchAt") && !row.isNull("dispatchAt")) "dispatched" else "not_dispatched")
        val result = resultFile(row.getString("operationId"))
        if (row.getString("state") in terminal && result.exists()) {
            val data = JSONObject(read(result, ShizukuProtocol.MAX_RESPONSE_BYTES))
            check(data.getString("operationId") == row.getString("operationId"))
            check(data.getString("serviceInstance") == row.getString("serviceInstance"))
            for (key in listOf("stdout", "stderr", "truncated", "startedAt", "elapsedMs", "exitCode", "termination")) {
                if (data.has(key)) public.put(key, data.get(key))
            }
        } else if (row.getString("state") in terminal && !row.isNull("serviceInstance")) public.put("outputUnavailable", true)
        return public
    }

    private fun persist(row: JSONObject) {
        try { writeRow(row); rows[row.getString("operationId")] = row }
        catch (error: Exception) { healthy = false; throw error }
    }
    private fun writeRow(row: JSONObject) = atomicFile(File(directory, "${ShizukuProtocol.hash(row.getString("operationId"))}.json"), row.toString())
    private fun resultFile(id: String) = File(directory, "${ShizukuProtocol.hash(id)}.result")
    private fun checkHealthy() { check(healthy) { "operation_storage_unavailable" } }
    private fun copy(value: JSONObject) = JSONObject(value.toString())

    private fun validate(row: JSONObject) {
        check(row.getInt("version") == 1 && ShizukuProtocol.idPattern.matches(row.getString("operationId")))
        check(ShizukuProtocol.validDigest(row.getString("ownerHash")) && ShizukuProtocol.validDigest(row.getString("sessionHash")))
        check(row.isNull("fingerprint") || ShizukuProtocol.validDigest(row.getString("fingerprint")))
        check(row.getString("state") in terminal + setOf("queued", "waiting", "running"))
        check(row.getString("source") in setOf("settings_test", "opencode_tool"))
    }

    private fun pruneResults() {
        val keep = rows.values.filter { !it.isNull("finishedAt") && it.getString("state") in terminal }
            .sortedByDescending { it.getLong("finishedAt") }.take(cachedResults).map { resultFile(it.getString("operationId")).name }.toSet()
        for (row in rows.values) {
            val file = resultFile(row.getString("operationId"))
            if (file.name !in keep && file.exists()) { check(!Files.isSymbolicLink(file.toPath())); check(file.delete()) }
        }
    }

    companion object {
        private fun privateMode(file: File) {
            check(file.setReadable(false, false) && file.setWritable(false, false))
            check(file.setReadable(true, true) && file.setWritable(true, true))
            if (file.isDirectory) { check(file.setExecutable(false, false)); check(file.setExecutable(true, true)) }
        }
        private fun read(file: File, max: Int): String {
            check(!Files.isSymbolicLink(file.toPath()) && file.isFile && file.length() in 1..max.toLong())
            return file.inputStream().use { input ->
                val bytes = ByteArray(max + 1)
                var count = 0
                while (count < bytes.size) {
                    val n = input.read(bytes, count, bytes.size - count)
                    if (n < 0) break
                    count += n
                }
                check(count in 1..max)
                String(bytes, 0, count, Charsets.UTF_8)
            }
        }
        internal fun atomicFile(file: File, text: String) {
            check(!Files.isSymbolicLink(file.toPath()) && file.parentFile.canonicalFile == file.parentFile.absoluteFile)
            val temporary = File.createTempFile(".shizuku-", ".tmp", file.parentFile)
            try {
                privateMode(temporary)
                FileOutputStream(temporary).use { it.write(text.toByteArray(Charsets.UTF_8)); it.fd.sync() }
                Files.move(temporary.toPath(), file.toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
                FileChannel.open(file.parentFile.toPath(), StandardOpenOption.READ).use { it.force(true) }
            } finally { if (temporary.exists()) temporary.delete() }
        }
    }
}
