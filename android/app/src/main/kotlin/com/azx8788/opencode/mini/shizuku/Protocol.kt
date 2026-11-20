package com.azx8788.opencode.mini.shizuku

import org.json.JSONObject
import java.security.MessageDigest

/** App-owned wire contract. Model arguments never contain a caller's identity. */
internal object Protocol {
    const val VERSION = ShizukuContract.BRIDGE_PROTOCOL
    const val SERVICE_VERSION = ShizukuContract.SERVICE_VERSION
    const val MAX_REQUEST_BYTES = 131_072
    const val MAX_RESPONSE_BYTES = 786_432
    val idPattern = Regex("[A-Za-z0-9_-]{1,80}")
    private val digestPattern = Regex("[a-f0-9]{64}")

    data class Owner(val source: String, val runtimeId: String, val directory: String,
                     val sessionId: String, val messageId: String, val callId: String, val agentId: String) {
        val sessionHash get() = hash(JSONObject().put("source", source).put("runtime", runtimeId)
            .put("directory", directory).put("session", sessionId).put("agent", agentId).toString())
        val ownerHash get() = hash("$sessionHash\u0000$messageId\u0000$callId")
    }

    fun owner(raw: JSONObject, expectedRuntime: String): Owner {
        require(raw.getString("source") == "opencode_tool")
        val scope = raw.getJSONObject("scope")
        fun word(key: String, max: Int = 256): String = scope.getString(key).also {
            require(it.isNotBlank() && it.length <= max && '\u0000' !in it)
        }
        val runtime = word("runtimeId", 80)
        require(runtime == expectedRuntime)
        val directory = word("directory", 4096)
        require(directory.startsWith('/'))
        val session = word("sessionID")
        require(session.startsWith("ses"))
        return Owner("opencode_tool", runtime, directory, session, word("messageID"), word("callID"), word("agentID", 128))
    }

    fun settingsOwner() = Owner("settings_test", "local", "/", "settings", "settings", "settings", "settings")

    fun validateCommand(command: String, timeout: Int?) {
        require(command.isNotBlank() && '\u0000' !in command && command.toByteArray(Charsets.UTF_8).size <= 16_384)
        require(timeout == null || timeout in 1_000..120_000)
    }

    fun fingerprint(command: String, requestedTimeout: Int?) = hash("$command\u0000${requestedTimeout ?: 0}")
    fun hash(value: String): String = MessageDigest.getInstance("SHA-256").digest(value.toByteArray(Charsets.UTF_8))
        .joinToString("") { "%02x".format(it.toInt() and 255) }
    fun validDigest(value: String) = digestPattern.matches(value)
    fun backend(uid: Int?) = when (uid) { 0 -> "root"; 2000 -> "adb"; else -> "unknown" }
    fun error(code: String): JSONObject = JSONObject().put("protocolVersion", VERSION).put("error", code)
        .put("state", "not_executed").put("environment", "android").put("fallback", false)
}
