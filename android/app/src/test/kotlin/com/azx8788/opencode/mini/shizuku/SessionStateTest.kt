package com.azx8788.opencode.mini.shizuku

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SessionStateTest {

    @Test
    fun `a silent bind expires and a later attempt gets a fresh epoch`() {
        var clock = 0L
        val session = SessionState({ clock })
        val first = session.begin()!!
        assertNull(session.begin())
        assertEquals(SessionPhase.BINDING, session.status().phase)

        clock = 10_000
        assertTrue(session.expire(first))
        assertEquals(SessionPhase.FAILED, session.status().phase)
        assertEquals("bind_timeout", session.status().reason)

        val next = session.begin()!!
        assertTrue(next > first)
        assertEquals(SessionPhase.BINDING, session.status().phase)
        assertFalse(session.connected(first, "old", 2000, ShizukuContract.SERVICE_VERSION))
        assertTrue(session.connected(next, "live", 2000, ShizukuContract.SERVICE_VERSION))
        assertNull(session.status().reason)
        assertEquals("live", session.readyInstance())
    }

    @Test
    fun `receiving a binder is not readiness and a stuck handshake also expires`() {
        var clock = 0L
        val session = SessionState({ clock })
        val epoch = session.begin()!!
        assertTrue(session.handshaking(epoch))
        assertNull(session.readyInstance())
        assertEquals(SessionPhase.HANDSHAKING, session.status().phase)

        clock = 5_001
        assertTrue(session.expire(epoch))
        assertEquals("handshake_timeout", session.status().reason)
        assertNull(session.readyInstance())
    }

    @Test
    fun `a service that is not the expected one is refused`() {
        val session = SessionState({ 0L })
        val epoch = session.begin()!!
        assertFalse(session.connected(epoch, "svc", 10123, ShizukuContract.SERVICE_VERSION))
        assertEquals("handshake_mismatch", session.status().reason)

        val second = session.begin()!!
        assertFalse(session.connected(second, "svc", 2000, ShizukuContract.SERVICE_VERSION + 1))
        assertEquals("handshake_mismatch", session.status().reason)

        val third = session.begin()!!
        assertFalse(session.connected(third, "  ", 2000, ShizukuContract.SERVICE_VERSION))
        assertEquals("handshake_mismatch", session.status().reason)
    }

    @Test
    fun `a disconnect after ready is reported and readiness is dropped`() {
        val session = SessionState({ 0L })
        val epoch = session.begin()!!
        session.handshaking(epoch)
        assertTrue(session.connected(epoch, "svc", 2000, ShizukuContract.SERVICE_VERSION))
        assertEquals(2000, session.status().uid)

        session.reset("service_disconnected")
        assertEquals(SessionPhase.FAILED, session.status().phase)
        assertEquals("service_disconnected", session.status().reason)
        assertNull(session.readyInstance())
        assertNull(session.status().uid)
    }

    @Test
    fun `a late failure from an old attempt cannot overwrite a ready session`() {
        val session = SessionState({ 0L })
        val old = session.begin()!!
        session.reset(null)
        val fresh = session.begin()!!
        assertTrue(session.connected(fresh, "live", 2000, ShizukuContract.SERVICE_VERSION))

        assertFalse(session.fail(old, "late_disconnect"))
        assertEquals(SessionPhase.READY, session.status().phase)
        assertEquals("live", session.readyInstance())
    }
}
