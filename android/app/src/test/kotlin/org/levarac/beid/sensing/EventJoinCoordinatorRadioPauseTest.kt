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
