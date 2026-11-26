package org.levarac.beid.sensing

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.levarac.beid.persistence.BindingRecordStore
import org.levarac.beid.persistence.SelfProofRecordStore
import org.levarac.beid.shared.event.NearbyEventSearchOutcome
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertTrue

/**
 * Home standby discovery pauses while the Bluetooth radio is off and resumes
 * when it is back, without touching a joined session. Mirrors iOS
 * `AppCoordinator.updateHomeStandby` (integration/ios-1.1.1
 * `AppCoordinator.swift:941-958`: `!homeBluetoothIsOff` gates discovery, a
 * disabled gate calls `stopNearbyEventDiscovery` only while idle) and
 * `SensingCoordinator.handle(.state)` (`SensingCoordinator.swift:1849-1856`:
 * a requested standby scan is restarted when the radio comes back; the scan
 * phase is never changed by radio state).
 */
@OptIn(ExperimentalCoroutinesApi::class)
class EventJoinCoordinatorRadioPauseTest {
    @Test
    fun radioOffStopsIdleDiscoveryAndRadioOnRestartsIt() = runTest {
        val engine = FakeEventJoinEngine()
        val coordinator = coordinator(engine)
        coordinator.startNearbyEventDiscovery()
        engine.emitHint("p", "Event", EVENT_HASH)
        assertEquals(1, engine.startScanCalls)

        coordinator.onBluetoothRadioChanged(isOn = false)

        assertEquals(1, engine.stopScanCalls, "a discovery-owned scan stops when the radio drops")
        assertFalse(engine.engineState.isScanning)
        assertEquals(0, coordinator.nearbyEventCandidates.value.candidateCount)

        coordinator.onBluetoothRadioChanged(isOn = true)

        assertEquals(2, engine.startScanCalls, "standby discovery resumes once the radio is back")
        assertTrue(engine.engineState.isScanning)
    }

    @Test
    fun noRescueOfferAccruesWhileTheRadioIsOff() = runTest {
        val engine = FakeEventJoinEngine()
        val coordinator = coordinator(engine)
        coordinator.startNearbyEventDiscovery()

        coordinator.onBluetoothRadioChanged(isOn = false)
        advanceTimeBy(10 * 60 * 1_000L)
        runCurrent()

        assertEquals(
            NearbyEventSearchOutcome.SEARCHING,
            coordinator.nearbyEventSearchOutcome.value,
            "a dead radio is not 'no joinable event nearby'",
        )
    }

    @Test
    fun discoveryRequestedWhileTheRadioIsOffWaitsForTheRadio() = runTest {
        val engine = FakeEventJoinEngine()
        val coordinator = coordinator(engine)
        coordinator.onBluetoothRadioChanged(isOn = false)

        coordinator.startNearbyEventDiscovery()

        assertEquals(0, engine.startScanCalls)
        assertEquals(NearbyEventSearchOutcome.SEARCHING, coordinator.nearbyEventSearchOutcome.value)

        coordinator.onBluetoothRadioChanged(isOn = true)

        assertEquals(1, engine.startScanCalls)
    }

    @Test
    fun radioOnWithoutARequestedStandbyStartsNothing() = runTest {
        val engine = FakeEventJoinEngine()
        val coordinator = coordinator(engine)

        coordinator.onBluetoothRadioChanged(isOn = false)
        coordinator.onBluetoothRadioChanged(isOn = true)

        assertEquals(0, engine.startScanCalls)
        assertEquals(0, engine.stopScanCalls)
    }

    @Test
    fun radioDropDuringASessionKeepsThePhaseAndTransport() = runTest {
        val engine = FakeEventJoinEngine()
        val registry = FakeNearbyEventRegistry()
        val coordinator = coordinator(engine, registry)
        coordinator.requestBluetoothPermission {}
        coordinator.startNearbyEventDiscovery()
        joinPromotedVectorEvent(coordinator, engine, registry)
        val before = coordinator.state.value
        assertIs<EventJoinUiState.Sensing>(before)
        val scanStartsBefore = engine.startScanCalls

        coordinator.onBluetoothRadioChanged(isOn = false)

        assertEquals(before, coordinator.state.value, "a radio drop never ends or changes a joined session")
        assertEquals(0, engine.stopScanCalls)
        assertTrue(engine.engineState.isAdvertising)

        coordinator.onBluetoothRadioChanged(isOn = true)

        assertEquals(before, coordinator.state.value)
        assertEquals(scanStartsBefore, engine.startScanCalls, "standby discovery never restarts over a session")
        assertEquals(1, engine.startAutoCalls)
    }

