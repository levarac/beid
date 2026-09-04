package org.levarac.beid.sensing

import java.nio.file.Files
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runTest
import org.levarac.beid.persistence.BindingRecordStore
import org.levarac.beid.persistence.SelfProofRecordStore
import org.levarac.beid.persistence.UnsentWindowLedgerStore
import org.levarac.beid.shared.report.createUnsentWindowObservationRecoveryInput
import org.levarac.beid.shared.report.reconcileUnsentWindowLedgerAfterRelaunch

@OptIn(ExperimentalCoroutinesApi::class)
class EventJoinCoordinatorWindowLedgerTest {
    @Test
    fun joiningAnotherEventClosesTheOpenWindowBeforeAcceptingItsDetections() = runTest {
        val directory = Files.createTempDirectory("window-event-change").toFile()
        val owner = WindowObservationRuntimeOwner(
            newWindowId = { java.util.UUID.fromString("00112233-4455-6677-8899-aabbccddeeff") },
            ledgerInstanceId = { "000102030405060708090a0b0c0d0e0f" },
        )
        val cryptography = vectorCryptography()
        val firstEngine = FakeEventJoinEngine()
        val first = coordinator(firstEngine, directory, owner, cryptography)
        first.joinEvent("event-a")
        first.acceptVerifiedObservationContext(EVENT_A_VECTOR_CONTEXT)
        emitRecordingWindow(firstEngine)
        first.dispose()

        val replacementEngine = FakeEventJoinEngine()
        val replacement = coordinator(replacementEngine, directory, owner, cryptography)
        replacement.joinEvent("event-b")
        replacement.acceptVerifiedObservationContext(EVENT_B_DISTINCT_CONTEXT)
        replacementEngine.emitDetection(6_000_000, RPID_THREE, "device-b", REPORTER_RPID)
        replacement.leaveEvent()

        val sign = cryptography.calls.filterIsInstance<FakeSensingCryptography.Call.SignWindowReport>().single()
        assertEquals("event-a", sign.eventCode)
        val signatureStructureHex = sign.bytes.toHexString()
        assertTrue(EVENT_A_VECTOR_CONTEXT.eventIdHex in signatureStructureHex)
        assertTrue(EVENT_A_VECTOR_CONTEXT.eventDefinitionDigestHex in signatureStructureHex)
        assertFalse(EVENT_B_DISTINCT_CONTEXT.eventIdHex in signatureStructureHex)
        assertFalse(EVENT_B_DISTINCT_CONTEXT.eventDefinitionDigestHex in signatureStructureHex)
        assertFalse(RPID_THREE in signatureStructureHex, "event-B RPID must not be added to event-A's signed window")
    }

    @Test
    fun disposedCoordinatorCannotReplaceTheReplacementEventContextWithALateCompletion() = runTest {
        val directory = Files.createTempDirectory("window-late-context").toFile()
        val owner = WindowObservationRuntimeOwner(
            newWindowId = { java.util.UUID.fromString("00112233-4455-6677-8899-aabbccddeeff") },
            ledgerInstanceId = { "000102030405060708090a0b0c0d0e0f" },
        )
        val cryptography = vectorCryptography()
        val firstEngine = FakeEventJoinEngine()
        val first = coordinator(firstEngine, directory, owner, cryptography)
        first.joinEvent("event-a")

        first.dispose()

        val replacementEngine = FakeEventJoinEngine()
        val replacement = coordinator(replacementEngine, directory, owner, cryptography)
        replacement.joinEvent("event-b")
        replacement.acceptVerifiedObservationContext(EVENT_B_CONTEXT)

        first.acceptVerifiedObservationContext(EVENT_A_CONTEXT)
        emitRecordingWindow(replacementEngine)
        replacement.leaveEvent()

        val contextCalls = cryptography.calls.filterIsInstance<FakeSensingCryptography.Call.EventSigningPublicKey>()
        assertTrue(contextCalls.isNotEmpty())
        assertTrue(contextCalls.all { it.eventCode == "event-b" }, "late event-A completion must not select event-A signing identity")
        val sign = cryptography.calls.filterIsInstance<FakeSensingCryptography.Call.SignWindowReport>().single()
        assertEquals("event-b", sign.eventCode)
        val signatureStructureHex = sign.bytes.toHexString()
        assertTrue(EVENT_B_CONTEXT.eventIdHex in signatureStructureHex)
        assertTrue(EVENT_B_CONTEXT.eventDefinitionDigestHex in signatureStructureHex)
        assertFalse(EVENT_A_CONTEXT.eventIdHex in signatureStructureHex)
        assertFalse(EVENT_A_CONTEXT.eventDefinitionDigestHex in signatureStructureHex)
    }

