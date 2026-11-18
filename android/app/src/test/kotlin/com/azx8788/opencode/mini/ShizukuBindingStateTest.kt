package com.azx8788.opencode.mini

import org.junit.Assert.*
import org.junit.Test

class ShizukuBindingStateTest {
    @Test fun `a silent bind expires and a later request gets a fresh epoch`() {
        var clock = 0L
        val state = ShizukuBindingState<String>({ clock })
        val old = state.begin()!!
        assertNull(state.begin())
        clock = 10_000
        assertTrue(state.expire(old))
        assertEquals("bind_timeout", state.snapshot().reason)
        val next = state.begin()!!
        assertTrue(next > old)
        assertFalse(state.connected(old, "obsolete", "old-instance", 2000))
        assertTrue(state.verifying(next))
        assertTrue(state.connected(next, "live", "new-instance", 2000))
        assertFalse(state.fail(old, "late_disconnect"))
        assertEquals("live", state.snapshot().ready!!.service)
    }

    @Test fun `binder arrival alone is not readiness and a stuck handshake also expires`() {
        var clock = 0L
        val state = ShizukuBindingState<String>({ clock })
        val epoch = state.begin()!!
        assertTrue(state.verifying(epoch))
        assertNull(state.snapshot().ready)
        clock = 10_001
        assertFalse(state.connected(epoch, "late", "instance", 0))
        assertEquals("handshake_timeout", state.snapshot().reason)
        assertNotNull(state.begin())
    }

    @Test fun `unknown UID is not guessed from authorization and reset invalidates every callback`() {
        val state = ShizukuBindingState<String>({ 0L })
        val first = state.begin()!!
        assertFalse(state.connected(first, "wrong-uid", "instance", 10001))
        assertNull(state.snapshot().ready)
        val next = state.begin()!!
        state.reset("feature_disabled")
        assertFalse(state.connected(next, "late", "instance", 0))
        assertFalse(state.expire(next))
        assertNull(state.snapshot().ready)
    }

    @Test fun `both actual Android identities can complete the same handshake`() {
        for (uid in listOf(0, 2000)) {
            val state = ShizukuBindingState<String>({ 0L })
            val epoch = state.begin()!!
            assertTrue(state.connected(epoch, "service", "instance-$uid", uid))
            assertEquals(uid, state.snapshot().ready!!.uid)
            assertNull(state.begin())
        }
    }
}
