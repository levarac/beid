package org.levarac.beid.sensing

import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.security.MessageDigest
import java.time.Instant
import java.util.UUID
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.runTest
import org.levarac.beid.persistence.BindingRecordStore
import org.levarac.beid.persistence.ProofRecord
import org.levarac.beid.persistence.ProofRecordStore
import org.levarac.beid.persistence.ReportProofLinkContract
import org.levarac.beid.persistence.SelfProofRecordStore
import org.levarac.beid.persistence.SubmissionRecordStore
import org.levarac.beid.persistence.UnsentWindowLedgerStore
import org.levarac.beid.persistence.WindowObservationDraftStore
import org.levarac.parallax.registry.EventDefinitionResolution

@OptIn(ExperimentalCoroutinesApi::class)
class ReportProofLinkWiringTest {
    @Test
    fun openingLinksExactlyOnceBeforeCloseAndSurvivesRestart() {
        val directory = directory()
        val store = ReportProofLinkContract(linkFile(directory))
        val accumulator = accumulator(directory, store)
        observe(accumulator, 6_000_000, PROOF)
        assertEquals(listOf(WINDOW to PROOF), store.links(), "the durable open must already have its link")
        assertNotNull(WindowObservationDraftStore(directory.resolve("draft.snapshot")).load())
        assertNotNull(SubmissionRecordStore(SubmissionRecordStore.defaultFile(directory)).recordFor(WINDOW.toString()))
        val original = linkFile(directory).readBytes()
        assertTrue(accumulator.close())
        assertTrue(accumulator.close())
        assertContentEquals(original, linkFile(directory).readBytes())
        assertEquals(listOf(WINDOW to PROOF), ReportProofLinkContract(linkFile(directory)).links())
        assertNotNull(SubmissionRecordStore(SubmissionRecordStore.defaultFile(directory)).recordFor(WINDOW.toString()))
    }

    @Test
    fun eninBoundaryLinksEachWindowAtItsOwnOpen() {
        val directory = directory()
        val store = ReportProofLinkContract(linkFile(directory))
        val accumulator = accumulator(directory, store)
        observe(accumulator, 6_000_000, PROOF)
        assertEquals(listOf(WINDOW to PROOF), store.links())
        observe(accumulator, 6_000_001, PROOF)
        assertEquals(listOf(WINDOW to PROOF, OTHER_WINDOW to PROOF), store.links())
    }

    @Test
    fun sessionsInTheSameEninKeepTheirOwnProofIdentity() {
        val directory = directory()
        val store = ReportProofLinkContract(linkFile(directory))
        val accumulator = accumulator(directory, store)
        observe(accumulator, 6_000_000, PROOF)
        accumulator.close()
        observe(accumulator, 6_000_000, OTHER_PROOF)
        accumulator.close()
        assertEquals(listOf(WINDOW to PROOF, OTHER_WINDOW to OTHER_PROOF), store.links())
    }

    @Test
    fun writeFailureAtOpenLeavesTheDraftQueueSigningAndDrainUnchanged() {
        val baseline = completedWithoutLinks()
        val directory = directory()
        var writes = 0
        val store = ReportProofLinkContract(linkFile(directory)) { _, _ -> writes++; throw IOException("injected") }
        var drainTriggers = 0
        val accumulator = accumulator(directory, store, onWindowClosed = { drainTriggers++ })
        observe(accumulator, 6_000_000, PROOF)
        assertEquals(1, writes, "the failing write must have happened at open")
        assertNotNull(WindowObservationDraftStore(directory.resolve("draft.snapshot")).load())
        assertNotNull(SubmissionRecordStore(SubmissionRecordStore.defaultFile(directory)).recordFor(WINDOW.toString()))
        assertFalse(directory.resolve("observations").exists(), "open does not sign")
        assertEquals(0, drainTriggers)
        // A later detection and close must never retry failed display metadata.
        observe(accumulator, 6_000_000, PROOF)
        assertTrue(accumulator.close())
        assertEquals(1, writes)
        assertEquals(1, drainTriggers)
        assertEquals(emptyList(), store.links())
        assertSameSubmissionFiles(baseline, directory)
    }

