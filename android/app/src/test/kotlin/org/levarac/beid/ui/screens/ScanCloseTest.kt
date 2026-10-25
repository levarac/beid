package org.levarac.beid.ui.screens

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.semantics.SemanticsActions
import java.io.File
import java.util.UUID
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNull
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runTest
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith
import org.levarac.beid.persistence.BindingRecordStore
import org.levarac.beid.persistence.SelfProofRecordStore
import org.levarac.beid.persistence.ProofRecordStore
import org.levarac.beid.sensing.ProofRecordingBridge
import org.levarac.beid.sensing.EventBindingState
import org.levarac.beid.sensing.EventJoinCoordinator
import org.levarac.beid.sensing.EventJoinSession
import org.levarac.beid.sensing.EventJoinUiState
import org.levarac.beid.sensing.FakeEventJoinEngine
import org.levarac.beid.sensing.FakeNearbyEventRegistry
import org.levarac.beid.sensing.FakeSensingCryptography
import org.levarac.beid.sensing.NearbyEventPromotionFixture
import org.levarac.beid.sensing.ScanEventSession
import org.levarac.beid.sensing.ScanPhase
import org.levarac.beid.sensing.joinPromotedVectorEvent
import org.levarac.beid.ui.theme.BeidAppTheme
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
@OptIn(ExperimentalCoroutinesApi::class)
class ScanCloseTest {
    @get:Rule val compose = createComposeRule()
    @get:Rule val files = TemporaryFolder()

    private val event = ScanEventSession(eventCode = "ABC123")

    @Test fun closeFromIdlePhase() = closesToHome(ScanPhase.Idle)
    @Test fun closeFromSensing() = closesToHome(ScanPhase.Sensing)
    @Test fun closeFromEventFound() = closesToHome(ScanPhase.EventFound(event))
    @Test fun closeFromRecording() = closesToHome(ScanPhase.Recording(event, 3))
    @Test fun closeFromSignalLost() = closesToHome(ScanPhase.SignalLost(event, 3))

    private fun closesToHome(phase: ScanPhase) {
        val fake = FakeEventJoinSession(EventJoinUiState.Sensing(phase))
        val session = object : EventJoinSession by fake {
            override fun leaveEvent() {
                fake.leaveEvent()
                fake.emit(EventJoinUiState.Idle)
            }
        }
        var accountOpens = 0
        val model = EventJoinViewModel(session)
        compose.setContent {
            BeidAppTheme {
                EventJoinScreen(model, onOpenAccount = { accountOpens++ }, onOpenManualEventCode = {})
            }
        }
        // Account remains reachable in every phase, independently of Close.
        compose.onNodeWithTag(EventJoinScreenTestTags.ACCOUNT_ENTRY).assertIsDisplayed().performClick()
        assertEquals(1, accountOpens)
        compose.onNodeWithText("Close").assertIsDisplayed().performClick()
        compose.onNodeWithTag(EventJoinScreenTestTags.NEARBY_EVENT_LIST).assertIsDisplayed()
        compose.onNodeWithText("Close").assertDoesNotExist()
        compose.onNodeWithTag(EventJoinScreenTestTags.ACCOUNT_ENTRY).assertIsDisplayed()
        assertEquals(1, fake.leaveEventCallCount)
        assertEquals(EventJoinUiState.Idle, model.uiState.value.sessionState)
    }

    @Test fun closeFinalizesRecordingThroughExistingCoordinatorLeavePath() = closesRealSession(signalLost = false)
    @Test fun closeFinalizesSignalLostThroughExistingCoordinatorLeavePath() = closesRealSession(signalLost = true)

    @Test fun keepSensingPreservesRecording() = closesRealSession(keepSensing = true)
    @Test fun keepSensingPreservesSignalLost() = closesRealSession(signalLost = true, keepSensing = true)
    @Test fun staleConfirmationCannotFinalizeNewerSession() = closesRealSession(replaceSession = true)

