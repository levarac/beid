package org.levarac.beid.sensing

import java.util.UUID
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertTrue
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.levarac.barnard.BarnardPermissionError
import org.levarac.barnard.BarnardPermissionResult
import org.levarac.barnard.BarnardPermissionStatus
import org.levarac.beid.persistence.BindingRecordStore
import org.levarac.beid.persistence.SelfProofRecordStore

private fun fakeStatus(canScan: Boolean, canAdvertise: Boolean): BarnardPermissionStatus =
    BarnardPermissionStatus(
        platform = "android",
        permissions = emptyMap(),
        requiredPermissions = emptyList(),
        missingPermissions = emptyList(),
        requestablePermissions = emptyList(),
        blockedPermissions = emptyList(),
        canScan = canScan,
        canAdvertise = canAdvertise,
    )

/**
 * `EventJoinCoordinator`'s [EventJoinCoordinator.onProofCollected]/
 * [EventJoinCoordinator.onPeersVerifiedChanged]/
 * [EventJoinCoordinator.onProofSignatureStateChanged] callback hooks —
 * beid#235, the contract issue #121's own Worker is coding a fake against.
 * No `UnsentWindowLedger`/ledger-writer concern here; these tests only
 * confirm the three hooks fire (or do not) at the exact boundaries the
 * task spec pins down. [EventJoinCoordinatorSelfProofTest]/
 * [EventJoinCoordinatorBindingTest] cover
 * [EventJoinCoordinator.onProofSignatureStateChanged]'s two fire sites,
 * since those already own [EventJoinCoordinator.leaveEvent]/
 * [EventJoinCoordinator.completeBinding]'s persistence assertions this
 * hook piggybacks on.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class EventJoinCoordinatorHooksTest {
    @Test
    fun staleJoinActionCannotReplaceAnActiveProofOrResetItsAccountingAndBinding() = runTest {
        val engine = FakeEventJoinEngine()
        val coordinator = coordinator(engine, FakeSensingCryptography())
        val proofIds = mutableListOf<UUID>()
        val peerUpdates = mutableListOf<Pair<UUID, Int>>()
        coordinator.onProofCollected = { proofId, _, _ -> proofIds += proofId }
        coordinator.onPeersVerifiedChanged = { proofId, peersVerified -> peerUpdates += proofId to peersVerified }

        coordinator.joinEvent("FIRST-EVENT")

        runCurrent()
        assertEquals("FIRST-EVENT", engine.getCurrentEventCode(), "an Idle session must still admit the initial join")
        assertEquals(1, engine.startAutoCalls)
        confirmRecording(engine)
        val firstProofId = proofIds.single()
        val firstBinding = assertIs<EventBindingState.PendingConnect>(coordinator.bindingState)

        coordinator.joinNearbyEvent("SECOND-EVENT")

        runCurrent()

        assertEquals("FIRST-EVENT", engine.getCurrentEventCode(), "a stale action must not replace the active engine event")
        assertEquals(1, engine.startAutoCalls, "a stale action must not restart the engine")
        assertEquals(firstBinding, coordinator.bindingState, "a stale action must not clear the active proof's binding state")

        engine.emitDetection(enin = 4, rpid = "dd", detectedDisplayId = "device-4")

        assertEquals(listOf(firstProofId to 4), peerUpdates, "the first proof identity and its device accounting must survive")
        assertEquals(listOf(firstProofId), proofIds, "the stale action must not create a replacement proof")
    }

    @Test
    fun onProofCollectedFiresExactlyOnceAtFirstConfirmWithTheCorrectValues() = runTest {
        val engine = FakeEventJoinEngine()
        val coordinator = coordinator(engine, FakeSensingCryptography())
        val calls = mutableListOf<Triple<UUID, String, Int>>()
        coordinator.onProofCollected = { proofId, eventCode, peersVerified -> calls += Triple(proofId, eventCode, peersVerified) }

        coordinator.joinEvent("HOOK-EVENT")

        runCurrent()
        confirmRecording(engine)

        assertEquals(1, calls.size, "must fire exactly once, at the first confirm into Recording")
        val (proofId, eventCode, peersVerified) = calls.single()
        assertEquals("HOOK-EVENT", eventCode)
        assertEquals(3, peersVerified, "3 distinct devices were observed to reach the confirm threshold")
        assertTrue(calls.all { it.first == proofId }, "sanity: only one call recorded")
    }

    @Test
    fun onProofCollectedDoesNotRefireOnSubsequentDetectionsWhileAlreadyRecording() = runTest {
        val engine = FakeEventJoinEngine()
        val coordinator = coordinator(engine, FakeSensingCryptography())
        var callCount = 0
        coordinator.onProofCollected = { _, _, _ -> callCount += 1 }

        coordinator.joinEvent("HOOK-EVENT")

        runCurrent()
        confirmRecording(engine)
        engine.emitDetection(enin = 4, rpid = "dd", detectedDisplayId = "device-4")
        engine.emitDetection(enin = 4, rpid = "dd", detectedDisplayId = "device-4")

        assertEquals(1, callCount, "already-Recording detections, including a duplicate device, must never re-fire onProofCollected")
    }

    @Test
    fun onPeersVerifiedChangedDoesNotFireOnTheInitialConfirm() = runTest {
        val engine = FakeEventJoinEngine()
        val coordinator = coordinator(engine, FakeSensingCryptography())
        var callCount = 0
        coordinator.onPeersVerifiedChanged = { _, _ -> callCount += 1 }

        coordinator.joinEvent("HOOK-EVENT")

        runCurrent()
        confirmRecording(engine)

        assertEquals(0, callCount, "the confirming detection is onProofCollected's transition, not a peers-verified update")
    }

    @Test
    fun onPeersVerifiedChangedFiresWhenTheCountChangesWhileAlreadyRecording() = runTest {
        val engine = FakeEventJoinEngine()
        val coordinator = coordinator(engine, FakeSensingCryptography())
        val proofIds = mutableListOf<UUID>()
        coordinator.onProofCollected = { proofId, _, _ -> proofIds += proofId }
        val calls = mutableListOf<Pair<UUID, Int>>()
        coordinator.onPeersVerifiedChanged = { proofId, peersVerified -> calls += proofId to peersVerified }

        coordinator.joinEvent("HOOK-EVENT")

        runCurrent()
        confirmRecording(engine)
        engine.emitDetection(enin = 4, rpid = "dd", detectedDisplayId = "device-4")

        assertEquals(listOf(proofIds.single() to 4), calls, "must fire once, with the same Proof identity onProofCollected already handed out")
    }

    @Test
    fun onPeersVerifiedChangedDoesNotFireForARepeatedDeviceThatDoesNotChangeTheCount() = runTest {
        val engine = FakeEventJoinEngine()
        val coordinator = coordinator(engine, FakeSensingCryptography())
        var callCount = 0
        coordinator.onPeersVerifiedChanged = { _, _ -> callCount += 1 }

        coordinator.joinEvent("HOOK-EVENT")

        runCurrent()
        confirmRecording(engine)
        engine.emitDetection(enin = 4, rpid = "cc", detectedDisplayId = "device-3")

        assertEquals(0, callCount, "device-3 was already counted — distinctDeviceCount does not move")
    }

    @Test
    fun neitherHookFiresBelowTheConfirmThreshold() = runTest {
        val engine = FakeEventJoinEngine()
        val coordinator = coordinator(engine, FakeSensingCryptography())
        var proofCollectedCalls = 0
        var peersVerifiedChangedCalls = 0
        coordinator.onProofCollected = { _, _, _ -> proofCollectedCalls += 1 }
        coordinator.onPeersVerifiedChanged = { _, _ -> peersVerifiedChangedCalls += 1 }

        coordinator.joinEvent("HOOK-EVENT")

        runCurrent()
        engine.emitDetection(enin = 1, rpid = "aa", detectedDisplayId = "device-1")

        assertEquals(0, proofCollectedCalls, "EventFound/Sensing never produced a Proof")
        assertEquals(0, peersVerifiedChangedCalls)
    }

    @Test
    fun onPeersVerifiedChangedDoesNotFireWhileSignalLost() = runTest {
        val engine = FakeEventJoinEngine()
        val coordinator = coordinator(engine, FakeSensingCryptography())
        var callCount = 0
        coordinator.onPeersVerifiedChanged = { _, _ -> callCount += 1 }

        coordinator.joinEvent("HOOK-EVENT")

        runCurrent()
        confirmRecording(engine)
        coordinator.simulateSignalLost()
        engine.emitDetection(enin = 4, rpid = "dd", detectedDisplayId = "device-4")

        assertEquals(0, callCount, "a detection arriving while SignalLost must not surface a peers-verified update")
    }

    @Test
    fun neitherHookCrashesWhenNeverAssigned() = runTest {
        val engine = FakeEventJoinEngine()
        val coordinator = coordinator(engine, FakeSensingCryptography())

        coordinator.joinEvent("HOOK-EVENT")

        runCurrent()
        confirmRecording(engine)
        engine.emitDetection(enin = 4, rpid = "dd", detectedDisplayId = "device-4")

        assertTrue(coordinator.state.value is EventJoinUiState.Sensing, "reaching here without an exception is the assertion")
    }

    @Test
    fun recordingCeremonyShownDefaultsFalseAndFlipsTrueOnceMarked() = runTest {
        val engine = FakeEventJoinEngine()
        val coordinator = coordinator(engine, FakeSensingCryptography())

        assertFalse(coordinator.recordingCeremonyShown, "a fresh coordinator has never shown the ceremony")
        coordinator.joinEvent("HOOK-EVENT")
        runCurrent()
        confirmRecording(engine)
        assertFalse(coordinator.recordingCeremonyShown, "confirming Recording alone must not mark the ceremony shown — only the UI does, via markRecordingCeremonyShown")

        coordinator.markRecordingCeremonyShown()

        assertTrue(coordinator.recordingCeremonyShown)
    }

    @Test
    fun recordingCeremonyShownSurvivesASignalLostResumeCycleUnchanged() = runTest {
        val engine = FakeEventJoinEngine()
        val coordinator = coordinator(engine, FakeSensingCryptography())

        coordinator.joinEvent("HOOK-EVENT")

        runCurrent()
        confirmRecording(engine)
        coordinator.markRecordingCeremonyShown()

        coordinator.simulateSignalLost()
        coordinator.resumeSensing()

        assertTrue(
            coordinator.recordingCeremonyShown,
            "resumeSensing (SIGNAL_LOST -> RECORDING in place) must never replay the entrance ceremony",
        )
    }

    @Test
    fun recordingCeremonyShownResetsOnAFreshSessionAfterLeavingTheEvent() = runTest {
        val engine = FakeEventJoinEngine()
        val coordinator = coordinator(engine, FakeSensingCryptography())

        coordinator.joinEvent("FIRST-EVENT")

        runCurrent()
        confirmRecording(engine)
        coordinator.markRecordingCeremonyShown()
        assertTrue(coordinator.recordingCeremonyShown)

        coordinator.leaveEvent()
        coordinator.joinEvent("SECOND-EVENT")
        runCurrent()

        assertFalse(
            coordinator.recordingCeremonyShown,
            "a genuinely new session (a fresh joinEvent after leaving) must show the ceremony again",
        )
    }

    private fun confirmRecording(engine: FakeEventJoinEngine) {
        engine.emitDetection(enin = 1, rpid = "aa", detectedDisplayId = "device-1")
        engine.emitDetection(enin = 2, rpid = "bb", detectedDisplayId = "device-2")
        engine.emitDetection(enin = 3, rpid = "cc", detectedDisplayId = "device-3")
    }

    private fun TestScope.coordinator(
        engine: FakeEventJoinEngine,
        cryptography: FakeSensingCryptography,
        selfProofRecordStore: SelfProofRecordStore = SelfProofRecordStore(newTempRecordFile("self-proofs")),
        bindingRecordStore: BindingRecordStore = BindingRecordStore(newTempRecordFile("binding-records")),
    ): EventJoinCoordinator = EventJoinCoordinator(
        engine = engine,
        joinRegistry = FakeEventJoinRegistry(),
        nowEpochMillis = { testScheduler.currentTime },
        coroutineScope = backgroundScope,
        sensingCryptography = cryptography,
        selfProofRecordStore = selfProofRecordStore,
        bindingRecordStore = bindingRecordStore,
    )
}

class EventJoinCoordinatorTest {
    @Test
    fun grantedWithoutScanCapabilityMapsToPermissionDenied() {
        val result = BarnardPermissionResult.Granted(fakeStatus(canScan = false, canAdvertise = true))

        assertEquals(EventJoinUiState.PermissionDenied, mapPermissionResultToState(result))
    }

    @Test
    fun grantedWithoutAdvertiseCapabilityMapsToPermissionDenied() {
        val result = BarnardPermissionResult.Granted(fakeStatus(canScan = true, canAdvertise = false))

        assertEquals(EventJoinUiState.PermissionDenied, mapPermissionResultToState(result))
    }

    @Test
    fun failedWithNoActivityErrorMapsToJoinFailedNotPermissionDenied() {
        val status = fakeStatus(canScan = true, canAdvertise = true)
        val error = BarnardPermissionError(code = "E_NO_ACTIVITY", message = "no activity attached", status = status)

        assertEquals(EventJoinUiState.JoinFailed, mapPermissionResultToState(BarnardPermissionResult.Failed(error)))
    }

    @Test
    fun failedWithPermissionRequestInProgressErrorMapsToJoinFailedNotPermissionDenied() {
        val status = fakeStatus(canScan = true, canAdvertise = true)
        val error = BarnardPermissionError(
            code = "E_PERMISSION_REQUEST_IN_PROGRESS",
            message = "a request is already in flight",
            status = status,
        )

        assertEquals(EventJoinUiState.JoinFailed, mapPermissionResultToState(BarnardPermissionResult.Failed(error)))
    }
}
