package com.azx8788.opencode.mini.shizuku

import org.json.JSONObject

/**
 * The facts a Shizuku integration needs, kept apart on purpose.
 *
 * A single "authorized" boolean cannot express the difference between "the
 * manager is not installed", "the binder is gone", "the server did not answer"
 * and "the person said no". Each of those needs a different remedy, so each is
 * its own value here and the UI shows all of them.
 */
internal object ShizukuContract {
    /** Bumped when the JSON shape changes; Dart rejects an unknown version. */
    const val VERSION = 2

    /** Native <-> Ubuntu socket protocol, unchanged by the status contract. */
    const val BRIDGE_PROTOCOL = 1

    /** Handshake version of the app's own UserService AIDL. */
    const val SERVICE_VERSION = 4
}

internal enum class ManagerState(val wire: String) {
    INSTALLED("installed"),
    NOT_INSTALLED("not_installed"),
    UNKNOWN("unknown"),
}

internal enum class BinderState(val wire: String) {
    ABSENT("absent"),
    ALIVE("alive"),
    DEAD("dead"),
}

internal enum class ProviderKind(val wire: String) {
    SHIZUKU("shizuku"),
    SUI("sui"),
    UNKNOWN("unknown"),
}

/**
 * Three outcomes, not two. [UNKNOWN] is the answer whenever the server could
 * not be asked, because "I could not check" must never be shown as "allowed".
 */
internal enum class AuthorizationState(val wire: String) {
    GRANTED("granted"),
    DENIED("denied"),
    UNKNOWN("unknown"),
}

internal enum class AuthorizationEvidence(val wire: String) {
    /** A live answer from the running Shizuku/Sui server. */
    SERVER("server"),
    /** The SDK answered, but its in-process cache may predate a revocation. */
    SDK_CACHE("sdk_cache"),
    /** Nothing answered. */
    NONE("none"),
}

internal enum class RequestPhase(val wire: String) {
    /** Nothing was asked in this process yet. */
    IDLE("idle"),
    /** Asked, no decision delivered yet. */
    PENDING("pending"),
    GRANTED("granted"),
    DENIED("denied"),
    /** The request could not be issued at all (no binder, no client record). */
    UNAVAILABLE("unavailable"),
    /** Issued, but no callback arrived and the live query does not confirm a grant. */
    UNCONFIRMED("unconfirmed"),
    /** A binder change or a disabled feature ended the wait. */
    INTERRUPTED("interrupted"),
}

internal enum class SessionPhase(val wire: String) {
    STOPPED("stopped"),
    BINDING("binding"),
    HANDSHAKING("handshaking"),
    READY("ready"),
    FAILED("failed"),
}

internal data class AuthorizationReading(
    val state: AuthorizationState,
    val evidence: AuthorizationEvidence,
    val reason: String?,
    val observedAt: Long,
) {
    val grantsExecution: Boolean
        get() = state == AuthorizationState.GRANTED && evidence == AuthorizationEvidence.SERVER

    companion object {
        fun unknown(reason: String, at: Long) =
            AuthorizationReading(AuthorizationState.UNKNOWN, AuthorizationEvidence.NONE, reason, at)
    }
}

/** What the installed package declares; the manager's list is built from exactly this. */
internal data class Registration(
    val applicationId: String,
    val permissionDeclared: Boolean,
    val v3Support: Boolean,
    val providerConfigured: Boolean,
    val providerAuthority: String?,
) {
    /**
     * Whether the manager's own list can contain this package. It is exactly
     * the filter in ShizukuService.getApplications: the V3_SUPPORT meta-data
     * and the API_V23 permission. The provider is not part of that filter, so
     * it is reported separately.
     */
    val listed: Boolean get() = permissionDeclared && v3Support
}

/** Live server identity, read from the server itself, not from a cached field. */
internal data class ServerIdentity(
    val uid: Int?,
    val apiVersion: Int?,
    val patchVersion: Int?,
    val selinuxContext: String?,
) {
    val backend: String
        get() = when (uid) {
            0 -> "root"
            2000 -> "adb"
            else -> "unknown"
        }

    val supported: Boolean get() = uid != null && uid in SUPPORTED_UIDS && apiVersion != null && apiVersion >= MIN_API

    companion object {
        val SUPPORTED_UIDS = setOf(0, 2000)
        const val MIN_API = 13
        val EMPTY = ServerIdentity(null, null, null, null)
    }
}

internal data class RequestStatus(
    val phase: RequestPhase,
    val reason: String?,
    val requestCode: Int?,
    val attempts: Int,
    val startedAt: Long?,
) {
    companion object {
        val IDLE = RequestStatus(RequestPhase.IDLE, null, null, 0, null)
    }
}

internal data class SessionStatus(
    val phase: SessionPhase,
    val reason: String?,
    val instance: String?,
    val uid: Int?,
    val serviceVersion: Int?,
) {
    companion object {
        val STOPPED = SessionStatus(SessionPhase.STOPPED, null, null, null, null)
    }
}