    /**
     * The gate owns "should standby run". Once it stops discovery, a radio
     * pause recorded before that is withdrawn (iOS `stopNearbyEventDiscovery`
     * clears `homeStandbyDiscoveryRequested`), so the radio returning while the
     * user is on Records, Account or in the background starts nothing.
     */
    @Test
    fun aGateStopAfterARadioPauseWithdrawsTheResume() = runTest {
        val engine = FakeEventJoinEngine()
        val coordinator = coordinator(engine)
        coordinator.startNearbyEventDiscovery()
        coordinator.onBluetoothRadioChanged(isOn = false)

        coordinator.stopNearbyEventDiscovery()
        coordinator.onBluetoothRadioChanged(isOn = true)

        assertEquals(1, engine.startScanCalls, "a closed gate is not reopened by the radio")
        assertFalse(engine.engineState.isScanning)
    }

    @Test
    fun aGateStopWithdrawsAStartDeferredWhileTheRadioWasOff() = runTest {
        val engine = FakeEventJoinEngine()
        val coordinator = coordinator(engine)
        coordinator.onBluetoothRadioChanged(isOn = false)
        coordinator.startNearbyEventDiscovery()

        coordinator.stopNearbyEventDiscovery()
        coordinator.onBluetoothRadioChanged(isOn = true)

        assertEquals(0, engine.startScanCalls)
    }

    /** Gate closes on radio off, then reopens after the coordinator hears the radio is back. */
    @Test
    fun aToggleWithTheGateReopeningAfterTheRadioResumesOnce() = runTest {
        val engine = FakeEventJoinEngine()
        val coordinator = coordinator(engine)
        coordinator.startNearbyEventDiscovery()

        coordinator.onBluetoothRadioChanged(isOn = false)
        coordinator.stopNearbyEventDiscovery()
        coordinator.onBluetoothRadioChanged(isOn = true)
        coordinator.startNearbyEventDiscovery()

        assertEquals(2, engine.startScanCalls)
        assertEquals(1, engine.stopScanCalls)
        assertTrue(engine.engineState.isScanning)
    }

    /** Gate reopens before the coordinator hears the radio: the start is deferred, then runs once. */
    @Test
    fun aToggleWithTheGateReopeningBeforeTheRadioResumesOnce() = runTest {
        val engine = FakeEventJoinEngine()
        val coordinator = coordinator(engine)
        coordinator.startNearbyEventDiscovery()

        coordinator.stopNearbyEventDiscovery()
        coordinator.onBluetoothRadioChanged(isOn = false)
        coordinator.startNearbyEventDiscovery()
        assertEquals(1, engine.startScanCalls, "a start requested while off is deferred")
        coordinator.onBluetoothRadioChanged(isOn = true)

        assertEquals(2, engine.startScanCalls)
        assertEquals(1, engine.stopScanCalls)
        assertTrue(engine.engineState.isScanning)
    }

    /**
     * A permission grant routes the user and starts nothing (iOS release/1.1.0
     * `AppCoordinator.requestBluetoothPermission` → `applyBluetoothState`).
     * Granted with the radio off, the user is on the Bluetooth-off guidance
     * waiting for "I've turned it on"; the radio returning there must not
     * start a scan the Now gate never asked for.
     */
    @Test
    fun aPermissionGrantedWhileTheRadioIsOffStartsNoDiscoveryWhenTheRadioReturns() = runTest {
        val engine = FakeEventJoinEngine()
        val coordinator = coordinator(engine)
        coordinator.onBluetoothRadioChanged(isOn = false)
        val results = mutableListOf<BluetoothPermissionState>()

        coordinator.requestBluetoothPermission { results += it }
        coordinator.onBluetoothRadioChanged(isOn = true)

        assertEquals(listOf(BluetoothPermissionState.Granted), results)
        assertEquals(0, engine.startScanCalls, "only the Now gate starts standby discovery")
        assertFalse(engine.engineState.isScanning)

        coordinator.startNearbyEventDiscovery()

        assertEquals(1, engine.startScanCalls, "the gate's request starts it")
        assertTrue(engine.engineState.isScanning)
    }

    /** With the radio on, too, the grant itself starts nothing; the gate does. */
    @Test
    fun aPermissionGrantWithTheRadioOnStartsNoDiscovery() = runTest {
        val engine = FakeEventJoinEngine()
        val coordinator = coordinator(engine)

        coordinator.requestBluetoothPermission {}

        assertEquals(0, engine.startScanCalls)
        assertFalse(engine.engineState.isScanning)
    }

    private fun TestScope.coordinator(
        engine: FakeEventJoinEngine,
        nearbyRegistry: FakeNearbyEventRegistry = FakeNearbyEventRegistry(),
    ): EventJoinCoordinator =
        EventJoinCoordinator(
            engine = engine,
            nearbyRegistry = nearbyRegistry,
            nowEpochMillis = { NearbyEventPromotionFixture.VECTOR_NOW_EPOCH_MILLIS + testScheduler.currentTime },
            coroutineScope = backgroundScope,
            sensingCryptography = FakeSensingCryptography(),
            selfProofRecordStore = SelfProofRecordStore(newTempRecordFile("radio-self-proofs")),
            bindingRecordStore = BindingRecordStore(newTempRecordFile("radio-binding-records")),
        )

    private companion object {
        val EVENT_HASH = byteArrayOf(0, 1, 2, 3, 4, 5, 6, 7)
    }
}
