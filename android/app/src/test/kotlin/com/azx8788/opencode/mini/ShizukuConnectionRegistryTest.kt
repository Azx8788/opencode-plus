package com.azx8788.opencode.mini

import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class ShizukuConnectionRegistryTest {
    @Test
    fun `late old callbacks cannot detach the newer shared SDK connection`() {
        val registry = ShizukuConnectionRegistry<Any>()
        val old = Any()
        val current = Any()
        registry.install(1, old)
        assertSame(old, registry.takeCurrent()!!.connection)

        registry.install(2, current)
        assertFalse(registry.isCurrent(1, old))
        assertNull(registry.take(1, old))
        assertNull(registry.take(1))
        assertTrue(registry.isCurrent(2, current))
        assertSame(current, registry.take(2, current)!!.connection)
        assertFalse(registry.isCurrent(2, current))
    }
}
