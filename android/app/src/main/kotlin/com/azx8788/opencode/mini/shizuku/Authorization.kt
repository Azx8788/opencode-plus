package com.azx8788.opencode.mini.shizuku

/**
 * The authorization request, as a record of what was asked and what came back.
 *
 * Rules this class exists to enforce:
 *  - a missing callback is never turned into a denial, and never into a grant;
 *  - a grant is only recorded from the server's own answer;
 *  - a binder change cannot leave a request pending forever;
 *  - the person's decision is never inferred from a local switch.
 */
internal class AuthorizationRequest(
    private val timeoutMs: Long = DEFAULT_TIMEOUT_MS,
    private val minIntervalMs: Long = MIN_INTERVAL_MS,
    private val maxAttempts: Int = MAX_ATTEMPTS,
) {
    private var epoch = 0L
    private var phase = RequestPhase.IDLE
    private var reason: String? = null
    private var code: Int? = null
    private var startedAt: Long? = null
    private var attempts = 0
    private var lastAttemptAt = 0L

    @Synchronized
    fun status() = RequestStatus(phase, reason, code, attempts, startedAt)

    @Synchronized
    fun pending() = phase == RequestPhase.PENDING

    /**
     * Why a request may not be issued right now, or null when it may.
     * These are preconditions of the *call*, not of authorization.
     */
    @Synchronized
    fun refusal(now: Long): String? = when {
        phase == RequestPhase.PENDING -> "request_already_pending"
        attempts >= maxAttempts -> "too_many_attempts"
        now - lastAttemptAt < minIntervalMs -> "request_too_soon"
        else -> null
    }

    /** Starts a request. Returns the epoch, or null when one is already pending. */
    @Synchronized
    fun begin(requestCode: Int, now: Long): Long? {
        if (phase == RequestPhase.PENDING) return null
        epoch++
        phase = RequestPhase.PENDING
        reason = null
        code = requestCode
        startedAt = now
        lastAttemptAt = now
        attempts++
        return epoch
    }

    /** The call itself threw: nothing reached the server. */
    @Synchronized
    fun failed(expectedEpoch: Long, requestCode: Int, why: String): Boolean {
        if (epoch != expectedEpoch || code != requestCode || phase != RequestPhase.PENDING) return false
        code = null
        phase = RequestPhase.UNAVAILABLE
        reason = why
        return true
    }

    /** A precondition refused the request before it was issued. */
    @Synchronized
    fun unavailable(why: String) {
        if (phase == RequestPhase.PENDING) return
        code = null
        phase = RequestPhase.UNAVAILABLE
        reason = why
    }

    /** The server answered the pending request. */
    @Synchronized
    fun deliver(requestCode: Int, allowed: Boolean): Boolean {
        if (phase != RequestPhase.PENDING || code != requestCode) return false
        code = null
        phase = if (allowed) RequestPhase.GRANTED else RequestPhase.DENIED
        reason = if (allowed) null else "permission_denied"
        return true
    }

    /**
     * The deadline passed. A grant the server now reports is accepted (the
     * callback can be lost); anything else is "unconfirmed", so the person can
     * ask again instead of being told they refused.
     */
    @Synchronized
    fun expire(expectedEpoch: Long, live: AuthorizationReading): Boolean {
        if (epoch != expectedEpoch || phase != RequestPhase.PENDING) return false
        code = null
        when (live.state) {
            AuthorizationState.GRANTED -> {
                phase = RequestPhase.GRANTED
                reason = null
            }
            AuthorizationState.DENIED -> {
                phase = RequestPhase.DENIED
                reason = "permission_denied"
            }
            AuthorizationState.UNKNOWN -> {
                phase = RequestPhase.UNCONFIRMED
                reason = "callback_missing"
            }
        }
        return true
    }

    /** A binder replacement, a dead server or a disabled feature ends the wait. */
    @Synchronized
    fun interrupt(why: String) {
        if (phase != RequestPhase.PENDING) return
        code = null
        phase = RequestPhase.INTERRUPTED
        reason = why
    }

    /**
     * Reconcile the recorded request with the live server answer. Called after
     * every probe, so a revocation made in the manager is reported instead of
     * being kept as granted.
     */
    @Synchronized
    fun sync(live: AuthorizationReading) {
        if (live.state == AuthorizationState.GRANTED) {
            if (phase != RequestPhase.GRANTED) {
                phase = RequestPhase.GRANTED
                reason = null
                code = null
            }
            return
        }
        if (live.state == AuthorizationState.DENIED && phase == RequestPhase.GRANTED) {
            phase = RequestPhase.IDLE
            reason = "permission_revoked"
        }
    }

    /**
     * Starts over: used when the person re-enables the feature. The attempt
     * budget is replenished here and only here, so a loop of failed requests
     * cannot exhaust it without an explicit new decision.
     */
    @Synchronized
    fun reset() {
        epoch++
        phase = RequestPhase.IDLE
        reason = null
        code = null
        startedAt = null
        attempts = 0
        lastAttemptAt = 0
    }

    companion object {
        const val DEFAULT_TIMEOUT_MS = 30_000L
        const val MIN_INTERVAL_MS = 1_500L
        const val MAX_ATTEMPTS = 10
    }
}
