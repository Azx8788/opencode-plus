package com.azx8788.opencode.mini

import org.junit.Assert.*
import org.junit.Test

class ShizukuServiceGateTest {
    @Test fun `a cancel arriving before the Binder execute transaction prevents launch`() {
        val gate = ShizukuServiceGate()
        assertTrue(gate.cancel("late"))
        assertEquals("cancelled_before_start", gate.claim("late"))
        assertNull(gate.claim("other"))
    }
    @Test fun `finishing a command frees the slot but never its dedup claim`() {
        val gate = ShizukuServiceGate()
        assertNull(gate.claim("first"))
        assertEquals("busy", gate.claim("second"))
        gate.finish("first")
        assertEquals("duplicate_operation", gate.claim("first"))
        assertNull(gate.claim("second"))
        gate.finish("first") // A late completion cannot free another command's slot.
        assertEquals("busy", gate.claim("third"))
    }
    @Test fun `cancel after claim but before ProcessBuilder start remains observable`() {
        val gate = ShizukuServiceGate()
        assertNull(gate.claim("starting"))
        assertTrue(gate.cancel("starting"))
        assertTrue(gate.cancelled("starting"))
        gate.stop()
        assertEquals("service_stopping", gate.claim("new"))
    }
    @Test fun `capacity exhaustion fails closed instead of forgetting old IDs`() {
        val gate = ShizukuServiceGate(1)
        assertNull(gate.claim("first"))
        gate.finish("first")
        assertEquals("operation_history_full", gate.claim("second"))
        assertFalse(gate.cancel("unknown"))
        assertEquals("duplicate_operation", gate.claim("first"))
    }
}
