package com.azx8788.opencode.mini

import android.app.Application
import android.content.pm.PackageManager
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import rikka.shizuku.ShizukuProvider

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = Application::class)
class ShizukuRegistrationManifestTest {
    @Suppress("DEPRECATION")
    @Test
    fun installedManifestMeetsShizukuDiscoveryAndBinderProviderContract() {
        val context = RuntimeEnvironment.getApplication()
        val info = context.packageManager.getPackageInfo(
            context.packageName,
            PackageManager.GET_PERMISSIONS or PackageManager.GET_META_DATA or PackageManager.GET_PROVIDERS,
        )

        assertTrue(
            "Shizuku scans installed packages for API_V23",
            info.requestedPermissions?.contains(ShizukuProvider.PERMISSION) == true,
        )
        assertTrue(
            "Shizuku scans installed packages for V3_SUPPORT",
            info.applicationInfo?.metaData?.getBoolean("moe.shizuku.client.V3_SUPPORT", false) == true,
        )

        val provider = info.providers.orEmpty().singleOrNull { it.name == ShizukuProvider::class.java.name }
        assertNotNull("ShizukuProvider must be in the installed manifest", provider)
        assertEquals("${context.packageName}.shizuku", provider!!.authority)
        assertTrue(provider.exported)
        assertFalse(provider.multiprocess)
        assertEquals("android.permission.INTERACT_ACROSS_USERS_FULL", provider.readPermission)
        assertEquals("android.permission.INTERACT_ACROSS_USERS_FULL", provider.writePermission)
    }
}
