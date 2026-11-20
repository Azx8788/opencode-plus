package com.azx8788.opencode.mini.shizuku

import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.IBinder
import moe.shizuku.server.IShizukuService
import rikka.shizuku.Shizuku
import rikka.shizuku.ShizukuProvider
import rikka.sui.Sui

/**
 * Reads the environment: is a manager installed, does this package declare
 * everything the manager needs in order to list it, which provider answered.
 *
 * None of this says anything about authorization; that is [ServerAuthorizationProbe].
 */
internal class EnvironmentProbe(private val context: Context) {

    fun manager(): ManagerState = try {
        context.packageManager.getPackageInfo(MANAGER_PACKAGE, 0)
        ManagerState.INSTALLED
    } catch (_: PackageManager.NameNotFoundException) {
        ManagerState.NOT_INSTALLED
    } catch (_: Throwable) {
        ManagerState.UNKNOWN
    }

    /**
     * The manager builds its list from the package's own declarations
     * (ShizukuService.getApplications): the API_V23 permission, the
     * V3_SUPPORT meta-data and an app-scoped provider that the server can
     * call. A package missing one of them cannot appear there, so a request
     * looks like it fails and nothing is ever remembered.
     */
    fun registration(): Registration {
        val applicationId = context.packageName
        return try {
            val flags = PackageManager.GET_PERMISSIONS or PackageManager.GET_META_DATA or
                PackageManager.GET_PROVIDERS
            val info = packageInfo(applicationId, flags)
            val permissionDeclared = info.requestedPermissions?.contains(ShizukuProvider.PERMISSION) == true
            val v3 = info.applicationInfo?.metaData?.getBoolean(V3_SUPPORT, false) == true
            val provider = info.providers.orEmpty().firstOrNull { it.name == ShizukuProvider::class.java.name }
            // android:permission on a provider becomes both read and write permission.
            val guard = PROVIDER_PERMISSION
            val configured = provider != null &&
                provider.authority == "$applicationId.shizuku" &&
                provider.exported &&
                !provider.multiprocess &&
                provider.readPermission == guard &&
                provider.writePermission == guard
            Registration(applicationId, permissionDeclared, v3, configured, provider?.authority)
        } catch (_: Throwable) {
            Registration(applicationId, false, false, false, null)
        }
    }

    fun provider(): ProviderKind = try {
        if (Sui.isSui()) ProviderKind.SUI else ProviderKind.SHIZUKU
    } catch (_: Throwable) {
        ProviderKind.UNKNOWN
    }

    private fun packageInfo(name: String, flags: Int) =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.packageManager.getPackageInfo(name, PackageManager.PackageInfoFlags.of(flags.toLong()))
        } else {
            @Suppress("DEPRECATION")
            context.packageManager.getPackageInfo(name, flags)
        }

    companion object {
        const val MANAGER_PACKAGE = "moe.shizuku.privileged.api"
        const val V3_SUPPORT = "moe.shizuku.client.V3_SUPPORT"
        const val PROVIDER_PERMISSION = "android.permission.INTERACT_ACROSS_USERS_FULL"
    }
}

/**
 * Asks the running server, every time, whether this process may execute.
 *
 * Why not `Shizuku.checkSelfPermission()`: the SDK stores the first `true` in a
 * static field (`permissionGranted`) and returns it for the rest of the
 * process, so a revocation made in the manager is invisible to it. Its
 * `shouldShowRequestPermissionRationale()` is likewise short-circuited by that
 * cache, and server-side it means "the entry is explicitly denied", not "not
 * granted".
 *
 * Why not `Shizuku.checkRemotePermission()`: server-side that call is
 * `PermissionManagerApis.checkPermission(permission, Os.getuid())`, i.e. it
 * checks whether the *Shizuku server* holds a permission, not the caller.
 *
 * What is used instead: transaction `checkSelfPermission` on the binder the SDK
 * already holds. The transaction id is fixed by the AIDL the SDK was built
 * from (13.1.5: explicit id 15, wire code 16), which is verified by the
 * `dev.rikka.shizuku:aidl:13.1.5` artifact this app compiles against. It is an
 * internal interface, not a documented public API, so it is gated: only server
 * API 13..[MAX_VERIFIED_API] is queried, and every failure returns UNKNOWN.
 * A server newer than that is not guessed at.
 */
internal class ServerAuthorizationProbe(
    private val binderProvider: () -> IBinder?,
    private val serverApi: () -> Int?,
) {

    fun read(now: Long): AuthorizationReading {
        val binder = try {
            binderProvider()
        } catch (_: Throwable) {
            null
        } ?: return AuthorizationReading.unknown("binder_absent", now)

        if (!ping(binder)) return AuthorizationReading.unknown("binder_dead", now)

        val api = try {
            serverApi()
        } catch (_: Throwable) {
            null
        } ?: return AuthorizationReading.unknown("server_version_unknown", now)
        if (api < 11) return AuthorizationReading.unknown("server_too_old", now)
        if (api > MAX_VERIFIED_API) return AuthorizationReading.unknown("server_newer_than_sdk", now)

        return try {
            val service = IShizukuService.Stub.asInterface(binder)
            val allowed = service.checkSelfPermission()
            AuthorizationReading(
                if (allowed) AuthorizationState.GRANTED else AuthorizationState.DENIED,
                AuthorizationEvidence.SERVER,
                null,
                now,
            )
        } catch (_: IllegalStateException) {
            // Server-side requireClient(): this process has no client record yet.
            // That is "cannot check", not "denied".
            AuthorizationReading.unknown("client_not_attached", now)
        } catch (_: SecurityException) {
            AuthorizationReading.unknown("query_rejected", now)
        } catch (_: Throwable) {
            // DeadObjectException, RemoteException, a missing transaction, ...
            AuthorizationReading.unknown("server_unreachable", now)
        }
    }

    private fun ping(binder: IBinder) = try {
        binder.pingBinder()
    } catch (_: Throwable) {
        false
    }

    companion object {
        /**
         * Highest server API whose `checkSelfPermission` transaction this build
         * has been verified against. 13.1.5 and 13.1.6 share the same explicit
         * AIDL ids; anything newer is reported as unknown instead of guessed.
         */
        const val MAX_VERIFIED_API = 14

        fun fromSdk(): ServerAuthorizationProbe = ServerAuthorizationProbe(
            { Shizuku.getBinder() },
            { try { Shizuku.getVersion().takeIf { it > 0 } } catch (_: Throwable) { null } },
        )
    }
}

/** Live server identity. Reads the server; a cached field would outlive a restart. */
internal class ServerIdentityProbe(private val binderProvider: () -> IBinder?) {

    fun read(): ServerIdentity {
        val binder = try {
            binderProvider()
        } catch (_: Throwable) {
            null
        } ?: return ServerIdentity.EMPTY
        return try {
            if (!binder.pingBinder()) return ServerIdentity.EMPTY
            val service = IShizukuService.Stub.asInterface(binder)
            val api = service.getVersion()
            if (api > ServerAuthorizationProbe.MAX_VERIFIED_API) return ServerIdentity.EMPTY
            ServerIdentity(service.getUid(), api, null, runCatching { service.getSELinuxContext() }.getOrNull())
        } catch (_: Throwable) {
            ServerIdentity.EMPTY
        }
    }
}
