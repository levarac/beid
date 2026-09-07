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
import org.levarac.parallax.registry.EventJoinMode
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
        val coordinator = coordinator(engine)

        coordinator.joinEvent("community-night")

        assertNotNull(engine.configuredRelayVerifier)
    }

    @Test
    fun aRefusedPermissionLeavesTheRelayOff() = runTest {
        // The fake answers the permission request inline, so the refusal has
        // to be in place before the join asks for it.
        val engine = FakeEventJoinEngine(SCAN_ONLY)
        val coordinator = coordinator(engine)

        coordinator.joinEvent("community-night")

        assertNull(
            engine.configuredRelayVerifier,
            "a device that cannot advertise cannot re-broadcast anything",
        )
    }

    @Test
    fun leavingTheEventClearsTheRelay() = runTest {
        val engine = FakeEventJoinEngine()
        val coordinator = coordinator(engine)
        coordinator.joinEvent("community-night")

        coordinator.leaveEvent()

        assertNull(engine.configuredRelayVerifier)
    }

    @Test
    fun endingTheSessionClearsTheRelay() = runTest {
        val engine = FakeEventJoinEngine()
        val coordinator = coordinator(engine)
        coordinator.joinEvent("community-night")

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
        coordinator.joinEvent("community-night")
        val verifier = assertNotNull(engine.configuredRelayVerifier)

        // A verified envelope, a registry answer that agrees with it, and the
        // joined event resolved: the three things the gate insists on.
        engine.emitVerifiedEnvelopeV2("peripheral-a", VECTOR_CONTAINER, VECTOR_ENIN)
        runCurrent()
        registry.completeLookup(NearbyEventIdLookup(true, VECTOR_EVENT_ID_HEX, null))
        runCurrent()
        registry.completeDefinition(vectorDefinition())
        runCurrent()
        coordinator.acceptVerifiedObservationContext(
            WindowObservationContext(
                eventCode = "community-night",
                eventIdHex = VECTOR_EVENT_ID_HEX,
                eventDefinitionDigestHex = VECTOR_EVENT_ID_HEX,
            ),
        )
        runCurrent()

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
        val coordinator = coordinator(engine)
        coordinator.joinEvent("community-night")

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
        val coordinator = coordinator(engine)
        coordinator.joinEvent("community-night")
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
            nowEpochMillis = { testScheduler.currentTime },
            coroutineScope = backgroundScope,
            sensingCryptography = FakeSensingCryptography(),
            selfProofRecordStore = SelfProofRecordStore(newTempRecordFile("relay-self-proofs")),
            bindingRecordStore = BindingRecordStore(newTempRecordFile("relay-binding-records")),
        )

    private fun vectorDefinition() = NearbyEventDefinitionVerification(
        isSuccess = true,
        joinMode = EventJoinMode.OPEN,
        eventIdHex = VECTOR_EVENT_ID_HEX,
        eventCodeHashHex = VECTOR_EVENT_CODE_HASH,
        // The registry publishes Unix seconds; barnard converts them back to
        // ENINs and requires exact agreement, so these are the vector's own
        // window expressed the way a registry would carry it.
        validFromEpochSeconds = VECTOR_VALID_FROM * VECTOR_ENIN_SECONDS,
        validUntilEpochSeconds = (VECTOR_VALID_THROUGH + 1) * VECTOR_ENIN_SECONDS - 1,
        keySetDigestHex = VECTOR_KEY_SET_DIGEST,
    )

    private class FakeNearbyEventRegistry : NearbyEventRegistry {
        private var lookupCompletion: ((NearbyEventIdLookup) -> Unit)? = null
        private var definitionCompletion: ((NearbyEventDefinitionVerification) -> Unit)? = null

        override fun resolveEventIdByCodeHash(
            hashHex: String,
            completion: (NearbyEventIdLookup) -> Unit,
        ): NearbyEventRegistryRequest {
            lookupCompletion = completion
            return NearbyEventRegistryRequest {}
        }

        override fun resolveEventDefinition(
            eventIdHex: String,
            useTimeEpochSeconds: Long,
            completion: (NearbyEventDefinitionVerification) -> Unit,
        ): NearbyEventRegistryRequest {
            definitionCompletion = completion
            return NearbyEventRegistryRequest {}
        }

        fun completeLookup(result: NearbyEventIdLookup) {
            requireNotNull(lookupCompletion) { "no event-id lookup was started" }(result)
        }

        fun completeDefinition(result: NearbyEventDefinitionVerification) {
            requireNotNull(definitionCompletion) { "no definition read was started" }(result)
        }
    }

    private companion object {
        /**
         * barnard's own B005 v2 conformance vector, `v1_*` from
         * `test-vectors/b005-envelope-v2.txt` at tag v0.8.0: authority-direct
         * mode, hop zero, genuinely signed. Copied rather than synthesised
         * because the relay gate only ever sees envelopes barnard verified,
         * and nothing this repository can fabricate would get that far.
         */
        const val VECTOR_CONTAINER_HEX = "03000100011111111111111111111111111111111111111111222222222222222222222222222222222222222233333333333333333333333333333333333333333333333333333333333333330102f9308a019258c31049344f85f89d5229b531c845836f99b08601f113bce036f900012c005b8d76005b8d8a005b8d82029adc61d60dda843e3a4261726e6172642052656c617920436f6e666f726d616e6365204576656e742030313233343536373839206162636465666768696a6b6c6d6e6f00f3e5c7db67db1a676b3e488b9f7805bdb0c7078a97cd65a01b2ba8630bc7bb334a594053371a53830a4cac5f57e74cbd1d684ca822859ca5fa510ef28b203b5000"
        const val VECTOR_ENVELOPE_HEX = "011111111111111111111111111111111111111111222222222222222222222222222222222222222233333333333333333333333333333333333333333333333333333333333333330102f9308a019258c31049344f85f89d5229b531c845836f99b08601f113bce036f900012c005b8d76005b8d8a005b8d82029adc61d60dda843e3a4261726e6172642052656c617920436f6e666f726d616e6365204576656e742030313233343536373839206162636465666768696a6b6c6d6e6f00f3e5c7db67db1a676b3e488b9f7805bdb0c7078a97cd65a01b2ba8630bc7bb334a594053371a53830a4cac5f57e74cbd1d684ca822859ca5fa510ef28b203b5000"
        const val VECTOR_EVENT_ID_HEX =
            "5d5891b92a9a6597aa2c58586fd2fdf3974f40f732b9a319ec9f3fc4d7ab3195"
        const val VECTOR_KEY_SET_DIGEST =
            "cba59e50c7666ef2468a14f2e53f04decfd078933cd245a9a2d77532eb23b700"
        const val VECTOR_EVENT_CODE_HASH = "9adc61d60dda843e"
        const val VECTOR_VALID_FROM = 5_999_990L
        const val VECTOR_VALID_THROUGH = 6_000_010L
        const val VECTOR_ENIN_SECONDS = 300L

        /** Inside the vector's signed relay window `[validFrom, relayExpires)`. */
        const val VECTOR_ENIN = 6_000_000L

        val VECTOR_CONTAINER = VECTOR_CONTAINER_HEX.hexBytes()
        val VECTOR_ENVELOPE = VECTOR_ENVELOPE_HEX.hexBytes()

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
