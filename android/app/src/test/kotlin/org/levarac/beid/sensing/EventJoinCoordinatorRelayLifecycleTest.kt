package org.levarac.beid.sensing

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.levarac.barnard.BarnardPermissionResult
import org.levarac.barnard.BarnardPermissionStatus
import org.levarac.barnard.BarnardRelayDecision
import org.levarac.barnard.BarnardRelayDecisionEvent
import org.levarac.barnard.BarnardRelayVerification
import org.levarac.beid.persistence.BindingRecordStore
import org.levarac.beid.persistence.SelfProofRecordStore
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * When relay is on and when it is off (beid#367).
 *
 * Relay is a radio behaviour, so its lifecycle is the part a unit test can
 * actually hold: it starts only once this device may both scan and advertise
 * for an event it joined, and it stops at every exit from that state.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class EventJoinCoordinatorRelayLifecycleTest {
    @Test
    fun joiningWithFullPermissionConfiguresTheRelay() = runTest {
        val engine = FakeEventJoinEngine()
        val registry = FakeNearbyEventRegistry()
        val coordinator = coordinator(engine, registry)

        joinPromotedVectorEvent(coordinator, engine, registry)

        val verifier = assertNotNull(engine.configuredRelayVerifier)
        val verification = verifier.verify(VECTOR_ENVELOPE, VECTOR_ENIN)
            as BarnardRelayVerification.RegistryVerified
        // The signed conformance vector expires two ENINs after this clock.
        assertEquals(6_000_002L, verification.relayExpiresAtEnin)
        assertEquals(BarnardRelayVerification.Rejected, verifier.verify(VECTOR_ENVELOPE, 6_000_002L))
    }

    @Test
    fun aRefusedPermissionLeavesTheRelayOff() = runTest {
        // The fake answers the permission request inline, so the refusal has
        // to be in place before the join asks for it.
        val engine = FakeEventJoinEngine(SCAN_ONLY)
        val registry = FakeNearbyEventRegistry()
        val coordinator = coordinator(engine, registry)

        joinPromotedVectorEvent(coordinator, engine, registry)

        assertNull(
            engine.configuredRelayVerifier,
            "a device that cannot advertise cannot re-broadcast anything",
        )
    }

    @Test
    fun leavingTheEventClearsTheRelay() = runTest {
        val engine = FakeEventJoinEngine()
        val registry = FakeNearbyEventRegistry()
        val coordinator = coordinator(engine, registry)
        joinPromotedVectorEvent(coordinator, engine, registry)

        coordinator.leaveEvent()

        assertNull(engine.configuredRelayVerifier)
    }

    @Test
    fun endingTheSessionClearsTheRelay() = runTest {
        val engine = FakeEventJoinEngine()
        val registry = FakeNearbyEventRegistry()
        val coordinator = coordinator(engine, registry)
        joinPromotedVectorEvent(coordinator, engine, registry)

        coordinator.dispose()

        assertNull(engine.configuredRelayVerifier)
    }

    /**
     * The counterpart of iOS's `testResettingClearsTheRelay`: ending a
     * session's discovery leaves this device unable to relay, even though the
     * radio may still be scanning.
     *
     * The mechanism differs and the assertions say so. iOS's `reset()` calls
     * the relay teardown directly. Android has no such entry point -- leaving
     * and disposing are the two session ends, both covered above -- so
     * `stopNearbyEventDiscovery` instead clears the candidates the gate reads,
     * and the verifier stays configured while having nothing left to agree
     * about.
     *
     * Everything here is real: barnard's own conformance-vector container,
     * verified by barnard at an ENIN inside its signed window, promoted to
     * `REGISTRY_VERIFIED` through a registry answer, and offered to the
     * verifier the coordinator actually handed the engine. An earlier version
     * offered garbage bytes, which barnard refuses long before the gate is
     * consulted, so it asserted nothing about the gate and passed identically
     * before the reset.
     */
    @Test
    fun resettingClearsTheRelay() = runTest {
        val engine = FakeEventJoinEngine()
        val registry = FakeNearbyEventRegistry()
        val coordinator = coordinator(engine, registry)

        // The promotion and the join in one: a verified envelope, a registry
        // answer that agrees with it, and the joined event's canonical id,
        // which the join itself now establishes (beid#374).
        joinPromotedVectorEvent(coordinator, engine, registry)
        val verifier = assertNotNull(engine.configuredRelayVerifier)

        assertEquals(
            VECTOR_EVENT_ID_HEX,
            coordinator.relayGateJoinedEventIdHexForTesting,
            "the gate must be open before a reset can close it",
        )
        assertTrue(
            verifier.verify(VECTOR_ENVELOPE, VECTOR_ENIN) is BarnardRelayVerification.RegistryVerified,
            "the gate must agree before the reset, or this test asserts nothing",
        )

        coordinator.stopNearbyEventDiscovery()
        runCurrent()

        val refusals = mutableListOf<String>()
        assertEquals(
            BarnardRelayVerification.Rejected,
            verifier.verify(VECTOR_ENVELOPE, VECTOR_ENIN),
            "a reset leaves no candidate for the envelope to match",
        )
        // The reason, so a future change cannot satisfy this by making the
        // envelope fail for some unrelated cause.
        participantRelayVerification(
            state = ParticipantRelayGateState(
                candidates = coordinator.nearbyEventCandidates.value,
                verifiedDefinitionsByHash = emptyMap(),
                joinedEventIdHex = coordinator.relayGateJoinedEventIdHexForTesting,
            ),
            signedEnvelopeHex = VECTOR_ENVELOPE.toHex(),
            eventCodeHashHex = VECTOR_EVENT_CODE_HASH,
            eventId = VECTOR_EVENT_ID_HEX.hexBytes(),
            validFromEnin = VECTOR_VALID_FROM,
            validThroughEnin = VECTOR_VALID_THROUGH,
            relayExpiresAtEnin = 6_000_002L,
            currentEnin = VECTOR_ENIN,
            agreesWithDefinition = { true },
            reportRefusal = { refusals += it },
        )
        assertEquals(
            listOf("NOT_REGISTRY_VERIFIED"),
            refusals,
            "the refusal must come from the gate losing its candidate",
        )
    }

    /**
     * barnard drives the relay on its own timer too, so this cadence is not
     * the only thing ending a lease on time — but a host that stops calling it
     * is a host whose relay decisions are no longer tied to its own liveness.
     */
    @Test
    fun theHostRunsTheRelayForwardOnTheDecisionBoundary() = runTest {
        val engine = FakeEventJoinEngine()
        val registry = FakeNearbyEventRegistry()
        val coordinator = coordinator(engine, registry)
        joinPromotedVectorEvent(coordinator, engine, registry)

        val cadence = EventJoinCoordinator.RELAY_DECISION_BOUNDARY_MILLIS
        advanceTimeBy(cadence - 1)
        runCurrent()
        assertEquals(0, engine.advanceRelayCalls)

        advanceTimeBy(1L)
        runCurrent()
        assertEquals(1, engine.advanceRelayCalls)

        advanceTimeBy(cadence)
        runCurrent()
        assertEquals(2, engine.advanceRelayCalls)
    }

    @Test
    fun theCadenceStopsWhenTheEventIsLeft() = runTest {
        val engine = FakeEventJoinEngine()
        val registry = FakeNearbyEventRegistry()
        val coordinator = coordinator(engine, registry)
        joinPromotedVectorEvent(coordinator, engine, registry)
        advanceTimeBy(EventJoinCoordinator.RELAY_DECISION_BOUNDARY_MILLIS)
        runCurrent()

        coordinator.leaveEvent()
        advanceTimeBy(EventJoinCoordinator.RELAY_DECISION_BOUNDARY_MILLIS * 4)
        runCurrent()

        assertEquals(1, engine.advanceRelayCalls)
    }

    @Test
    fun aRelayDecisionIsSurfacedForVisibility() = runTest {
        val engine = FakeEventJoinEngine()
        val coordinator = coordinator(engine)

        coordinator.handleRelayDecision(
            BarnardRelayDecisionEvent(
                decision = BarnardRelayDecision.BROADCAST,
                payloadDigest = byteArrayOf(0x0a, 0x0b),
                hop = 1,
                reason = "elected",
            ),
        )

        val decision = assertNotNull(coordinator.lastRelayDecision)
        assertEquals(BarnardRelayDecision.BROADCAST, decision.decision)
        assertEquals("0a0b", decision.payloadDigestHex)
        assertEquals(1, decision.hop)
        assertEquals("elected", decision.reason)
    }

    private fun TestScope.coordinator(
        engine: FakeEventJoinEngine,
        nearbyRegistry: NearbyEventRegistry? = null,
    ): EventJoinCoordinator =
        EventJoinCoordinator(
            engine = engine,
            nearbyRegistry = nearbyRegistry,
            // The join gate answers with the conformance vector's own Event ID,
            // so the gate this suite exercises is opened by the same identity
            // the envelope carries -- otherwise the verifier would refuse for
            // an unrelated reason and these tests would assert nothing.
            joinRegistry = FakeEventJoinRegistry(eventIdHex = VECTOR_EVENT_ID_HEX),
            nowEpochMillis = { NearbyEventPromotionFixture.VECTOR_NOW_EPOCH_MILLIS + testScheduler.currentTime },
            coroutineScope = backgroundScope,
            sensingCryptography = FakeSensingCryptography(),
            selfProofRecordStore = SelfProofRecordStore(newTempRecordFile("relay-self-proofs")),
            bindingRecordStore = BindingRecordStore(newTempRecordFile("relay-binding-records")),
        )

    private companion object {
        // Aliases onto NearbyEventPromotionFixture rather than a second copy.
        // Two files holding the same signed conformance vector, which must
        // agree byte for byte or nothing promotes, is exactly the drift hazard
        // this round already found once.
        const val VECTOR_EVENT_ID_HEX = NearbyEventPromotionFixture.EVENT_ID_HEX
        const val VECTOR_EVENT_CODE_HASH = NearbyEventPromotionFixture.EVENT_CODE_HASH
        const val VECTOR_VALID_FROM = NearbyEventPromotionFixture.VALID_FROM_ENIN
        const val VECTOR_VALID_THROUGH = NearbyEventPromotionFixture.VALID_THROUGH_ENIN
        const val VECTOR_ENIN = NearbyEventPromotionFixture.ENIN
        val VECTOR_CONTAINER = NearbyEventPromotionFixture.CONTAINER
        val VECTOR_ENVELOPE = NearbyEventPromotionFixture.ENVELOPE

        fun String.hexBytes(): ByteArray =
            chunked(2).map { it.toInt(16).toByte() }.toByteArray()

        fun ByteArray.toHex(): String =
            joinToString("") { "%02x".format(it.toInt() and 0xff) }

        val SCAN_ONLY = permission(canScan = true, canAdvertise = false)

        fun permission(canScan: Boolean, canAdvertise: Boolean) = BarnardPermissionResult.Granted(
            BarnardPermissionStatus(
                platform = "android",
                permissions = emptyMap(),
                requiredPermissions = emptyList(),
                missingPermissions = emptyList(),
                requestablePermissions = emptyList(),
                blockedPermissions = emptyList(),
                canScan = canScan,
                canAdvertise = canAdvertise,
            ),
        )
    }
}
