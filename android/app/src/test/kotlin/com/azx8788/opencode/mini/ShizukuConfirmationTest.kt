package com.azx8788.opencode.mini

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

class ShizukuConfirmationTest {
    @Test fun `explicit reject is terminal even if allow or timeout follows`() {
        val outcomes = mutableListOf<ShizukuConfirmationOutcome>()
        val confirmation = ShizukuConfirmation(3_000, 10_000) { outcomes.add(it) }
        confirmation.choose(false, 1, true)
        confirmation.choose(true, 3_000, true)
        confirmation.tick(10_000, true)
        confirmation.finish(ShizukuConfirmationOutcome.CANCELLED)
        assertEquals(listOf(ShizukuConfirmationOutcome.USER_DENIED), outcomes)
    }

    @Test fun `delayed timer does not let a tap past the deadline approve or claim a rejection`() {
        for (allow in listOf(false, true)) {
            val outcomes = mutableListOf<ShizukuConfirmationOutcome>()
            val confirmation = ShizukuConfirmation(3_000, 10_000) { outcomes.add(it) }
            confirmation.choose(allow, 10_000, true)
            assertEquals(listOf(ShizukuConfirmationOutcome.TIMED_OUT), outcomes)
        }
    }

    @Test fun `allow delay and overlay permission are both enforced`() {
        val outcomes = mutableListOf<ShizukuConfirmationOutcome>()
        val confirmation = ShizukuConfirmation(3_000, 10_000) { outcomes.add(it) }
        confirmation.choose(true, 2_999, true)
        assertFalse(confirmation.isFinished)
        confirmation.choose(true, 3_000, true)
        assertEquals(listOf(ShizukuConfirmationOutcome.ALLOWED), outcomes)

        outcomes.clear()
        val revoked = ShizukuConfirmation(3_000, 10_000) { outcomes.add(it) }
        revoked.tick(2_000, false)
        revoked.choose(true, 3_000, true)
        assertEquals(listOf(ShizukuConfirmationOutcome.PERMISSION_MISSING), outcomes)
    }

    @Test fun `dismissal is cancellation, not a user denial or permission grant`() {
        val outcomes = mutableListOf<ShizukuConfirmationOutcome>()
        val confirmation = ShizukuConfirmation(3_000, 10_000) { outcomes.add(it) }
        confirmation.finish(ShizukuConfirmationOutcome.CANCELLED)
        confirmation.tick(10_000, true)
        confirmation.choose(true, 4_000, true)
        assertEquals(listOf(ShizukuConfirmationOutcome.CANCELLED), outcomes)
    }
}
