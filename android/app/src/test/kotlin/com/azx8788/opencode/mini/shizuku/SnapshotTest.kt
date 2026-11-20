package com.azx8788.opencode.mini.shizuku

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SnapshotTest {

    private fun reading(state: AuthorizationState, evidence: AuthorizationEvidence = AuthorizationEvidence.SERVER) =
        AuthorizationReading(state, evidence, null, 1_000)

    private fun snapshot(
        feature: Boolean = true,
        manager: ManagerState = ManagerState.INSTALLED,
        registration: Registration = Registration("com.azx8788.opencode.mini", true, true, true, "com.azx8788.opencode.mini.shizuku"),
        binder: BinderState = BinderState.ALIVE,
        authorization: AuthorizationReading = reading(AuthorizationState.GRANTED),
        request: RequestStatus = RequestStatus.IDLE,
        identity: ServerIdentity = ServerIdentity(2000, 13, 6, "u:r:shell:s0"),
        session: SessionStatus = SessionStatus(SessionPhase.READY, null, "svc", 2000, ShizukuContract.SERVICE_VERSION),
        storage: Boolean = true,
        bridge: Boolean = true,
    ) = ShizukuSnapshot(
        observedAt = 2_000,
        featureEnabled = feature,
        manager = manager,
        registration = registration,
        binder = binder,
        binderGeneration = 1,
        provider = ProviderKind.SHIZUKU,
        authorization = authorization,
        request = request,
        identity = identity,
        session = session,
        storageReady = storage,
        storageReason = if (storage) null else "journal_unavailable",
        bridgeReady = bridge,
        bridgeReason = if (bridge) null else "socket_closed",
        overlayAllowed = true,
    )

    @Test
    fun `execution needs every fact at once`() {
        assertTrue(snapshot().executionAdmitted)
        assertNull(snapshot().blockedBy)
    }

    @Test
    fun `each missing fact is named on its own`() {
        assertEquals("feature_disabled", snapshot(feature = false).blockedBy)
        assertEquals("app_not_listed", snapshot(registration = Registration("p", false, true, true, null)).blockedBy)
        assertEquals("provider_misconfigured", snapshot(registration = Registration("p", true, true, false, null)).blockedBy)
        assertEquals("shizuku_not_running", snapshot(binder = BinderState.ABSENT).blockedBy)
        assertEquals("shizuku_binder_dead", snapshot(binder = BinderState.DEAD).blockedBy)
        assertEquals(
            "authorization_unknown",
            snapshot(authorization = AuthorizationReading.unknown("server_unreachable", 1_000)).blockedBy,
        )
        assertEquals("authorization_denied", snapshot(authorization = reading(AuthorizationState.DENIED)).blockedBy)
        assertEquals(
            "authorization_pending",
            snapshot(request = RequestStatus(RequestPhase.PENDING, null, 7412, 1, 1_000)).blockedBy,
        )
        assertEquals("identity_unsupported", snapshot(identity = ServerIdentity(10123, 13, 6, null)).blockedBy)
        assertEquals("identity_unsupported", snapshot(identity = ServerIdentity(2000, 12, 0, null)).blockedBy)
        assertEquals("operation_storage_unavailable", snapshot(storage = false).blockedBy)
        assertEquals("user_service_not_ready", snapshot(session = SessionStatus.STOPPED).blockedBy)
    }

    @Test
    fun `a cached sdk answer is never enough to admit a command`() {
        val cached = snapshot(authorization = reading(AuthorizationState.GRANTED, AuthorizationEvidence.SDK_CACHE))
        assertFalse(cached.authorization.grantsExecution)
        assertFalse(cached.executionAdmitted)
    }

    @Test
    fun `the list condition is the managers own filter and excludes the provider`() {
        assertTrue(Registration("p", true, true, false, null).listed)
        assertFalse(Registration("p", false, true, true, null).listed)
        assertFalse(Registration("p", true, false, true, null).listed)
        assertFalse(Registration("p", false, false, false, null).listed)
    }

    @Test
    fun `the json contract keeps the facts apart`() {
        val json = snapshot().toJson()
        assertEquals(ShizukuContract.VERSION, json.getInt("contractVersion"))
        assertEquals("installed", json.getJSONObject("manager").getString("state"))
        assertEquals("granted", json.getJSONObject("authorization").getString("state"))
        assertEquals("server", json.getJSONObject("authorization").getString("evidence"))
        assertEquals("alive", json.getJSONObject("binder").getString("state"))
        assertEquals("shizuku", json.getJSONObject("binder").getString("provider"))
        assertEquals("adb", json.getJSONObject("identity").getString("backend"))
        assertEquals(2000, json.getJSONObject("identity").getInt("uid"))
        assertEquals("ready", json.getJSONObject("session").getString("phase"))
        assertEquals(ShizukuContract.SERVICE_VERSION, json.getJSONObject("session").getInt("protocolVersion"))
        assertTrue(json.getJSONObject("registration").getBoolean("listed"))
        assertTrue(json.getJSONObject("storage").getBoolean("ready"))
        assertTrue(json.getJSONObject("bridge").getBoolean("ready"))
        assertTrue(json.getJSONObject("execution").getBoolean("admitted"))
        assertTrue(json.getJSONObject("execution").isNull("blockedBy"))
    }

    @Test
    fun `an unconfirmed authorization is not reported as granted`() {
        val json = snapshot(
            authorization = AuthorizationReading.unknown("client_not_attached", 1_000),
            request = RequestStatus(RequestPhase.UNCONFIRMED, "callback_missing", null, 1, 1_000),
        ).toJson()
        assertEquals("unknown", json.getJSONObject("authorization").getString("state"))
        assertEquals("none", json.getJSONObject("authorization").getString("evidence"))
        assertEquals("client_not_attached", json.getJSONObject("authorization").getString("reason"))
        assertEquals("unconfirmed", json.getJSONObject("request").getString("phase"))
        assertFalse(json.getJSONObject("execution").getBoolean("admitted"))
        assertEquals("authorization_unknown", json.getJSONObject("execution").getString("blockedBy"))
    }
}
