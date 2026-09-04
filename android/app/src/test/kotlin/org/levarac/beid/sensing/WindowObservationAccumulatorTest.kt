package org.levarac.beid.sensing

import java.io.IOException
import java.nio.file.Files
import java.util.UUID
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertFailsWith
import org.levarac.beid.shared.report.confirmUnsentWindowLedgerPersistence
import org.levarac.beid.shared.report.createUnsentWindowLedger
import org.levarac.beid.shared.report.openUnsentWindow
import org.levarac.beid.persistence.UnsentWindowLedgerStore
import org.levarac.parallax.submission.restoreStoredObservation

class WindowObservationAccumulatorTest {
    @Test
    fun boundaryClosesSignsAndDurablyWritesWithoutAUiObserver() {
        val directory = Files.createTempDirectory("window-accumulator").toFile()
        val ledgerFile = directory.resolve("ledger.snapshot")
        val crypto = VectorCryptography()
        val accumulator = WindowObservationAccumulator(
            context = { VECTOR_CONTEXT },
            cryptography = crypto,
            ledgerStore = UnsentWindowLedgerStore(ledgerFile),
            observationDirectory = directory.resolve("observations"),
            nowEpochSeconds = { 1_800_000_000.75 },
            newWindowId = sequenceIds(),
            ledgerInstanceId = { "000102030405060708090a0b0c0d0e0f" },
        )

        accumulator.observe(6_000_000, RPID_TWO, REPORTER_RPID, recording = false)
        accumulator.observe(6_000_000, RPID_ONE, REPORTER_RPID, recording = true)
        accumulator.observe(6_000_001, RPID_TWO, REPORTER_RPID, recording = true)

        assertContentEquals(EXPECTED_SIGNATURE_STRUCTURE.hexBytes(), crypto.signedBytes)
        val loaded = assertNotNull(UnsentWindowLedgerStore(ledgerFile).load())
        assertEquals(3L, loaded.persistenceRevision)
        val observation = directory.resolve("observations").listFiles().orEmpty().single()
        assertNotNull(restoreStoredObservation(observation.readBytes().toHex()))
    }

    @Test
    fun closingTwiceDoesNotWriteTheSameWindowTwice() {
        val directory = Files.createTempDirectory("window-no-double-write").toFile()
        val ledgerFile = directory.resolve("ledger.snapshot")
        val accumulator = WindowObservationAccumulator(
            context = { VECTOR_CONTEXT }, cryptography = VectorCryptography(),
            ledgerStore = UnsentWindowLedgerStore(ledgerFile), observationDirectory = directory.resolve("observations"),
            nowEpochSeconds = { 1_800_000_000.75 },
            newWindowId = { UUID.fromString("00112233-4455-6677-8899-aabbccddeeff") },
            ledgerInstanceId = { "000102030405060708090a0b0c0d0e0f" },
        )
        accumulator.observe(6_000_000, RPID_ONE, REPORTER_RPID, recording = true)
        accumulator.observe(6_000_000, RPID_TWO, REPORTER_RPID, recording = true)
        accumulator.close()
        accumulator.close()

        assertEquals(2L, assertNotNull(UnsentWindowLedgerStore(ledgerFile).load()).persistenceRevision)
        assertEquals(1, directory.resolve("observations").listFiles().orEmpty().size)
    }

    @Test
    fun contextNotReadyDoesNotCreateADurableOpenWindow() {
        val directory = Files.createTempDirectory("window-context-not-ready").toFile()
        val ledgerFile = directory.resolve("ledger.snapshot")
        val accumulator = WindowObservationAccumulator(
            context = { null }, cryptography = VectorCryptography(),
            ledgerStore = UnsentWindowLedgerStore(ledgerFile), observationDirectory = directory.resolve("observations"),
            nowEpochSeconds = { 1_800_000_000.75 },
            newWindowId = sequenceIds(), ledgerInstanceId = { "000102030405060708090a0b0c0d0e0f" },
        )

        accumulator.observe(6_000_000, RPID_ONE, REPORTER_RPID, recording = true)

        assertFalse(ledgerFile.exists(), "context-free input must remain transient, not strand a durable open row")
    }

