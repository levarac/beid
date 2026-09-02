package org.levarac.beid.sensing

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.levarac.barnard.BarnardPermissionResult
import org.levarac.barnard.BarnardPermissionStatus
import org.levarac.beid.persistence.BindingRecordStore
import org.levarac.beid.persistence.SelfProofRecordStore
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

@OptIn(ExperimentalCoroutinesApi::class)
class EventJoinCoordinatorDiscoveryAdapterTest {
    @Test
    fun grantedPreJoinDiscoveryStartsScanOnlyAndMapsB005WithoutChangingJoinUiState() = runTest {
        val engine = FakeEventJoinEngine()
        val coordinator = coordinator(engine)

        coordinator.requestBluetoothPermission {}
        engine.emitHint(
            peripheralId = "peripheral-a",
            displayName = "Community night",
            hash = EVENT_HASH,
            census = byteArrayOf(1, 2),
        )

        assertEquals(1, engine.startScanCalls)
        assertEquals(0, engine.startAutoCalls)
        assertEquals(EventJoinUiState.Idle, coordinator.state.value)
        val candidate = assertNotNull(coordinator.nearbyEventCandidates.value.candidateAt(0))
        assertContentEquals(EVENT_HASH, candidate.eventCodeHash)
        assertEquals("Community night", candidate.displayNameAt(0))
        assertEquals("peripheral-a", assertNotNull(candidate.sourceAt(0)).peripheralId)
        assertContentEquals(byteArrayOf(1, 2), assertNotNull(assertNotNull(candidate.sourceAt(0)).census))
    }

    @Test
    fun expiryUsesTheInjectedClockAndCoroutineScope() = runTest {
        val engine = FakeEventJoinEngine()
        val coordinator = coordinator(engine)
        coordinator.requestBluetoothPermission {}
        engine.emitHint("p", "Event", EVENT_HASH)
        assertEquals(1, coordinator.nearbyEventCandidates.value.candidateCount)

        advanceTimeBy(299_999L)
        runCurrent()
        assertEquals(1, coordinator.nearbyEventCandidates.value.candidateCount)

        advanceTimeBy(1L)
        runCurrent()
        assertEquals(0, coordinator.nearbyEventCandidates.value.candidateCount)
    }

    @Test
    fun repeatedPermissionGrantDoesNotRestartOrResetOwnedDiscoveryScan() = runTest {
        val engine = FakeEventJoinEngine()
        val coordinator = coordinator(engine)
        coordinator.requestBluetoothPermission {}
        engine.emitHint("p", "Event", EVENT_HASH)

        coordinator.requestBluetoothPermission {}

        assertEquals(1, engine.startScanCalls)
        assertEquals(1, coordinator.nearbyEventCandidates.value.candidateCount)
    }

    @Test
    fun explicitStopStopsOnlyAGenuineDiscoveryOwnedScan() = runTest {
        val engine = FakeEventJoinEngine()
        val coordinator = coordinator(engine)
        coordinator.requestBluetoothPermission {}

        coordinator.stopNearbyEventDiscovery()

        assertEquals(1, engine.stopScanCalls)
        assertFalse(engine.engineState.isScanning)
        assertEquals(0, coordinator.nearbyEventCandidates.value.candidateCount)
    }

    @Test
    fun joiningTransfersTransportOwnershipAndLeaveResetsCandidatesWithoutStoppingScanOrAdvertise() = runTest {
        val engine = FakeEventJoinEngine()
        val coordinator = coordinator(engine)
        coordinator.requestBluetoothPermission {}
        engine.emitHint("p", "Event", EVENT_HASH)

        coordinator.joinEvent("JOIN-CODE")
        coordinator.leaveEvent()
        coordinator.stopNearbyEventDiscovery()

        assertEquals(1, engine.startAutoCalls)
        assertEquals(0, engine.stopScanCalls, "the discovery adapter no longer owns startAuto's scan")
        assertTrue(engine.engineState.isScanning)
        assertTrue(engine.engineState.isAdvertising, "Barnard 0.4 leaveEvent does not stop advertising")
        assertEquals(0, coordinator.nearbyEventCandidates.value.candidateCount)
        assertEquals(EventJoinUiState.Idle, coordinator.state.value)
    }

    @Test
    fun advertisingGuardPreventsAStaleOwnershipFlagFromStoppingHalfOfATransportPair() = runTest {
        val engine = FakeEventJoinEngine()
        val coordinator = coordinator(engine)
        coordinator.requestBluetoothPermission {}
        engine.engineState = EventJoinEngineState(isScanning = true, isAdvertising = true)

        coordinator.stopNearbyEventDiscovery()

        assertEquals(0, engine.stopScanCalls)
        assertTrue(engine.engineState.isScanning)
        assertTrue(engine.engineState.isAdvertising)
    }