    @Test
    fun successfulLinkLeavesTheQueueAndSignedBytesIdenticalToNoStore() {
        val baseline = completedWithoutLinks()
        val directory = directory()
        val store = ReportProofLinkContract(linkFile(directory))
        closeRecordingWindow(accumulator(directory, store))
        assertEquals(listOf(WINDOW to PROOF), store.links())
        assertTrue(linkFile(directory).readText().contains(PROOF.toString()))
        assertSameSubmissionFiles(baseline, directory)
    }

    @Test
    fun unreadableFileLeavesTheQueueAndSignedBytesIdenticalToNoStore() {
        val baseline = completedWithoutLinks()
        val directory = directory()
        linkFile(directory).writeText("unreadable")
        val store = ReportProofLinkContract(linkFile(directory))
        closeRecordingWindow(accumulator(directory, store))
        assertEquals("unreadable", linkFile(directory).readText())
        assertSameSubmissionFiles(baseline, directory)
    }

    @Test
    fun existingRecordsAndRecoveredDraftsDoNotInferLinks() {
        val directory = completedWithoutLinks()
        val proofFile = ProofRecordStore.defaultFile(directory)
        val oldProof = ProofRecord(PROOF, "event", Instant.EPOCH, peersVerified = 3)
        ProofRecordStore(proofFile).add(oldProof)
        val proofBytes = proofFile.readBytes()
        val before = submissionFiles(directory)
        val store = ReportProofLinkContract(linkFile(directory))
        accumulator(directory, store).recoverAfterRelaunch()
        assertEquals(emptyList(), store.links())
        assertFalse(linkFile(directory).exists())
        assertEquals(listOf(oldProof), ProofRecordStore(proofFile).records)
        assertContentEquals(proofBytes, proofFile.readBytes())
        // Recovery may update the ledger revision; records and signed artifacts stay exact.
        before.filterKeys { it != "ledger.snapshot" }.forEach { (path, bytes) ->
            assertContentEquals(bytes, directory.resolve(path).readBytes(), path)
        }

        val draftDirectory = directory()
        observe(accumulator(draftDirectory, null), 6_000_000, PROOF)
        val draftStore = ReportProofLinkContract(linkFile(draftDirectory))
        accumulator(draftDirectory, draftStore).recoverAfterRelaunch()
        assertEquals(emptyList(), draftStore.links(), "a recovered draft has no proven session identity")
        assertEquals(1, draftDirectory.resolve("observations").listFiles()!!.size)
    }

    @Test
    fun crashAfterOpenPreservesTheLinkWithoutWritingDuringDraftRecovery() {
        val directory = directory()
        val store = ReportProofLinkContract(linkFile(directory))
        observe(accumulator(directory, store), 6_000_000, PROOF)
        // Simulate process death: the live accumulator is never closed.
        assertNotNull(WindowObservationDraftStore(directory.resolve("draft.snapshot")).load())
        val original = linkFile(directory).readBytes()
        var recoveryWrites = 0
        val restarted = ReportProofLinkContract(linkFile(directory)) { _, _ ->
            recoveryWrites++
            throw IOException("recovery must not write links")
        }
        accumulator(directory, restarted).recoverAfterRelaunch()
        assertEquals(0, recoveryWrites)
        assertEquals(listOf(WINDOW to PROOF), restarted.links())
        assertContentEquals(original, linkFile(directory).readBytes())
        assertEquals(1, directory.resolve("observations").listFiles()!!.size)
        assertEquals(null, WindowObservationDraftStore(directory.resolve("draft.snapshot")).load())
    }

    @Test
    fun restoredDraftWithoutAnOpenTimeRowStaysUnlinked() {
        val directory = directory()
        observe(accumulator(directory, null), 6_000_000, PROOF)
        ProofRecordStore(ProofRecordStore.defaultFile(directory)).add(
            ProofRecord(PROOF, "event", Instant.EPOCH, peersVerified = 3),
        )
        var recoveryWrites = 0
        val store = ReportProofLinkContract(linkFile(directory)) { _, _ -> recoveryWrites++ }
        accumulator(directory, store).recoverAfterRelaunch()
        assertEquals(0, recoveryWrites)
        assertEquals(emptyList(), store.links())
        assertFalse(linkFile(directory).exists())
        assertEquals(1, directory.resolve("observations").listFiles()!!.size)
    }

