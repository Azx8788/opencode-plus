package com.azx8788.opencode.mini.shizuku

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class ProtocolTest {
    @Test fun `native owner is bound to a runtime and is not supplied as a model tool argument`() {
        val scope = JSONObject().put("runtimeId", "installed-runtime").put("directory", "/project")
            .put("sessionID", "ses1").put("messageID", "msg1").put("callID", "provider-call").put("agentID", "build")
        val request = JSONObject().put("source", "opencode_tool").put("scope", scope)
        assertEquals("ses1", Protocol.owner(request, "installed-runtime").sessionId)
        assertThrows(IllegalArgumentException::class.java) { Protocol.owner(request, "another-runtime") }
        scope.put("directory", "../other")
        assertThrows(IllegalArgumentException::class.java) { Protocol.owner(request, "installed-runtime") }
    }
    @Test fun `complex commands remain available but oversized malformed requests do not`() {
        Protocol.validateCommand("printf test | cat; id", 1000)
        assertThrows(IllegalArgumentException::class.java) { Protocol.validateCommand("id\u0000getprop", null) }
        assertThrows(IllegalArgumentException::class.java) { Protocol.validateCommand("a".repeat(16385), null) }
        assertThrows(IllegalArgumentException::class.java) { Protocol.validateCommand("id", 120001) }
    }
    @Test fun `UID classification never promotes unknown identities to root`() {
        assertEquals("adb", Protocol.backend(2000))
        assertEquals("root", Protocol.backend(0))
        assertEquals("unknown", Protocol.backend(null))
        assertEquals("unknown", Protocol.backend(10001))
    }
}
