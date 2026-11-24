package org.levarac.beid

import android.app.Activity
import android.content.Context
import io.metamask.androidsdk.CommunicationClientModuleInterface
import org.junit.Before
import org.robolectric.annotation.Implements
import org.robolectric.annotation.Implementation
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotSame
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.levarac.beid.persistence.ProofRecordStore
import org.levarac.beid.persistence.SelfProofRecordStore
import org.levarac.beid.sensing.BluetoothPermissionState
import org.levarac.beid.sensing.EventJoinCoordinator
import org.levarac.beid.sensing.EventJoinEngine
import org.levarac.beid.sensing.EventJoinUiState
import org.levarac.beid.sensing.FakeEventJoinEngine
import org.levarac.beid.sensing.FakeNearbyEventRegistry
import org.levarac.beid.sensing.FakeSensingCryptography
import org.levarac.beid.sensing.MetaMaskSdkTransport
import org.levarac.beid.sensing.NearbyEventPromotionFixture
import org.levarac.beid.sensing.ProcessSessionCheckpointRuntimeOwner
import org.levarac.beid.sensing.ScanPhase
import org.levarac.beid.sensing.joinPromotedVectorEvent
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.util.ReflectionHelpers
import java.util.Collections
import java.util.IdentityHashMap

/** Real MainActivity lifecycle with isolated radio, cryptography, registry and wallet effects. */
@RunWith(RobolectricTestRunner::class)
@Config(
    sdk = [34],
    shadows = [ShadowRecreationWalletTransport::class],
    instrumentedPackages = ["org.levarac.beid.sensing.MetaMaskSdkTransport"],
)
@OptIn(ExperimentalCoroutinesApi::class)
class MainActivityRecreationTest {
    @Before
    fun resetProcessRuntimeForRobolectricApplication() {
        // Each Robolectric application gets a fresh filesDir, unlike a live process.
        val holder = Class.forName("org.levarac.beid.sensing.EventJoinCoordinatorKt")
            .getDeclaredField("ProcessWindowObservationRuntimeOwner").apply { isAccessible = true }.get(null)
        ReflectionHelpers.setField(holder, "activeRuntime", null)
        ReflectionHelpers.setField(holder, "activeFilesPath", null)
    }

    @Test
    fun recordingSurvivesRecreationAndFinalizesExactlyOnceOnFinish() = runTest {
        val controller = Robolectric.buildActivity(MainActivity::class.java).setup()
        try {
            val oldActivity = controller.get()
            val coordinator = requireNotNull(oldActivity.eventJoinCoordinator)
            val engine = FakeEventJoinEngine()
            val cryptography = FakeSensingCryptography()
            val registry = FakeNearbyEventRegistry()
            // Preserve the production coordinator and all its lifecycle wiring.
            // Replace native effects before joining; never replace the coordinator itself.
            val originalEngine = field<EventJoinEngine>(coordinator, "engine")
            val eventCallback = originalEngine.onEvent
            originalEngine.dispose()
            ReflectionHelpers.setField(coordinator, "engine", engine)
            engine.onEvent = eventCallback
            ReflectionHelpers.setField(coordinator, "sensingCryptography", cryptography)
            ReflectionHelpers.setField(coordinator, "nowEpochMillis", { NearbyEventPromotionFixture.VECTOR_NOW_EPOCH_MILLIS })
            val discovery = field<Any>(coordinator, "nearbyDiscovery")
            ReflectionHelpers.setField(discovery, "nowEpochMillis", { NearbyEventPromotionFixture.VECTOR_NOW_EPOCH_MILLIS })
            ReflectionHelpers.setField(discovery, "registry", registry)
            // Window submission is independently covered; this lifecycle test performs no HTTP.
            ReflectionHelpers.setField(coordinator, "windowAccumulator", null)
            ReflectionHelpers.setField(coordinator, "windowObservationRuntime", null)

            joinPromotedVectorEvent(coordinator, engine, registry)
            repeat(3) { engine.emitDetection(enin = 7, rpid = "0$it", detectedDisplayId = "device-$it") }
            coordinator.markRecordingCeremonyShown()
            coordinator.beginBinding("0x14791697260e4c9a71f18484c9f997b308e59325", chainId = 1)
            coordinator.completeBinding("0x14791697260e4c9a71f18484c9f997b308e59325", "0x" + "0a".repeat(65))
            val bindingState = coordinator.bindingState
            assertTrue(bindingState is org.levarac.beid.sensing.EventBindingState.Bound)
            val state = coordinator.state.value
            assertTrue((state as EventJoinUiState.Sensing).phase is ScanPhase.Recording)
            val records = ProcessSessionCheckpointRuntimeOwner.proofRecordStore(ProofRecordStore.defaultFile(oldActivity.filesDir))
            val proofId = records.records.single().id
            val selfProofs = ProcessSessionCheckpointRuntimeOwner.selfProofStore(SelfProofRecordStore.defaultFile(oldActivity.filesDir))
            assertTrue(selfProofs.records.isEmpty())

            controller.recreate()
            val recreated = controller.get()
            assertNotSame(oldActivity, recreated)
            assertEquals("configuration destruction must not dispose", 0, engine.disposeCalls)
            assertSame(coordinator, recreated.eventJoinCoordinator)
            assertEquals(state, recreated.eventJoinCoordinator!!.state.value)
            assertTrue(engine.engineState.isScanning)
            assertTrue(engine.engineState.isAdvertising)
            assertEquals(1, engine.joinEventCalls)
            assertEquals(1, engine.startAutoCalls)
            assertTrue(coordinator.recordingCeremonyShown)
            assertEquals(bindingState, coordinator.bindingState)
            assertEquals(proofId, records.records.single().id)
            assertTrue(selfProofs.records.isEmpty())
            assertEquals(0, cryptography.calls.filterIsInstance<FakeSensingCryptography.Call.SignSelfProof>().size)
            assertNoActivityReference(coordinator, oldActivity)
            retainedOwners(recreated).forEach { owner ->
                assertFalse(owner.javaClass.declaredFields.any { Activity::class.java.isAssignableFrom(it.type) })
                assertNoActivityReference(owner, oldActivity)
            }

            // A new observation proves the original event callback still reaches the live proof.
            engine.emitDetection(enin = 8, rpid = "dd", detectedDisplayId = "device-4")
            controller.recreate()
            assertSame(coordinator, controller.get().eventJoinCoordinator)
            assertEquals(0, engine.disposeCalls)
            assertTrue(selfProofs.records.isEmpty())
            controller.get().finish()
            assertTrue(controller.get().isFinishing)
            assertFalse(controller.get().isChangingConfigurations)
            controller.pause().stop().destroy()
            assertEquals(1, engine.disposeCalls)
            assertFalse(engine.engineState.isScanning)
            assertEquals(1, cryptography.calls.filterIsInstance<FakeSensingCryptography.Call.SignSelfProof>().size)
            assertEquals(proofId, selfProofs.records.single().proofId)
            assertEquals(8L, selfProofs.records.single().eninEnd)
            assertEquals(4, coordinator.sessionAggregateSnapshot(proofId)?.observationCount)
            assertTrue(records.records.single().hasSelfProof)
            controller.get().viewModelStore.clear()
            assertEquals(1, engine.disposeCalls)
            assertEquals(1, selfProofs.records.size)
        } finally {
            if (!controller.get().isDestroyed) {
                controller.get().finish()
                controller.pause().stop().destroy()
            }
        }
    }

