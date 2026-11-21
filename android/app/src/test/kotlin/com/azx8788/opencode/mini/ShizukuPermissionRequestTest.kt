package com.azx8788.opencode.mini

import org.junit.Assert.*
import org.junit.Test

class ShizukuPermissionRequestTest {
    @Test fun `a request waits for the server and a late answer cannot overwrite a new one`() {
        val request = ShizukuPermissionRequest()
        val first = request.begin(7412)!!
        assertNull(request.begin(7413)) // the same request is never issued twice
        assertEquals(7412, request.snapshot().requestCode)
        assertEquals("requesting", request.snapshot().state)
        assertTrue(request.deliver(7412, true))
        assertEquals("granted", request.snapshot().state)
        assertNull(request.snapshot().reason)
        assertEquals(true, request.snapshot().granted)

        val second = request.begin(7413)!!
        assertTrue(second > first)
        assertEquals(7413, request.snapshot().requestCode)
        assertEquals("requesting", request.snapshot().state)
        assertNull(request.snapshot().granted)
    }

    @Test fun `a denial is the person's answer and not a missing callback`() {
        val request = ShizukuPermissionRequest()
        request.begin(7412)
        assertTrue(request.deliver(7412, false))
        assertEquals("denied", request.snapshot().state)
        assertEquals("permission_denied", request.snapshot().reason)
        assertEquals(false, request.snapshot().granted)
        // A later answer for the finished request is not a second result.
        assertFalse(request.deliver(7412, true))
        assertEquals("denied", request.snapshot().state)
    }

    @Test fun `a stale callback from a timed out request cannot finish its retry`() {
        val request = ShizukuPermissionRequest()
        val first = request.begin(7412)!!
        assertTrue(request.expire(first, false))
        val second = request.begin(7413)!!

        assertFalse(request.deliver(7412, true))
        assertEquals("requesting", request.snapshot().state)
        assertEquals(7413, request.snapshot().requestCode)
        assertTrue(request.deliver(7413, true))
        assertEquals("granted", request.snapshot().state)
    }

    @Test fun `a delayed request failure cannot fail a newer request`() {
        val request = ShizukuPermissionRequest()
        val first = request.begin(7412)!!
        assertTrue(request.expire(first, false))
        request.begin(7413)

        assertFalse(request.failed(first, 7412, "permission_request_failed"))
        assertEquals("requesting", request.snapshot().state)
        assertEquals(7413, request.snapshot().requestCode)
    }

    @Test fun `a missing callback is reported as unconfirmed and can be asked again`() {
        val request = ShizukuPermissionRequest()
        val epoch = request.begin(7412)!!
        assertTrue(request.expire(epoch, false))
        assertEquals("unconfirmed", request.snapshot().state)
        assertEquals("permission_callback_missing", request.snapshot().reason)
        assertNull(request.snapshot().granted)
        assertNotNull(request.begin(7413)) // the person is not blocked from asking again
        assertFalse(request.expire(epoch, true)) // an old deadline cannot grant anything
    }

    @Test fun `a grant the server already holds survives a lost callback`() {
        val request = ShizukuPermissionRequest()
        val epoch = request.begin(7412)!!
        assertTrue(request.expire(epoch, true))
        assertEquals("granted", request.snapshot().state)
        assertNull(request.snapshot().reason)
    }

    @Test fun `a Binder replacement ends a pending request instead of blocking binding`() {
        val request = ShizukuPermissionRequest()
        val epoch = request.begin(7412)!!
        request.interrupt("binder_replaced")
        assertEquals("interrupted", request.snapshot().state)
        assertEquals("binder_replaced", request.snapshot().reason)
        assertFalse(request.deliver(7412, true)) // the dialog is gone; its answer means nothing here
        assertFalse(request.expire(epoch, true))
        assertNotNull(request.begin(7413))
    }

    @Test fun `an unavailable request is never inferred as granted`() {
        val request = ShizukuPermissionRequest()
        request.unavailable("shizuku_not_running")
        assertEquals("unavailable", request.snapshot().state)
        assertNull(request.snapshot().granted)
        assertEquals("shizuku_not_running", request.snapshot().reason)
    }

    @Test fun `a revocation in the manager list is reported and grants are not re-reported`() {
        val request = ShizukuPermissionRequest()
        assertFalse(request.sync(false))
        request.begin(7412)
        request.deliver(7412, true)
        assertFalse(request.sync(true))
        assertTrue(request.sync(false))
        assertEquals("not_requested", request.snapshot().state)
        assertEquals("permission_revoked", request.snapshot().reason)
        assertNull(request.snapshot().granted)
        assertFalse(request.sync(false))
    }
}
