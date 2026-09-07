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
import org.levarac.beid.persistence.BindingRecordStore
import org.levarac.beid.persistence.SelfProofRecordStore
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull

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
     * barnard drives the relay on its own timer too, so this cadence is not
     * the only thing ending a lease on time — but a host that stops calling it
     * is a host whose relay decisions are no longer tied to its own liveness.
     */
    @Test
    fun theHostRunsTheRelayForwardOnTheThirtySecondBoundary() = runTest {
        val engine = FakeEventJoinEngine()
        val coordinator = coordinator(engine)
        coordinator.joinEvent("community-night")

        advanceTimeBy(29_999L)
        runCurrent()
        assertEquals(0, engine.advanceRelayCalls)

        advanceTimeBy(1L)
        runCurrent()
        assertEquals(1, engine.advanceRelayCalls)

        advanceTimeBy(30_000L)
        runCurrent()
        assertEquals(2, engine.advanceRelayCalls)
    }

    @Test
    fun theCadenceStopsWhenTheEventIsLeft() = runTest {
        val engine = FakeEventJoinEngine()
        val coordinator = coordinator(engine)
        coordinator.joinEvent("community-night")
        advanceTimeBy(30_000L)
        runCurrent()

        coordinator.leaveEvent()
        advanceTimeBy(120_000L)
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

    private fun TestScope.coordinator(engine: FakeEventJoinEngine): EventJoinCoordinator =
        EventJoinCoordinator(
            engine = engine,
            nowEpochMillis = { testScheduler.currentTime },
            coroutineScope = backgroundScope,
            sensingCryptography = FakeSensingCryptography(),
            selfProofRecordStore = SelfProofRecordStore(newTempRecordFile("relay-self-proofs")),
            bindingRecordStore = BindingRecordStore(newTempRecordFile("relay-binding-records")),
        )

    private companion object {
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