    @Test
    fun boundaryPersistsEligibleBufferedWindowWhenVerifiedContextArrivedAfterItsLastDetection() {
        val directory = Files.createTempDirectory("window-late-context-boundary").toFile()
        val ledgerFile = directory.resolve("ledger.snapshot")
        var observationContext: WindowObservationContext? = null
        val cryptography = VectorCryptography()
        val accumulator = WindowObservationAccumulator(
            context = { observationContext }, cryptography = cryptography,
            ledgerStore = UnsentWindowLedgerStore(ledgerFile), observationDirectory = directory.resolve("observations"),
            nowEpochSeconds = { 1_800_000_000.75 },
            newWindowId = sequenceIds(), ledgerInstanceId = { "000102030405060708090a0b0c0d0e0f" },
        )
        accumulator.observe(6_000_000, RPID_TWO, REPORTER_RPID, recording = true)
        accumulator.observe(6_000_000, RPID_ONE, REPORTER_RPID, recording = true)

        observationContext = VECTOR_CONTEXT
        accumulator.observe(6_000_001, RPID_ONE, REPORTER_RPID, recording = false)

        assertContentEquals(EXPECTED_SIGNATURE_STRUCTURE.hexBytes(), cryptography.signedBytes)
        assertEquals(2L, assertNotNull(UnsentWindowLedgerStore(ledgerFile).load()).persistenceRevision)
        assertEquals(1, directory.resolve("observations").listFiles().orEmpty().size)
    }

    @Test
    fun ineligibleEvidenceDoesNotCreateADurableOpenWindow() {
        val directory = Files.createTempDirectory("window-ineligible").toFile()
        val ledgerFile = directory.resolve("ledger.snapshot")
        val accumulator = WindowObservationAccumulator(
            context = { VECTOR_CONTEXT }, cryptography = VectorCryptography(),
            ledgerStore = UnsentWindowLedgerStore(ledgerFile), observationDirectory = directory.resolve("observations"),
            nowEpochSeconds = { 1_800_000_000.75 },
            newWindowId = sequenceIds(), ledgerInstanceId = { "000102030405060708090a0b0c0d0e0f" },
        )

        accumulator.observe(6_000_000, "not-an-rpid", REPORTER_RPID, recording = true)
        accumulator.close()

        assertFalse(ledgerFile.exists(), "shared-ineligible evidence must never create an uncloseable durable row")
    }

    @Test
    fun failedOpenPersistenceDoesNotAdvanceMemoryAndCanRetryTheSameWindow() {
        val directory = Files.createTempDirectory("window-open-persistence-retry").toFile()
        val ledgerFile = directory.resolve("ledger.snapshot")
        val accumulator = WindowObservationAccumulator(
            context = { VECTOR_CONTEXT }, cryptography = VectorCryptography(),
            ledgerStore = UnsentWindowLedgerStore(ledgerFile), observationDirectory = directory.resolve("observations"),
            nowEpochSeconds = { 1_800_000_000.75 },
            newWindowId = { UUID.fromString(WINDOW_ID) },
            ledgerInstanceId = { "000102030405060708090a0b0c0d0e0f" },
        )
        check(ledgerFile.mkdir())

        assertFailsWith<IOException> {
            accumulator.observe(6_000_000, RPID_ONE, REPORTER_RPID, recording = true)
        }

        check(ledgerFile.delete())
        accumulator.observe(6_000_000, RPID_ONE, REPORTER_RPID, recording = true)
        accumulator.observe(6_000_000, RPID_TWO, REPORTER_RPID, recording = true)
        accumulator.close()

        assertEquals(2L, assertNotNull(UnsentWindowLedgerStore(ledgerFile).load()).persistenceRevision)
        assertEquals(1, directory.resolve("observations").listFiles().orEmpty().size)
    }

