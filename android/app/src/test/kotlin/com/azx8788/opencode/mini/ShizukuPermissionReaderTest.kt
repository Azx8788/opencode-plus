package com.azx8788.opencode.mini

import android.app.Application
import android.os.Binder
import android.os.RemoteException
import java.lang.reflect.Proxy
import moe.shizuku.server.IShizukuService
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [31], manifest = Config.NONE, application = Application::class)
class ShizukuPermissionReaderTest {
    private fun binder(read: () -> Boolean): Binder {
        val binder = Binder()
        val api = Proxy.newProxyInstance(
            IShizukuService::class.java.classLoader,
            arrayOf(IShizukuService::class.java),
        ) { _, method, _ ->
            when (method.name) {
                "checkSelfPermission" -> read()
                "asBinder" -> binder
                else -> error("Unexpected server method: ${method.name}")
            }
        } as IShizukuService
        binder.attachInterface(api, "moe.shizuku.server.IShizukuService")
        return binder
    }

    @Test fun liveGrantThenRevocationNeverReusesTheEarlierGrant() {
        var allowed = true
        var reads = 0
        val server = binder { reads++; allowed }
        assertEquals(true, ShizukuPermissionReader.read(server))
        allowed = false
        assertEquals(false, ShizukuPermissionReader.read(server))
        assertEquals(2, reads)
    }

    @Test fun unavailableOrFailingServerIsUnknown() {
        assertNull(ShizukuPermissionReader.read(null))
        assertNull(ShizukuPermissionReader.read(binder { throw RemoteException("unavailable") }))
    }
}