    @Test
    fun nativePermissionHostReattachesAndReleasesTheDestroyedActivity() {
        val controller = Robolectric.buildActivity(MainActivity::class.java).setup()
        try {
            val oldActivity = controller.get()
            val coordinator = requireNotNull(oldActivity.eventJoinCoordinator)
            val adapter = field<Any>(coordinator, "engine")
            val sdk = field<Any>(adapter, "engine")
            assertSame(oldActivity, field<Activity?>(sdk, "activity"))
            val oldWalletFlow = field<Any>(oldActivity, "walletBindingFlow")
            // The SDK may still owe a permission result when the host rotates.
            coordinator.requestBluetoothPermission { oldActivity.finish() }
            controller.recreate()
            val recreated = controller.get()
            assertSame(coordinator, recreated.eventJoinCoordinator)
            assertSame(recreated, field<Activity?>(sdk, "activity"))
            assertNotSame(oldWalletFlow, field<Any>(recreated, "walletBindingFlow"))
            assertNoActivityReference(coordinator, oldActivity)
            // Permission results arriving on the new host still go to the retained SDK.
            val permissionResults = mutableListOf<BluetoothPermissionState>()
            coordinator.bindBluetoothPermissionResult { permissionResults += it }
            recreated.onRequestPermissionsResult(2893, emptyArray(), intArrayOf())
            assertEquals(1, permissionResults.size)
            assertFalse("the retired permission UI callback must be detached", oldActivity.isFinishing)
            controller.get().finish()
            controller.pause().stop().destroy()
            assertNull(field<Activity?>(sdk, "activity"))
        } finally {
            if (!controller.get().isDestroyed) {
                controller.get().finish()
                controller.pause().stop().destroy()
            }
        }
    }

    private fun retainedOwners(activity: MainActivity): List<Any> =
        activity.viewModelStore.javaClass.declaredFields.flatMap { member ->
            member.isAccessible = true
            (member.get(activity.viewModelStore) as? Map<*, *>)?.values?.filterNotNull() ?: emptyList()
        }

    // GC is nondeterministic under Robolectric (the controller also keeps its old host).
    // Inspect the retained app/SDK graph instead, including callbacks and owner fields.
    private fun assertNoActivityReference(root: Any, oldActivity: Activity) {
        val visited = Collections.newSetFromMap(IdentityHashMap<Any, Boolean>())
        fun visit(value: Any?) {
            if (value == null || !visited.add(value)) return
            assertNotSame("retained session must release the old Activity", oldActivity, value)
            if (value is Map<*, *>) { value.values.forEach(::visit); return }
            if (value is Iterable<*>) { value.forEach(::visit); return }
            if (!value.javaClass.name.startsWith("org.levarac.")) return
            value.javaClass.declaredFields.filterNot { java.lang.reflect.Modifier.isStatic(it.modifiers) }.forEach {
                it.isAccessible = true
                visit(it.get(value))
            }
        }
        visit(root)
    }

    private fun <T> field(instance: Any, name: String): T = ReflectionHelpers.getField(instance, name)
}

/** Wallet transport construction needs a device Keystore; no wallet operation is performed here. */
@Implements(MetaMaskSdkTransport::class, isInAndroidSdk = false)
class ShadowRecreationWalletTransport {
    @Implementation
    fun __constructor__(context: Context, communicationClientModule: CommunicationClientModuleInterface) = Unit
}