    @Test
    fun missingProofAndNonRecordingInputStayUnlinked() {
        val directory = directory()
        val store = ReportProofLinkContract(linkFile(directory))
        val accumulator = accumulator(directory, store)
        accumulator.observe(6_000_000, PEER, REPORTER, recording = false)
        accumulator.close()
        assertEquals(emptyList(), store.links())
        accumulator.observe(6_000_000, PEER, REPORTER, recording = true)
        accumulator.close()
        assertEquals(emptyList(), store.links(), "never invent a Proof for legacy callers")
    }

    @Test
    fun productionCoordinatorLinksTheProofItCollected() = runTest {
        val directory = directory()
        val engine = FakeEventJoinEngine()
        val registry = FakeNearbyEventRegistry()
        val coordinator = EventJoinCoordinator(
            engine = engine, nearbyRegistry = registry, coroutineScope = backgroundScope,
            nowEpochMillis = { NearbyEventPromotionFixture.VECTOR_NOW_EPOCH_MILLIS },
            sensingCryptography = SigningCryptography(),
            selfProofRecordStore = SelfProofRecordStore(SelfProofRecordStore.defaultFile(directory)),
            bindingRecordStore = BindingRecordStore(BindingRecordStore.defaultFile(directory)),
            ledgerFilesDir = directory, checkpointDispatcher = StandardTestDispatcher(testScheduler),
        )
        val proofs = mutableListOf<UUID>()
        coordinator.onProofCollected = { id, _, _ -> proofs += id }
        repeat(2) {
            joinPromotedVectorEvent(coordinator, engine, registry)
            repeat(3) { index -> engine.emitDetection(6_000_000, PEER, "device-$index", REPORTER) }
            assertEquals(it + 1, proofs.size)
            coordinator.leaveEvent()
        }
        coordinator.dispose()
        val links = ReportProofLinkContract(linkFile(directory)).links()
        assertEquals(2, links.size)
        assertEquals(proofs, links.map { it.second })
        val records = SubmissionRecordStore(SubmissionRecordStore.defaultFile(directory)).records
        assertEquals(records.map { it.windowId }.toSet(), links.map { it.first.toString() }.toSet())
    }

    @Test
    fun retainedWindowNeverTakesAReplacementCoordinatorsProof() = runTest {
        val directory = directory()
        val ids = ArrayDeque(listOf(WINDOW, OTHER_WINDOW))
        val owner = WindowObservationRuntimeOwner(newWindowId = { ids.removeFirst() })
        val proofs = mutableListOf<UUID>()
        repeat(2) { index ->
            val engine = FakeEventJoinEngine()
            val registry = FakeNearbyEventRegistry()
            val coordinator = EventJoinCoordinator(
                engine = engine, nearbyRegistry = registry, coroutineScope = backgroundScope,
                nowEpochMillis = { NearbyEventPromotionFixture.VECTOR_NOW_EPOCH_MILLIS },
                sensingCryptography = SigningCryptography(),
                selfProofRecordStore = SelfProofRecordStore(SelfProofRecordStore.defaultFile(directory)),
                bindingRecordStore = BindingRecordStore(BindingRecordStore.defaultFile(directory)),
                ledgerFilesDir = directory, windowObservationRuntimeOwner = owner,
                checkpointDispatcher = StandardTestDispatcher(testScheduler),
            )
            coordinator.onProofCollected = { id, _, _ -> proofs += id }
            joinPromotedVectorEvent(coordinator, engine, registry)
            repeat(3) { device -> engine.emitDetection(6_000_000, PEER, "device-$device", REPORTER) }
            assertEquals(index + 1, proofs.size)
            assertEquals(listOf(WINDOW to proofs[0]), ReportProofLinkContract(linkFile(directory)).links(),
                "the retained window belongs to A before either coordinator closes it")
            if (index == 1) {
                engine.emitDetection(6_000_001, PEER, "next-window", REPORTER)
                assertEquals(listOf(WINDOW to proofs[0], OTHER_WINDOW to proofs[1]),
                    ReportProofLinkContract(linkFile(directory)).links())
                coordinator.leaveEvent()
            }
            coordinator.dispose()
        }
        assertTrue(proofs[0] != proofs[1])
        assertEquals(listOf(WINDOW to proofs[0], OTHER_WINDOW to proofs[1]),
            ReportProofLinkContract(linkFile(directory)).links(),
            "an Activity replacement does not transfer the retained window to the new session")
    }