    @Test
    fun replacementCoordinatorContinuesAndClosesTheSameWindowExactlyOnce() = runTest {
        val directory = Files.createTempDirectory("window-config-replacement").toFile()
        val ledgerFile = directory.resolve("unsent-window-ledger-v1.snapshot")
        val owner = WindowObservationRuntimeOwner(
            newWindowId = { java.util.UUID.fromString("00112233-4455-6677-8899-aabbccddeeff") },
            ledgerInstanceId = { "000102030405060708090a0b0c0d0e0f" },
        )
        val firstEngine = FakeEventJoinEngine()
        val first = coordinator(firstEngine, directory, owner)
        first.joinEvent("event")
        first.acceptVerifiedObservationContext(VECTOR_CONTEXT)
        emitRecordingWindow(firstEngine)

        first.dispose()

        val replacementEngine = FakeEventJoinEngine()
        val replacement = coordinator(replacementEngine, directory, owner)
        replacement.joinEvent("event")
        replacement.acceptVerifiedObservationContext(VECTOR_CONTEXT)
        emitRecordingWindow(replacementEngine)
        replacement.leaveEvent()

        val loaded = requireNotNull(UnsentWindowLedgerStore(ledgerFile).load())
        assertEquals(2L, loaded.persistenceRevision, "one logical row has exactly one open and one close transition")
        assertEquals(1, directory.resolve("canonical-observations-v1").listFiles().orEmpty().size)
        val relaunchProbe = reconcileUnsentWindowLedgerAfterRelaunch(
            requireNotNull(loaded.ledger),
            createUnsentWindowObservationRecoveryInput(),
        )
        assertFalse(relaunchProbe.changed, "no orphan open row may remain for later relaunch cleanup")
    }

    @Test
    fun configurationDestroyDoesNotCloseTheBusinessWindow() = runTest {
        val directory = Files.createTempDirectory("window-config-destroy").toFile()
        val ledgerFile = directory.resolve("ledger.snapshot")
        val accumulator = WindowObservationAccumulator(
            context = { WindowObservationContext("event", "21".repeat(32), "22".repeat(32), "ab".repeat(32)) },
            cryptography = FakeSensingCryptography(
                eventSigningPublicKeyResult = PUBLIC_KEY.chunked(2).map { it.toInt(16).toByte() }.toByteArray(),
                signWindowReportResult = SensingRecoverableSignature(
                    SIGNATURE_R.chunked(2).map { it.toInt(16).toByte() }.toByteArray(),
                    SIGNATURE_S.chunked(2).map { it.toInt(16).toByte() }.toByteArray(),
                    0,
                ),
            ),
            ledgerStore = UnsentWindowLedgerStore(ledgerFile),
            observationDirectory = directory.resolve("observations"),
            nowEpochSeconds = { 1_800_000_000.0 },
            newWindowId = { java.util.UUID.fromString("00112233-4455-6677-8899-aabbccddeeff") },
            ledgerInstanceId = { "000102030405060708090a0b0c0d0e0f" },
        )
        accumulator.observe(6_000_000, RPID_TWO, REPORTER_RPID, recording = false)
        accumulator.observe(6_000_000, RPID_ONE, REPORTER_RPID, recording = true)
        val engine = FakeEventJoinEngine()
        val coordinator = EventJoinCoordinator(
            engine = engine, nowEpochMillis = { testScheduler.currentTime }, coroutineScope = backgroundScope,
            sensingCryptography = FakeSensingCryptography(),
            selfProofRecordStore = SelfProofRecordStore(newTempRecordFile("self-proofs")),
            bindingRecordStore = BindingRecordStore(newTempRecordFile("binding-records")),
            injectedWindowAccumulator = accumulator,
        )

        coordinator.dispose()

        assertEquals(1L, UnsentWindowLedgerStore(ledgerFile).load()?.persistenceRevision)
        assertEquals(0, directory.resolve("observations").listFiles().orEmpty().size)
    }

