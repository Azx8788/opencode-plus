package com.azx8788.opencode.mini.shizuku

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AuthorizationRequestTest {

    private fun granted(at: Long = 0) =
        AuthorizationReading(AuthorizationState.GRANTED, AuthorizationEvidence.SERVER, null, at)

    private fun denied(at: Long = 0) =
        AuthorizationReading(AuthorizationState.DENIED, AuthorizationEvidence.SERVER, null, at)

    private fun unknown(at: Long = 0) = AuthorizationReading.unknown("binder_absent", at)

    @Test
    fun `a request is never issued twice and a stale code cannot answer it`() {
        val request = AuthorizationRequest()
        val epoch = request.begin(7412, 0)!!
        assertNull(request.begin(7413, 10))
        assertEquals(RequestPhase.PENDING, request.status().phase)
        assertEquals(7412, request.status().requestCode)

        assertFalse(request.deliver(7411, true))
        assertEquals(RequestPhase.PENDING, request.status().phase)

        assertTrue(request.deliver(7412, true))
        assertEquals(RequestPhase.GRANTED, request.status().phase)
        assertNull(request.status().reason)
        assertFalse(request.pending())
    }

    @Test
    fun `a denial is the persons answer and a missing callback is not a denial`() {
        val request = AuthorizationRequest()
        request.begin(7412, 0)
        assertTrue(request.deliver(7412, false))
        assertEquals(RequestPhase.DENIED, request.status().phase)
        assertEquals("permission_denied", request.status().reason)
        assertFalse(request.deliver(7412, true))

        val other = AuthorizationRequest()
        val epoch = other.begin(7413, 0)!!
        assertTrue(other.expire(epoch, unknown(30_000)))
        assertEquals(RequestPhase.UNCONFIRMED, other.status().phase)
        assertEquals("callback_missing", other.status().reason)
    }

    @Test
    fun `a grant the server confirms after the deadline is accepted`() {
        val request = AuthorizationRequest()
        val epoch = request.begin(7412, 0)!!
        assertTrue(request.expire(epoch, granted(30_000)))
        assertEquals(RequestPhase.GRANTED, request.status().phase)
        assertNull(request.status().reason)
    }

    @Test
    fun `a late callback from an expired request cannot finish the next one`() {
        val request = AuthorizationRequest(minIntervalMs = 0)
        val first = request.begin(7412, 0)!!
        assertTrue(request.expire(first, denied(30_000)))
        assertEquals(RequestPhase.DENIED, request.status().phase)

        val second = request.begin(7413, 31_000)!!
        assertTrue(second > first)
        assertFalse(request.deliver(7412, true))
        assertEquals(RequestPhase.PENDING, request.status().phase)
        assertTrue(request.deliver(7413, true))
        assertEquals(RequestPhase.GRANTED, request.status().phase)
    }

    @Test
    fun `a binder change ends the wait instead of leaving it pending`() {
        val request = AuthorizationRequest()
        request.begin(7412, 0)
        request.interrupt("binder_changed")
        assertEquals(RequestPhase.INTERRUPTED, request.status().phase)
        assertEquals("binder_changed", request.status().reason)
        assertFalse(request.deliver(7412, true))
        assertFalse(request.pending())
    }

    @Test
    fun `a failed call is unavailable and not a denial`() {
        val request = AuthorizationRequest()
        val epoch = request.begin(7412, 0)!!
        assertTrue(request.failed(epoch, 7412, "no_client_record"))
        assertEquals(RequestPhase.UNAVAILABLE, request.status().phase)
        assertEquals("no_client_record", request.status().reason)
        assertNull(request.status().requestCode)
        assertFalse(request.failed(epoch, 7412, "again"))
    }

    @Test
    fun `the live answer decides the recorded phase`() {
        val request = AuthorizationRequest()
        request.sync(granted())
        assertEquals(RequestPhase.GRANTED, request.status().phase)

        request.sync(denied())
        assertEquals(RequestPhase.IDLE, request.status().phase)
        assertEquals("permission_revoked", request.status().reason)

        request.sync(unknown())
        assertEquals(RequestPhase.IDLE, request.status().phase)
    }

    @Test
    fun `preconditions refuse a call before it is issued`() {
        val request = AuthorizationRequest(minIntervalMs = 1_500, maxAttempts = 2)
        request.begin(1, 0)
        assertEquals("request_already_pending", request.refusal(0))
        request.deliver(1, false)
        assertEquals("request_too_soon", request.refusal(1_000))
        request.begin(2, 2_000)
        request.deliver(2, false)
        assertEquals("too_many_attempts", request.refusal(9_000))
        request.reset()
        assertNull(request.refusal(9_000))
    }
}