    @Test
    fun runtimeOwnerPreservesEpochMillisecondsInRetryDeadlines() {
        val directory = directory()
        var lookupTime: Long? = null
        val registry = object : EventJoinRegistry {
            override fun resolveEventId(code: String, completion: (String?, String?) -> Unit) {
                error("A queued window already has its event id")
            }

            override fun resolveEventDefinition(
                eventIdHex: String,
                useTimeEpochSeconds: Long,
                completion: (EventDefinitionResolution?, String?) -> Unit,
            ) {
                lookupTime = useTimeEpochSeconds
                completion(null, "timeout")
            }
        }
        val runtime = WindowObservationRuntimeOwner(newWindowId = { WINDOW }).acquire(
            filesDir = directory,
            cryptography = SigningCryptography(),
            nowEpochSeconds = { 1_800_000_000.75 },
            eventJoinRegistry = registry,
        )
        try {
            runtime.updateContext(WindowObservationContext("event", "21".repeat(32), "22".repeat(32), "ab".repeat(32)))
            observe(runtime.accumulator, 6_000_000, PROOF)
            assertTrue(runtime.accumulator.close())
            assertEquals(1_800_000_000L, lookupTime)
            assertEquals(1_800_000_030_750L, runtime.accumulator.retryNotBeforeEpochMilliseconds())
        } finally {
            runtime.submissionDrain.close()
        }
    }

    @Test
    fun repeatedRelaunchRecoveryNeverPromotesALiveRecordingWindow() {
        val directory = directory()
        val store = ReportProofLinkContract(linkFile(directory))
        val accumulator = accumulator(directory, store)
        accumulator.recoverAfterRelaunch()
        observe(accumulator, 6_000_000, PROOF)
        val draft = directory.resolve("draft.snapshot").readBytes()
        val before = submissionFiles(directory)

        accumulator.recoverAfterRelaunch()

        assertNotNull(WindowObservationDraftStore(directory.resolve("draft.snapshot")).load())
        assertContentEquals(draft, directory.resolve("draft.snapshot").readBytes())
        assertTrue(directory.resolve("observations").listFiles().orEmpty().isEmpty())
        before.forEach { (path, bytes) -> assertContentEquals(bytes, directory.resolve(path).readBytes(), path) }
        assertEquals(listOf(WINDOW to PROOF), store.links())
        assertTrue(accumulator.close())
    }

    @Test
    fun failedPreparationRefusesAnotherEventAndKeepsTheOriginalProof() {
        val directory = directory()
        val store = ReportProofLinkContract(linkFile(directory))
        val signer = SigningCryptography()
        var keyReadable = true
        val cryptography = object : SensingCryptography by signer {
            override fun eventSigningPublicKey(eventCode: String): ByteArray =
                if (keyReadable) signer.eventSigningPublicKey(eventCode) else byteArrayOf()
        }
        val accumulator = accumulator(directory, store, cryptography = cryptography)
        observe(accumulator, 6_000_000, PROOF)
        keyReadable = false

        assertFalse(accumulator.beginEvent("other"))
        assertNotNull(WindowObservationDraftStore(directory.resolve("draft.snapshot")).load())
        assertEquals(listOf(WINDOW to PROOF), store.links())

        keyReadable = true
        assertTrue(accumulator.close())
    }

    @Test
    fun bufferedSessionNeverLinksAWindowUsingAnotherEventsContext() {
        val directory = directory()
        val store = ReportProofLinkContract(linkFile(directory))
        var context: WindowObservationContext? = null
        val accumulator = accumulator(directory, store, context = { context })
        observe(accumulator, 6_000_000, PROOF)
        context = WindowObservationContext("other", "31".repeat(32), "32".repeat(32), "ab".repeat(32))

        assertTrue(accumulator.close())

        assertEquals(emptyList(), store.links())
        assertFalse(linkFile(directory).exists())
        assertNull(SubmissionRecordStore(SubmissionRecordStore.defaultFile(directory)).recordFor(WINDOW.toString()))
    }