    private fun kotlinx.coroutines.test.TestScope.coordinator(
        engine: FakeEventJoinEngine,
        directory: java.io.File,
        owner: WindowObservationRuntimeOwner,
        cryptography: FakeSensingCryptography = vectorCryptography(),
    ): EventJoinCoordinator = EventJoinCoordinator(
        engine = engine,
        nowEpochMillis = { 1_800_000_000_000L },
        coroutineScope = backgroundScope,
        sensingCryptography = cryptography,
        selfProofRecordStore = SelfProofRecordStore(newTempRecordFile("self-proofs")),
        bindingRecordStore = BindingRecordStore(newTempRecordFile("binding-records")),
        ledgerFilesDir = directory,
        windowObservationRuntimeOwner = owner,
    )

    private fun emitRecordingWindow(engine: FakeEventJoinEngine) {
        engine.emitDetection(6_000_000, RPID_ONE, "device-1", REPORTER_RPID)
        engine.emitDetection(6_000_000, RPID_TWO, "device-2", REPORTER_RPID)
        engine.emitDetection(6_000_000, RPID_ONE, "device-3", REPORTER_RPID)
    }

    private fun vectorCryptography(): FakeSensingCryptography = FakeSensingCryptography(
        eventSigningPublicKeyResult = PUBLIC_KEY.chunked(2).map { it.toInt(16).toByte() }.toByteArray(),
        signWindowReportResult = SensingRecoverableSignature(
            SIGNATURE_R.chunked(2).map { it.toInt(16).toByte() }.toByteArray(),
            SIGNATURE_S.chunked(2).map { it.toInt(16).toByte() }.toByteArray(),
            0,
        ),
    )

    private companion object {
        const val PUBLIC_KEY = "0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798"
        const val REPORTER_RPID = "0110101010101010101010101010101010"
        const val RPID_ONE = "0111111111111111111111111111111111"
        const val RPID_TWO = "0122222222222222222222222222222222"
        const val RPID_THREE = "0133333333333333333333333333333333"
        const val SIGNATURE_R = "d9b39668ed2e92db7226461f059a1ecd06a732bd5bfdae0b23d43390a8025349"
        const val SIGNATURE_S = "462b3ecfaa8305881ad1a8b8960e9f3f1e6770683e0c178543613de942c8b765"
        val VECTOR_CONTEXT = WindowObservationContext("event", "21".repeat(32), "22".repeat(32), "ab".repeat(32))
        val EVENT_A_VECTOR_CONTEXT = WindowObservationContext("event-a", "21".repeat(32), "22".repeat(32), "ab".repeat(32))
        val EVENT_A_CONTEXT = WindowObservationContext("event-a", "31".repeat(32), "32".repeat(32), "ab".repeat(32))
        val EVENT_B_CONTEXT = WindowObservationContext("event-b", "21".repeat(32), "22".repeat(32), "ab".repeat(32))
        val EVENT_B_DISTINCT_CONTEXT = WindowObservationContext("event-b", "41".repeat(32), "42".repeat(32), "ab".repeat(32))
    }
}

private fun ByteArray.toHexString(): String = joinToString("") { "%02x".format(it.toInt() and 0xff) }
