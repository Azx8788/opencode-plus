package com.azx8788.opencode.mini

import android.os.IBinder
import moe.shizuku.server.IShizukuService

/** Reads live permission; a failed Binder query is unknown, never a grant or denial. */
internal object ShizukuPermissionReader {
    fun read(binder: IBinder?): Boolean? = runCatching {
        if (binder == null || !binder.pingBinder()) null
        else IShizukuService.Stub.asInterface(binder).checkSelfPermission()
    }.getOrNull()
}
