package org.levarac.beid.sensing

import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runTest
import org.levarac.beid.persistence.BindingRecordStore
import org.levarac.beid.persistence.SelfProofRecordStore
import kotlin.test.Test
import kotlin.test.assertEquals

class EventJoinCoordinatorPermissionRebindingTest {
    @Test
    fun pendingPermissionResultGoesToTheReplacementUi() = runTest {
        val engine = FakeEventJoinEngine(permissionResult = null)
        val coordinator = coordinator(engine)
        val oldResults = mutableListOf<BluetoothPermissionState>()
        val newResults = mutableListOf<BluetoothPermissionState>()
        coordinator.requestBluetoothPermission { oldResults += it }
        coordinator.detachActivity()
        coordinator.bindBluetoothPermissionResult { newResults += it }

        engine.completePermissionRequest(FakeEventJoinEngine.GRANTED)

        assertEquals(emptyList(), oldResults)
        assertEquals(listOf(BluetoothPermissionState.Granted), newResults)
        assertEquals(BluetoothPermissionState.Granted, coordinator.bluetoothPermissionState)
        coordinator.dispose()
    }

    @Test
    fun permissionResultBeforeUiReattachmentIsDeliveredOnlyOnce() = runTest {
        val engine = FakeEventJoinEngine(permissionResult = null)
        val coordinator = coordinator(engine)
        val oldResults = mutableListOf<BluetoothPermissionState>()
        val newResults = mutableListOf<BluetoothPermissionState>()
        coordinator.requestBluetoothPermission { oldResults += it }
        coordinator.detachActivity()
        engine.completePermissionRequest(FakeEventJoinEngine.GRANTED)
        assertEquals(emptyList(), oldResults)

        coordinator.bindBluetoothPermissionResult { newResults += it }
        coordinator.bindBluetoothPermissionResult(null)
        coordinator.bindBluetoothPermissionResult { newResults += it }

        assertEquals(listOf(BluetoothPermissionState.Granted), newResults)
        coordinator.dispose()
    }

    @Test
    fun realFinishDropsPendingPermissionUiAndLateResults() = runTest {
        val engine = FakeEventJoinEngine(permissionResult = null)
        val coordinator = coordinator(engine)
        val results = mutableListOf<BluetoothPermissionState>()
        coordinator.requestBluetoothPermission { results += it }
        coordinator.dispose()
        engine.completePermissionRequest(FakeEventJoinEngine.GRANTED)

        assertEquals(emptyList(), results)
        assertEquals(1, engine.disposeCalls)
    }

    private fun TestScope.coordinator(engine: FakeEventJoinEngine) = EventJoinCoordinator(
        engine = engine,
        nowEpochMillis = { NearbyEventPromotionFixture.VECTOR_NOW_EPOCH_MILLIS },
        coroutineScope = backgroundScope,
        sensingCryptography = FakeSensingCryptography(),
        selfProofRecordStore = SelfProofRecordStore(newTempRecordFile("permission-self-proofs")),
        bindingRecordStore = BindingRecordStore(newTempRecordFile("permission-bindings")),
    )
}