    private fun closesRealSession(
        signalLost: Boolean = false,
        keepSensing: Boolean = false,
        replaceSession: Boolean = false,
    ) = runTest {
        val engine = FakeEventJoinEngine()
        val registry = FakeNearbyEventRegistry()
        val proofFile = File(files.root, "self-proofs.json")
        val proofs = SelfProofRecordStore(proofFile)
        val coordinator = EventJoinCoordinator(
            engine = engine,
            nearbyRegistry = registry,
            nowEpochMillis = { NearbyEventPromotionFixture.VECTOR_NOW_EPOCH_MILLIS + testScheduler.currentTime },
            coroutineScope = backgroundScope,
            sensingCryptography = FakeSensingCryptography(),
            selfProofRecordStore = proofs,
            bindingRecordStore = BindingRecordStore(File(files.root, "bindings.json")),
        )
        val collected = mutableListOf<UUID>()
        val records = ProofRecordStore(File(files.root, "proof-records.json"))
        val bridge = coordinator.sharedProofRecordingBridge(ProofRecordingBridge(records))
        coordinator.onProofCollected = { id, session, peers ->
            collected += id
            bridge.onProofCollected(id, session, peers)
        }
        try {
            joinPromotedVectorEvent(coordinator, engine, registry)
            engine.emitDetection(enin = 1, rpid = "aa", detectedDisplayId = "device-1")
            engine.emitDetection(enin = 2, rpid = "bb", detectedDisplayId = "device-2")
            engine.emitDetection(enin = 3, rpid = "cc", detectedDisplayId = "device-3")
            assertIs<ScanPhase.Recording>(assertIs<EventJoinUiState.Sensing>(coordinator.state.value).phase)
            if (signalLost) coordinator.simulateSignalLost()
            var leaveCalls = 0
            val session = object : EventJoinSession by coordinator {
                override fun leaveEvent() {
                    leaveCalls++
                    coordinator.leaveEvent()
                }
            }
            val model = EventJoinViewModel(session)
            compose.setContent {
                BeidAppTheme { EventJoinScreen(model, onOpenAccount = {}, onOpenManualEventCode = {}) }
            }

            compose.onNodeWithText("Close").assertIsDisplayed().performClick()

            compose.onNodeWithText("Stop sensing?").performScrollTo().assertIsDisplayed()
            compose.onNodeWithText("Stop sensing to seal and keep what you've recorded on this phone. You can sense this event again later.")
                .performScrollTo().assertIsDisplayed()
            compose.onNodeWithText("SO FAR").performScrollTo().assertIsDisplayed()
            listOf("MUTUAL", "DETECTED", "WINDOWS").forEach {
                compose.onNodeWithText(it).performScrollTo().assertIsDisplayed()
            }
            assertEquals(0, leaveCalls)
            assertEquals(0, proofs.records.size)
            val liveState = coordinator.state.value
            val originalProof = collected.single()
            if (keepSensing) {
                compose.onNodeWithText("Keep sensing").performScrollTo().assertIsDisplayed().performClick()
                compose.onNodeWithText("Stop sensing?").assertDoesNotExist()
                assertEquals(liveState, coordinator.state.value)
                assertEquals(originalProof, records.records.single().id)
                assertEquals(0, leaveCalls)
                assertEquals(0, proofs.records.size)
                return@runTest
            }
            // Retain the old callback before any external session change removes its screen.
            val confirm = compose.onNodeWithText("Stop and keep record").performScrollTo().assertIsDisplayed()
                .fetchSemanticsNode().config[SemanticsActions.OnClick].action!!
            if (replaceSession) {
                coordinator.leaveEvent()
                joinPromotedVectorEvent(coordinator, engine, registry)
                engine.emitDetection(enin = 4, rpid = "dd", detectedDisplayId = "device-4")
                engine.emitDetection(enin = 5, rpid = "ee", detectedDisplayId = "device-5")
                engine.emitDetection(enin = 6, rpid = "ff", detectedDisplayId = "device-6")
                assertEquals(2, collected.size)
                compose.onNodeWithText("Stop sensing?").assertDoesNotExist()
            }
            val beforeConfirm = coordinator.state.value
            // Invoke the same captured callback twice, including after its screen disappears.
            compose.runOnIdle { confirm(); confirm() }
            if (replaceSession) {
                assertEquals(0, leaveCalls)
                assertEquals(beforeConfirm, coordinator.state.value)
                compose.onNodeWithText("Stop sensing?").assertDoesNotExist()
                assertEquals(1, proofs.records.size)
                return@runTest
            }

            compose.onNodeWithTag(EventJoinScreenTestTags.NEARBY_EVENT_LIST).assertIsDisplayed()
            assertEquals(1, leaveCalls)
            assertEquals(EventJoinUiState.Idle, coordinator.state.value)
            assertNull(engine.getCurrentEventCode())
            assertNull(engine.configuredRelayVerifier)
            assertEquals(EventBindingState.None, coordinator.bindingState)
            assertFalse(coordinator.recordingCeremonyShown)
            assertEquals(collected.single(), SelfProofRecordStore(proofFile).records.single().proofId)
            // Close ends the session; like iOS reset(), it preserves automatic transport.
            assertEquals(0, engine.disposeCalls)
            assertEquals(true, engine.engineState.isScanning)
            assertEquals(true, engine.engineState.isAdvertising)
            coordinator.dispose()
            assertEquals(1, SelfProofRecordStore(proofFile).records.size)
        } finally {
            coordinator.dispose()
        }
    }
}
