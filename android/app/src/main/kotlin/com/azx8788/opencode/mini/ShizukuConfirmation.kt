package com.azx8788.opencode.mini

import java.util.concurrent.atomic.AtomicBoolean

internal enum class ShizukuConfirmationOutcome(val reason: String?) {
    ALLOWED(null),
    USER_DENIED("confirmation_user_denied"),
    TIMED_OUT("confirmation_timeout"),
    CANCELLED("confirmation_cancelled"),
    PERMISSION_MISSING("overlay_permission_missing"),
    UNAVAILABLE("confirmation_unavailable"),
}

/** A one-shot decision for a single overlay. A late tap or timer cannot change it. */
internal class ShizukuConfirmation(
    private val allowDelayMs: Long,
    private val timeoutMs: Long,
    private val complete: (ShizukuConfirmationOutcome) -> Unit,
) {
    private val finished = AtomicBoolean(false)
    val isFinished: Boolean get() = finished.get()

    fun finish(outcome: ShizukuConfirmationOutcome) {
        if (finished.compareAndSet(false, true)) complete(outcome)
    }

    fun choose(allow: Boolean, elapsedMs: Long, hasOverlayPermission: Boolean) {
        when {
            elapsedMs >= timeoutMs -> finish(ShizukuConfirmationOutcome.TIMED_OUT)
            !allow -> finish(ShizukuConfirmationOutcome.USER_DENIED)
            !hasOverlayPermission -> finish(ShizukuConfirmationOutcome.PERMISSION_MISSING)
            elapsedMs >= allowDelayMs -> finish(ShizukuConfirmationOutcome.ALLOWED)
        }
    }

    fun tick(elapsedMs: Long, hasOverlayPermission: Boolean) {
        if (elapsedMs >= timeoutMs) finish(ShizukuConfirmationOutcome.TIMED_OUT)
        else if (!hasOverlayPermission) finish(ShizukuConfirmationOutcome.PERMISSION_MISSING)
    }
}
