package org.levarac.beid.ui.screens

import java.util.UUID
import kotlin.coroutines.CoroutineContext
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestCoroutineScheduler
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import org.levarac.beid.sensing.EventJoinSession
import org.levarac.beid.sensing.EventJoinUiState
import org.levarac.beid.sensing.ScanEventSession
import org.levarac.beid.sensing.ScanPhase
import org.levarac.beid.sensing.ScanSessionMetrics

@OptIn(ExperimentalCoroutinesApi::class)
class ScanStopConfirmationTest {
    private val main = StandardTestDispatcher()
    private val metricsScheduler = TestCoroutineScheduler()
    private val metricsQueue = StandardTestDispatcher(metricsScheduler)
    private var evaluatingOffMain = false
    private val metricsDispatcher = object : CoroutineDispatcher() {
        override fun dispatch(context: CoroutineContext, block: Runnable) {
            metricsQueue.dispatch(context) {
                evaluatingOffMain = true
                try { block.run() } finally { evaluatingOffMain = false }
            }
        }
    }
    private val event = ScanEventSession("ABC123")
    private val fake = FakeEventJoinSession(EventJoinUiState.Sensing(ScanPhase.Recording(event, 3)))
    private var proofId = UUID.randomUUID()
    private val evaluations = mutableListOf<Pair<Int, Boolean>>()
    private fun evaluator(value: Int): () -> ScanSessionMetrics = {
        evaluations += value to evaluatingOffMain
        ScanSessionMetrics(windowCount = value)
    }
    private val metrics = MutableStateFlow(evaluator(1))
    private val session = object : EventJoinSession by fake {
        override val currentProofId get() = proofId
        override fun hasStoredProof(proofId: UUID) = proofId == currentProofId
        override val scanSessionMetrics = metrics
    }

    // This fixture uses the original constructor so the tests execute on the unfixed head.
    private fun model() = EventJoinViewModel(session)

    @BeforeTest fun setUp() = Dispatchers.setMain(main)
    @AfterTest fun tearDown() = Dispatchers.resetMain()

    private fun finishMetrics() {
        main.scheduler.runCurrent()
        metricsScheduler.runCurrent()
        main.scheduler.runCurrent()
    }

    @Test fun openingShowsConfirmationImmediatelyWithZeroMetricsUntilEvaluationCompletes() {
        val model = model()
        main.scheduler.runCurrent()
        assertTrue(evaluations.isEmpty(), "hidden confirmations must not aggregate")
        model.requestScanClose()
        assertNotNull(model.uiState.value.stopConfirmation)
        assertTrue(evaluations.isEmpty(), "opening must not synchronously replay observations")
        assertEquals(ScanSessionMetrics(), model.uiState.value.scanSessionMetrics)
        finishMetrics()
        assertEquals(1, model.uiState.value.scanSessionMetrics.windowCount)
    }

    @Test fun openingEvaluatesOnlyOnMetricsDispatcher() {
        val model = model()
        main.scheduler.runCurrent()
        model.requestScanClose()
        finishMetrics()
        assertEquals(listOf(1 to true), evaluations, "the evaluator must run off main")
    }

    @Test fun newDetectionEvaluatesOnlyOnMetricsDispatcher() {
        val model = model()
        model.requestScanClose()
        finishMetrics()
        evaluations.clear()
        metrics.value = evaluator(2)
        main.scheduler.runCurrent()
        assertTrue(evaluations.isEmpty(), "detections must not aggregate on test-main")
        finishMetrics()
        assertEquals(listOf(2 to true), evaluations)
        assertEquals(2, model.uiState.value.scanSessionMetrics.windowCount)
    }

    @Test fun rapidDetectionsConflateWhileMetricsDispatcherIsBusy() {
        val model = model()
        model.requestScanClose()
        finishMetrics()
        evaluations.clear()
        // Keep the worker queued while main continues receiving distinct detections.
        for (value in 2..101) {
            metrics.value = evaluator(value)
            main.scheduler.runCurrent()
        }
        repeat(3) { finishMetrics() }
        assertTrue(evaluations.size in 1..2, "expected at most in-flight + latest; got ${evaluations.size}")
        assertTrue(evaluations.all { it.second }, "every replay must use the metrics dispatcher")
        assertEquals(101, evaluations.last().first)
        assertEquals(101, model.uiState.value.scanSessionMetrics.windowCount)
    }

    @Test fun externalIdleClearsPendingConfirmation() {
        val model = model()
        model.requestScanClose()
        finishMetrics()
        fake.emit(EventJoinUiState.Idle)
        main.scheduler.runCurrent()
        assertNull(model.uiState.value.stopConfirmation)
        metrics.value = evaluator(2)
        finishMetrics()
        assertEquals(1, evaluations.size, "ended sessions must stop evaluating")
        assertEquals(0, fake.leaveEventCallCount)
    }

    @Test fun differentEventClearsPendingConfirmation() {
        val model = model()
        model.requestScanClose()
        finishMetrics()
        fake.emit(EventJoinUiState.Sensing(ScanPhase.Recording(ScanEventSession("OTHER"), 3)))
        main.scheduler.runCurrent()
        assertNull(model.uiState.value.stopConfirmation)
        model.confirmStopSensing()
        assertEquals(0, fake.leaveEventCallCount)
    }

    @Test fun newProofForSameEventClearsPendingConfirmation() {
        val model = model()
        model.requestScanClose()
        finishMetrics()
        proofId = UUID.randomUUID()
        fake.emit(EventJoinUiState.Sensing(ScanPhase.Recording(event, 4)))
        main.scheduler.runCurrent()
        assertNull(model.uiState.value.stopConfirmation)
    }

    @Test fun liveDetectionAndSignalLossPreserveConfirmation() {
        val model = model()
        model.requestScanClose()
        finishMetrics()
        val confirmation = model.uiState.value.stopConfirmation
        fake.emit(EventJoinUiState.Sensing(ScanPhase.Recording(event, 4)))
        main.scheduler.runCurrent()
        assertEquals(confirmation, model.uiState.value.stopConfirmation)
        fake.emit(EventJoinUiState.Sensing(ScanPhase.SignalLost(event, 4)))
        main.scheduler.runCurrent()
        assertEquals(confirmation, model.uiState.value.stopConfirmation)
    }

    @Test fun endingSessionWithEvaluationQueuedCannotPublishOldMetrics() {
        val model = model()
        model.requestScanClose()
        main.scheduler.runCurrent()
        fake.emit(EventJoinUiState.Idle)
        main.scheduler.runCurrent()
        finishMetrics()
        assertNull(model.uiState.value.stopConfirmation)
        assertEquals(ScanSessionMetrics(), model.uiState.value.scanSessionMetrics)
    }

    @Test fun keepSensingCancelsQueuedMetricsAndReopeningStartsFresh() {
        val model = model()
        model.requestScanClose()
        main.scheduler.runCurrent()
        model.keepSensing()
        metrics.value = evaluator(2)
        finishMetrics()
        assertTrue(evaluations.isEmpty(), "dismissed confirmations must cancel queued replay")
        model.requestScanClose()
        assertEquals(ScanSessionMetrics(), model.uiState.value.scanSessionMetrics)
        finishMetrics()
        assertEquals(listOf(2 to true), evaluations)
    }
}