    @Test
    fun relaunchReconcilesAnArtifactMovedBeforeItsLedgerClose() {
        val source = Files.createTempDirectory("window-recovery-source").toFile()
        val sourceAccumulator = WindowObservationAccumulator(
            context = { VECTOR_CONTEXT }, cryptography = VectorCryptography(),
            ledgerStore = UnsentWindowLedgerStore(source.resolve("ledger.snapshot")),
            observationDirectory = source.resolve("observations"), nowEpochSeconds = { 1_800_000_000.75 },
            newWindowId = sequenceIds(), ledgerInstanceId = { "000102030405060708090a0b0c0d0e0f" },
        )
        sourceAccumulator.observe(6_000_000, RPID_ONE, REPORTER_RPID, recording = true)
        sourceAccumulator.observe(6_000_000, RPID_TWO, REPORTER_RPID, recording = true)
        sourceAccumulator.close()
        val sourceArtifact = source.resolve("observations").listFiles().orEmpty().single()
        val digest = sourceArtifact.name.removeSuffix(".cose").substringAfterLast("--")

        val recovered = Files.createTempDirectory("window-recovery-target").toFile()
        val ledgerFile = recovered.resolve("ledger.snapshot")
        val ledgerStore = UnsentWindowLedgerStore(ledgerFile)
        var ledger = assertNotNull(createUnsentWindowLedger("000102030405060708090a0b0c0d0e0f").ledger)
        val opened = openUnsentWindow(ledger, WINDOW_ID)
        ledgerStore.persist(opened)
        ledger = confirmUnsentWindowLedgerPersistence(ledger = opened.ledger, revision = opened.persistenceRevision).ledger
        assertNotNull(ledger)
        val observations = recovered.resolve("observations").also { it.mkdirs() }
        sourceArtifact.copyTo(observations.resolve("$WINDOW_ID--$digest.cose"))

        WindowObservationAccumulator(
            context = { null }, cryptography = VectorCryptography(), ledgerStore = ledgerStore,
            observationDirectory = observations, nowEpochSeconds = { 1_800_000_001.0 },
            ledgerInstanceId = { error("existing ledger must be reused") }, reconcileAfterRelaunch = true,
        )

        assertEquals(2L, assertNotNull(ledgerStore.load()).persistenceRevision)
    }

    private class VectorCryptography : FakeSensingCryptography(
        eventSigningPublicKeyResult = PUBLIC_KEY.hexBytes(),
        signWindowReportResult = SensingRecoverableSignature(SIGNATURE_R.hexBytes(), SIGNATURE_S.hexBytes(), 0),
    ) {
        var signedBytes: ByteArray? = null
        override fun signWindowReport(eventCode: String, bytes: ByteArray): SensingRecoverableSignature {
            signedBytes = bytes.copyOf()
            return super.signWindowReport(eventCode, bytes)
        }
    }

    private companion object {
        fun sequenceIds(): () -> UUID {
            val values = ArrayDeque(
                listOf(
                    UUID.fromString("00112233-4455-6677-8899-aabbccddeeff"),
                    UUID.fromString("11112233-4455-6677-8899-aabbccddeeff"),
                ),
            )
            return { values.removeFirst() }
        }
        const val PUBLIC_KEY = "0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798"
        const val REPORTER_RPID = "0110101010101010101010101010101010"
        const val RPID_ONE = "0111111111111111111111111111111111"
        const val RPID_TWO = "0122222222222222222222222222222222"
        const val SIGNATURE_R = "d9b39668ed2e92db7226461f059a1ecd06a732bd5bfdae0b23d43390a8025349"
        const val SIGNATURE_S = "462b3ecfaa8305881ad1a8b8960e9f3f1e6770683e0c178543613de942c8b765"
        const val EXPECTED_SIGNATURE_STRUCTURE = "846a5369676e6174757265315839a301382e0378286170706c69636174696f6e2f766e642e6c6576617261632e6f62736572766174696f6e2b63626f7204485ef036280edf16eb40590109a80101025000112233445566778899aabbccddeeff0378196c6576617261632e6d757475616c2d73656e73696e672f763104582021212121212121212121212121212121212121212121212121212121212121210558210279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798061a6b49d20007510110101010101010101010101010101010085875a50158202222222222222222222222222222222222222222222222222222222222222222021a005b8d80038251011111111111111111111111111111111151012222222222222222222222222222222204f6055820abababababababababababababababababababababababababababababababab"
        const val WINDOW_ID = "00112233-4455-6677-8899-aabbccddeeff"
        val VECTOR_CONTEXT = WindowObservationContext("event", "21".repeat(32), "22".repeat(32), "ab".repeat(32))
    }
}

private fun String.hexBytes(): ByteArray = chunked(2).map { it.toInt(16).toByte() }.toByteArray()
private fun ByteArray.toHex(): String = joinToString("") { "%02x".format(it.toInt() and 0xff) }
