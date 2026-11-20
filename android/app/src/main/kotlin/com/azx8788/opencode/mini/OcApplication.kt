package com.azx8788.opencode.mini

import android.app.Application
import com.azx8788.opencode.mini.shizuku.ShizukuRuntime

/** Installed before activities/services so foreground service failures survive. */
class OcApplication : Application() {
    override fun onCreate() {
        try { NativeCrashStore(filesDir).install() } catch (_: Throwable) { }
        super.onCreate()
        ShizukuRuntime.initialize(this)
    }
}