    @Test
    fun overflowMarkerUpdatesOmissionFactsButCreatesNoCandidate() = runTest {
        val engine = FakeEventJoinEngine()
        val coordinator = coordinator(engine)
        coordinator.requestBluetoothPermission {}

        engine.emitHint(
            peripheralId = "",
            displayName = "",
            hash = byteArrayOf(),
            additionalNamesOmitted = true,
            additionalEventsOmitted = true,
        )

        val snapshot = coordinator.nearbyEventCandidates.value
        assertEquals(0, snapshot.candidateCount)
        assertTrue(snapshot.additionalNamesOmitted)
        assertTrue(snapshot.additionalEventsOmitted)
        assertEquals(EventJoinUiState.Idle, coordinator.state.value)
    }

    @Test
    fun disposeCancelsOwnershipAndLatePermissionCompletionCannotRestartScanning() = runTest {
        val engine = FakeEventJoinEngine(permissionResult = null)
        val coordinator = coordinator(engine)
        var completionCalls = 0
        coordinator.requestBluetoothPermission { completionCalls += 1 }

        coordinator.dispose()
        engine.completePermissionRequest(GRANTED)

        assertEquals(1, engine.disposeCalls)
        assertEquals(0, engine.startScanCalls)
        assertFalse(engine.engineState.isScanning)
        assertFalse(engine.engineState.isAdvertising)
        assertEquals(0, completionCalls, "a disposed coordinator must ignore the late engine callback")
    }

    @Test
    fun leaveEventAloneClearsCandidatesWithoutRelyingOnAnExplicitDiscoveryStop() = runTest {
        val engine = FakeEventJoinEngine()
        val coordinator = coordinator(engine)
        coordinator.requestBluetoothPermission {}
        engine.emitHint("p", "Event", EVENT_HASH)
        coordinator.joinEvent("JOIN-CODE")
        assertEquals(1, coordinator.nearbyEventCandidates.value.candidateCount)

        coordinator.leaveEvent()

        assertEquals(
            0,
            coordinator.nearbyEventCandidates.value.candidateCount,
            "leaveEvent must clear pre-join candidates itself, not lean on stopNearbyEventDiscovery",
        )
    }

    @Test
    fun advertisingWithoutScanningStillBlocksASecondDiscoveryOwnedScan() = runTest {
        val engine = FakeEventJoinEngine()
        val coordinator = coordinator(engine)
        engine.engineState = EventJoinEngineState(isScanning = false, isAdvertising = true)

        coordinator.requestBluetoothPermission {}

        assertEquals(
            0,
            engine.startScanCalls,
            "an already-advertising transport is not this adapter's to re-arm for discovery",
        )
    }

    @Test
    fun aLiveJoinedSessionBlocksDiscoveryEvenWhenTheEngineReportsNoTransport() = runTest {
        val engine = FakeEventJoinEngine()
        val coordinator = coordinator(engine)
        coordinator.joinEvent("JOIN-CODE")
        engine.engineState = EventJoinEngineState(isScanning = false, isAdvertising = false)

        coordinator.requestBluetoothPermission {}

        assertEquals(
            0,
            engine.startScanCalls,
            "scanPhase, not the engine's reported transport, decides whether a join owns this session",
        )
    }

    @Test
    fun stopLeavesAScanThisAdapterNeverStartedRunning() = runTest {
        val engine = FakeEventJoinEngine()
        val coordinator = coordinator(engine)
        engine.engineState = EventJoinEngineState(isScanning = true, isAdvertising = false)

        coordinator.stopNearbyEventDiscovery()

        assertEquals(
            0,
            engine.stopScanCalls,
            "only a scan this adapter started for discovery may be stopped by it",
        )
        assertTrue(engine.engineState.isScanning)
    }

    private fun kotlinx.coroutines.test.TestScope.coordinator(engine: FakeEventJoinEngine): EventJoinCoordinator =
        EventJoinCoordinator(
            engine = engine,
            nowEpochMillis = { testScheduler.currentTime },
            coroutineScope = backgroundScope,
            sensingCryptography = FakeSensingCryptography(),
            selfProofRecordStore = SelfProofRecordStore(newTempRecordFile("self-proofs")),
            bindingRecordStore = BindingRecordStore(newTempRecordFile("binding-records")),
        )

    companion object {
        val EVENT_HASH = byteArrayOf(0, 1, 2, 3, 4, 5, 6, 7)
        val GRANTED = BarnardPermissionResult.Granted(
            BarnardPermissionStatus(
                platform = "android",
                permissions = emptyMap(),
                requiredPermissions = emptyList(),
                missingPermissions = emptyList(),
                requestablePermissions = emptyList(),
                blockedPermissions = emptyList(),
                canScan = true,
                canAdvertise = true,
            ),
        )
    }
}

