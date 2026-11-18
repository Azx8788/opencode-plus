package com.azx8788.opencode.mini

/** Host-testable binding epochs. Receiving a Binder is not an execution handshake. */
internal class ShizukuBindingState<T>(private val now: () -> Long, private val timeoutMs: Long = 10_000) {
    data class Ready<T>(val service: T, val instance: String, val uid: Int)
    data class Snapshot<T>(val epoch: Long, val phase: String, val reason: String?, val ready: Ready<T>?)

    private var epoch = 0L
    private var phase = "disconnected"
    private var reason: String? = null
    private var deadline = 0L
    private var ready: Ready<T>? = null

    @Synchronized fun snapshot() = Snapshot(epoch, phase, reason, ready)

    @Synchronized fun begin(): Long? {
        if (phase in setOf("connecting", "verifying", "connected")) return null
        epoch++
        phase = "connecting"
        reason = null
        ready = null
        deadline = now() + timeoutMs
        return epoch
    }

    @Synchronized fun verifying(expected: Long): Boolean {
        if (!pending(expected)) return false
        phase = "verifying"
        return true
    }

    @Synchronized fun connected(expected: Long, service: T, instance: String, uid: Int): Boolean {
        if (!pending(expected)) return false
        if (instance.isBlank() || uid !in setOf(0, 2000)) {
            fail(expected, "handshake_invalid")
            return false
        }
        ready = Ready(service, instance, uid)
        phase = "connected"
        reason = null
        return true
    }

    @Synchronized fun fail(expected: Long, why: String): Boolean {
        if (epoch != expected || phase == "failed" || phase == "disconnected") return false
        ready = null
        phase = "failed"
        reason = why
        return true
    }

    @Synchronized fun expire(expected: Long): Boolean {
        if (epoch != expected || phase !in setOf("connecting", "verifying") || now() < deadline) return false
        return fail(expected, if (phase == "verifying") "handshake_timeout" else "bind_timeout")
    }

    @Synchronized fun reset(why: String? = null) {
        epoch++ // Late connect, handshake, timeout and death callbacks are now obsolete.
        ready = null
        phase = if (why == null) "disconnected" else "failed"
        reason = why
    }

    private fun pending(expected: Long): Boolean {
        expire(expected)
        return epoch == expected && phase in setOf("connecting", "verifying")
    }
}
