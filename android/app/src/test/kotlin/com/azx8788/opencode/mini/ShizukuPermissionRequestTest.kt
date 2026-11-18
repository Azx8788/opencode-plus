package com.azx8788.opencode.mini

import org.junit.Assert.*
import org.junit.Test

class ShizukuPermissionRequestTest {
    @Test fun `a request waits for the server and a late answer cannot overwrite a new one`() {
        val request = ShizukuPermissionRequest()
        val first = request.begin()!!
        assertNull(request.begin()) // the same request is never issued twice
        assertEquals("requesting", request.snapshot().state)
        assertTrue(request.deliver(true))
        assertEquals("granted", request.snapshot().state)
        assertNull(request.snapshot().reason)
        assertEquals(true, request.snapshot().granted)

        val second = request.begin()!!
        assertTrue(second > first)
        assertEquals("requesting", request.snapshot().state)
        assertNull(request.snapshot().granted)
    }

    @Test fun `a denial is the person's answer and not a missing callback`() {
        val request = ShizukuPermissionRequest()
        request.begin()
        assertTrue(request.deliver(false))
        assertEquals("denied", request.snapshot().state)
        assertEquals("permission_denied", request.snapshot().reason)
        assertEquals(false, request.snapshot().granted)
        // A later answer for the finished request is not a second result.
        assertFalse(request.deliver(true))
        assertEquals("denied", request.snapshot().state)
    }

    @Test fun `a missing callback is reported as unconfirmed and can be asked again`() {
        val request = ShizukuPermissionRequest()
        val epoch = request.begin()!!
        assertTrue(request.expire(epoch, false))
        assertEquals("unconfirmed", request.snapshot().state)
        assertEquals("permission_callback_missing", request.snapshot().reason)
        assertNull(request.snapshot().granted)
        assertNotNull(request.begin()) // the person is not blocked from asking again
        assertFalse(request.expire(epoch, true)) // an old deadline cannot grant anything
    }

    @Test fun `a grant the server already holds survives a lost callback`() {
        val request = ShizukuPermissionRequest()
        val epoch = request.begin()!!
        assertTrue(request.expire(epoch, true))
        assertEquals("granted", request.snapshot().state)
        assertNull(request.snapshot().reason)
    }

    @Test fun `a Binder replacement ends a pending request instead of blocking binding`() {
        val request = ShizukuPermissionRequest()
        val epoch = request.begin()!!
        request.interrupt("binder_replaced")
        assertEquals("interrupted", request.snapshot().state)
        assertEquals("binder_replaced", request.snapshot().reason)
        assertFalse(request.deliver(true)) // the dialog is gone; its answer means nothing here
        assertFalse(request.expire(epoch, true))
        assertNotNull(request.begin())
    }

    @Test fun `an unattempted request is never inferred from a cached value`() {
        val request = ShizukuPermissionRequest()
        request.unavailable("sui_managed_authorization")
        assertEquals("unavailable", request.snapshot().state)
        assertNull(request.snapshot().granted)
        assertEquals("sui_managed_authorization", request.snapshot().reason)
    }

    @Test fun `a revocation in the manager list is reported and grants are not re-reported`() {
        val request = ShizukuPermissionRequest()
        assertFalse(request.sync(false))
        request.begin()
        request.deliver(true)
        assertFalse(request.sync(true))
        assertTrue(request.sync(false))
        assertEquals("not_requested", request.snapshot().state)
        assertEquals("permission_revoked", request.snapshot().reason)
        assertNull(request.snapshot().granted)
        assertFalse(request.sync(false))
    }
}