/**
 * One immutable view of everything, assembled on the controller's single
 * thread. Every consumer (channels, AI bridge, settings page) reads this, so
 * there is exactly one answer to "can this phone run a command right now".
 */
internal data class ShizukuSnapshot(
    val observedAt: Long,
    val featureEnabled: Boolean,
    val manager: ManagerState,
    val registration: Registration,
    val binder: BinderState,
    val binderGeneration: Long,
    val provider: ProviderKind,
    val authorization: AuthorizationReading,
    val request: RequestStatus,
    val identity: ServerIdentity,
    val session: SessionStatus,
    val storageReady: Boolean,
    val storageReason: String?,
    val bridgeReady: Boolean,
    val bridgeReason: String?,
    val overlayAllowed: Boolean,
) {
    /**
     * The first unmet condition, in the order a person can act on it. It is a
     * convenience for the UI; the individual facts stay visible.
     */
    val blockedBy: String?
        get() = when {
            !featureEnabled -> "feature_disabled"
            binder == BinderState.ABSENT -> "shizuku_not_running"
            binder == BinderState.DEAD -> "shizuku_binder_dead"
            !registration.listed -> "app_not_listed"
            !registration.providerConfigured -> "provider_misconfigured"
            request.phase == RequestPhase.PENDING -> "authorization_pending"
            authorization.state == AuthorizationState.UNKNOWN -> "authorization_unknown"
            authorization.state == AuthorizationState.DENIED -> "authorization_denied"
            !identity.supported -> "identity_unsupported"
            !storageReady -> "operation_storage_unavailable"
            session.phase != SessionPhase.READY -> "user_service_not_ready"
            else -> null
        }

    /** Execution needs every fact, not a remembered one. */
    val executionAdmitted: Boolean
        get() = blockedBy == null && authorization.grantsExecution && session.phase == SessionPhase.READY

    fun toJson(): JSONObject = JSONObject()
        .put("contractVersion", ShizukuContract.VERSION)
        .put("observedAt", observedAt)
        .put("feature", JSONObject().put("enabled", featureEnabled))
        .put("manager", JSONObject().put("state", manager.wire))
        .put(
            "registration",
            JSONObject()
                .put("applicationId", registration.applicationId)
                .put("listed", registration.listed)
                .put("permissionDeclared", registration.permissionDeclared)
                .put("v3Support", registration.v3Support)
                .put("providerConfigured", registration.providerConfigured)
                .put("providerAuthority", registration.providerAuthority ?: JSONObject.NULL),
        )
        .put(
            "binder",
            JSONObject()
                .put("state", binder.wire)
                .put("generation", binderGeneration)
                .put("provider", provider.wire),
        )
        .put(
            "authorization",
            JSONObject()
                .put("state", authorization.state.wire)
                .put("evidence", authorization.evidence.wire)
                .put("reason", authorization.reason ?: JSONObject.NULL)
                .put("observedAt", authorization.observedAt)
                .put("ageMs", (observedAt - authorization.observedAt).coerceAtLeast(0)),
        )
        .put(
            "request",
            JSONObject()
                .put("phase", request.phase.wire)
                .put("reason", request.reason ?: JSONObject.NULL)
                .put("requestCode", request.requestCode ?: JSONObject.NULL)
                .put("attempts", request.attempts)
                .put("startedAt", request.startedAt ?: JSONObject.NULL),
        )
        .put(
            "identity",
            JSONObject()
                .put("uid", identity.uid ?: JSONObject.NULL)
                .put("backend", identity.backend)
                .put("apiVersion", identity.apiVersion ?: JSONObject.NULL)
                .put("patchVersion", identity.patchVersion ?: JSONObject.NULL)
                .put("selinuxContext", identity.selinuxContext ?: JSONObject.NULL)
                .put("supported", identity.supported),
        )
        .put(
            "session",
            JSONObject()
                .put("phase", session.phase.wire)
                .put("reason", session.reason ?: JSONObject.NULL)
                .put("instance", session.instance ?: JSONObject.NULL)
                .put("uid", session.uid ?: JSONObject.NULL)
                .put("serviceVersion", session.serviceVersion ?: JSONObject.NULL)
                .put("protocolVersion", ShizukuContract.SERVICE_VERSION),
        )
        .put("storage", JSONObject().put("ready", storageReady).put("reason", storageReason ?: JSONObject.NULL))
        .put("bridge", JSONObject().put("ready", bridgeReady).put("reason", bridgeReason ?: JSONObject.NULL))
        .put("overlay", JSONObject().put("allowed", overlayAllowed))
        .put(
            "execution",
            JSONObject().put("admitted", executionAdmitted).put("blockedBy", blockedBy ?: JSONObject.NULL),
        )
}