    private fun completedWithoutLinks(): File = directory().also {
        val accumulator = accumulator(it, null)
        // The pre-link call path has neither a store nor a Proof argument.
        accumulator.observe(6_000_000, PEER, REPORTER, recording = true)
        assertTrue(accumulator.close())
    }
    private fun closeRecordingWindow(accumulator: WindowObservationAccumulator) {
        observe(accumulator, 6_000_000, PROOF)
        assertTrue(accumulator.close())
    }

    private fun assertSameSubmissionFiles(baseline: File, actual: File) {
        val expected = submissionFiles(baseline)
        val found = submissionFiles(actual)
        assertEquals(expected.keys, found.keys)
        assertEquals(3, expected.size, "ledger, submission records and signed Observation must all exist")
        expected.forEach { (path, bytes) -> assertContentEquals(bytes, found.getValue(path), path) }
    }

    private fun submissionFiles(directory: File): Map<String, ByteArray> = directory.walkTopDown()
        .filter { it.isFile && (it.name == "ledger.snapshot" || it.name == "submission-records-v1.json" || it.extension == "cose") }
        .associate { it.relativeTo(directory).path to it.readBytes() }

    private fun accumulator(
        directory: File,
        store: ReportProofLinkContract?,
        onWindowClosed: () -> Unit = {},
        cryptography: SensingCryptography = SigningCryptography(),
        context: () -> WindowObservationContext? = {
            WindowObservationContext("event", "21".repeat(32), "22".repeat(32), "ab".repeat(32))
        },
    ): WindowObservationAccumulator {
        val ids = ArrayDeque(listOf(WINDOW, OTHER_WINDOW))
        return WindowObservationAccumulator(
            context = context,
            cryptography = cryptography,
            ledgerStore = UnsentWindowLedgerStore(directory.resolve("ledger.snapshot")),
            draftStore = WindowObservationDraftStore(directory.resolve("draft.snapshot")),
            observationDirectory = directory.resolve("observations"),
            nowEpochSeconds = { 1_800_000_000.75 },
            newWindowId = { ids.removeFirst() },
            ledgerInstanceId = { "000102030405060708090a0b0c0d0e0f" },
            reportProofLinkStore = store?.instance,
            onWindowClosed = onWindowClosed,
        )
    }

    private fun observe(accumulator: WindowObservationAccumulator, enin: Long, proofId: UUID) {
        accumulator.observe(enin, PEER, REPORTER, recording = true, eventCode = "event", proofId = proofId)
    }

    private fun directory(): File = Files.createTempDirectory("report-link-wiring").toFile()
    private fun linkFile(directory: File): File = directory.resolve("report-proof-links.json")

    private class SigningCryptography : FakeSensingCryptography(eventSigningPublicKeyResult = PUBLIC_KEY.hexBytes()) {
        override fun signWindowReport(eventCode: String, bytes: ByteArray): SensingRecoverableSignature {
            val (r, s) = TestSecp256k1.sign(MessageDigest.getInstance("SHA-256").digest(bytes), 1)
            return SensingRecoverableSignature(r, s, 0)
        }
    }

    private companion object {
        val WINDOW: UUID = UUID.fromString("00112233-4455-6677-8899-aabbccddeeff")
        val OTHER_WINDOW: UUID = UUID.fromString("11112233-4455-6677-8899-aabbccddeeff")
        val PROOF: UUID = UUID.fromString("22222222-2222-2222-2222-222222222222")
        val OTHER_PROOF: UUID = UUID.fromString("33333333-3333-3333-3333-333333333333")
        const val PUBLIC_KEY = "0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798"
        const val REPORTER = "0110101010101010101010101010101010"
        const val PEER = "0111111111111111111111111111111111"
    }
}

private fun String.hexBytes(): ByteArray = chunked(2).map { it.toInt(16).toByte() }.toByteArray()
