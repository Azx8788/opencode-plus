package com.azx8788.opencode.mini

/**
 * Host-testable Shizuku authorization request.
 *
 * The request is a record of what the person asked for, not proof of consent:
 * "granted" is only reported from the Shizuku server, a missing callback is
 * never reported as a denial, and a Binder replacement cannot leave a request
 * pending forever. Shizuku keeps its decision in the manager's own list keyed
 * by UID, so an app that keeps a dead request "requesting" blocks binding
 * behind a dialog that will never return a result.
 */
internal class ShizukuPermissionRequest(val timeoutMs: Long = 30_000) {
    data class Snapshot(val epoch: Long, val state: String, val reason: String?, val granted: Boolean?)

    private var epoch = 0L
    private var state = "not_requested"
    private var reason: String? = null
    private var granted: Boolean? = null

    @Synchronized fun snapshot() = Snapshot(epoch, state, reason, granted)

    /** Starts a request, or returns null when one is already waiting for its result. */
    @Synchronized fun begin(): Long? {
        if (state == "requesting") return null
        epoch++
        state = "requesting"
        reason = null
        granted = null
        return epoch
    }

    /** The request could not be handed to Shizuku at all. */
    @Synchronized fun failed(why: String) {
        if (state != "requesting") return
        state = "failed"
        reason = why
        granted = null
    }

    /** The request was not attempted: no service, or an authorization owner with no dialog. */
    @Synchronized fun unavailable(why: String) {
        if (state == "requesting") return
        state = "unavailable"
        reason = why
        granted = null
    }

    /** The server answered the pending request. Anything else is not a result. */
    @Synchronized fun deliver(allowed: Boolean): Boolean {
        if (state != "requesting") return false
        state = if (allowed) "granted" else "denied"
        reason = if (allowed) null else "permission_denied"
        granted = allowed
        return true
    }

    /**
     * The callback deadline passed. A grant the server already reports is
     * accepted; everything else becomes "unconfirmed" so the person can ask
     * again instead of being told the request failed.
     */
    @Synchronized fun expire(expected: Long, serverGranted: Boolean): Boolean {
        if (epoch != expected || state != "requesting") return false
        if (serverGranted) {
            state = "granted"
            reason = null
            granted = true
        } else {
            state = "unconfirmed"
            reason = "permission_callback_missing"
            granted = null
        }
        return true
    }

    /** A Binder replacement, a dead service or a stopped feature ends a pending request. */
    @Synchronized fun interrupt(why: String) {
        if (state != "requesting") return
        state = "interrupted"
        reason = why
        granted = null
    }

    /**
     * Read the server's answer instead of trusting the last one. A revocation
     * made in the manager's list is reported, never silently kept as granted.
     */
    @Synchronized fun sync(serverGranted: Boolean): Boolean {
        if (serverGranted) {
            if (state == "granted") return false
            state = "granted"
            reason = null
            granted = true
            return true
        }
        if (state == "granted") {
            state = "not_requested"
            reason = "permission_revoked"
            granted = null
            return true
        }
        return false
    }
}
