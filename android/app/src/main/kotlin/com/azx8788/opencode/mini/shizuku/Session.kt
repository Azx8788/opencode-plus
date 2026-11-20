package com.azx8788.opencode.mini.shizuku

/**
 * One UserService connection attempt, with an epoch so late callbacks from an
 * older attempt can never overwrite a newer one. Receiving a Binder is not a
 * handshake: [READY] is only set after the service answered with its own
 * instance id, protocol version and UID.
 */
internal class SessionState(
    private val now: () -> Long,
    private val bindTimeoutMs: Long = 10_000,
    private val handshakeTimeoutMs: Long = 5_000,
) {
    private var epoch = 0L
    private var phase = SessionPhase.STOPPED
    private var reason: String? = null
    private var instance: String? = null
    private var uid: Int? = null
    private var serviceVersion: Int? = null
    private var deadline = 0L

    @Synchronized
    fun status() = SessionStatus(phase, reason, instance, uid, serviceVersion)

    @Synchronized
    fun readyInstance(): String? = if (phase == SessionPhase.READY) instance else null

    @Synchronized
    fun begin(): Long? {
        if (phase == SessionPhase.BINDING || phase == SessionPhase.HANDSHAKING || phase == SessionPhase.READY) return null
        epoch++
        phase = SessionPhase.BINDING
        reason = null
        instance = null
        uid = null
        serviceVersion = null
        deadline = now() + bindTimeoutMs
        return epoch
    }

    @Synchronized
    fun handshaking(expected: Long): Boolean {
        if (!pending(expected)) return false
        phase = SessionPhase.HANDSHAKING
        deadline = now() + handshakeTimeoutMs
        return true
    }

    @Synchronized
    fun connected(expected: Long, serviceInstance: String, actualUid: Int, version: Int): Boolean {
        if (!pending(expected)) return false
        if (serviceInstance.isBlank() || actualUid !in ServerIdentity.SUPPORTED_UIDS ||
            version != ShizukuContract.SERVICE_VERSION
        ) {
            fail(expected, "handshake_mismatch")
            return false
        }
        phase = SessionPhase.READY
        reason = null
        instance = serviceInstance
        uid = actualUid
        serviceVersion = version
        return true
    }

    @Synchronized
    fun fail(expected: Long, why: String): Boolean {
        if (epoch != expected) return false
        if (phase == SessionPhase.STOPPED || phase == SessionPhase.FAILED) return false
        phase = SessionPhase.FAILED
        reason = why
        instance = null
        uid = null
        serviceVersion = null
        return true
    }

    @Synchronized
    fun expire(expected: Long): Boolean {
        if (epoch != expected) return false
        if (phase != SessionPhase.BINDING && phase != SessionPhase.HANDSHAKING) return false
        if (now() < deadline) return false
        return fail(expected, if (phase == SessionPhase.HANDSHAKING) "handshake_timeout" else "bind_timeout")
    }

    @Synchronized
    fun reset(why: String?) {
        epoch++
        phase = if (why == null) SessionPhase.STOPPED else SessionPhase.FAILED
        reason = why
        instance = null
        uid = null
        serviceVersion = null
    }

    private fun pending(expected: Long): Boolean {
        expire(expected)
        return epoch == expected && (phase == SessionPhase.BINDING || phase == SessionPhase.HANDSHAKING)
    }
}
