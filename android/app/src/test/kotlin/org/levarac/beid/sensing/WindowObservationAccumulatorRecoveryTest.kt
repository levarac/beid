package org.levarac.beid.sensing

import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.util.UUID
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import org.levarac.beid.persistence.UnsentWindowLedgerStore
import org.levarac.beid.persistence.WindowObservationDraftStore
import org.levarac.beid.shared.report.addWindowObservationDraftRpid
import org.levarac.beid.shared.report.createUnsentWindowLedger
import org.levarac.beid.shared.report.createWindowObservationDraft
import org.levarac.beid.shared.report.openUnsentWindow

/**
 * beid#372 — the observation set of a window that is still open must survive
 * the process that collected it.
 *
 * Two contracts are exercised here and they are deliberately kept apart:
 *
 * - the **unsent-window ledger** answers which windows exist and what state
 *   each is in, and
 * - the **observation draft** answers what the device actually observed
 *   inside the window that is open right now.
 *
 * The pair of tests at the bottom is the point of the separation. Recovering
 * one must never be reportable as having recovered the other, so one test
 * gives the ledger everything and the draft nothing, and its twin does the
 * reverse.
 */
class WindowObservationAccumulatorRecoveryTest {
    /**
     * Acceptance 1. The relaunched accumulator is built from storage alone —
     * a different instance, different stores, `context` permanently null, and
     * a window-id source that throws if anything asks it to invent one. If a
     * single value came from the dead process's memory, this cannot pass.
     *
     * `finalizedAt` is the one evidence input that is *not* restored: it is
     * when the report was finalized, and after a relaunch that genuinely is
     * later. Both accumulators are pinned to the same clock so the assertion
     * isolates "was what the device observed restored" rather than measuring
     * the clock.
     */
    @Test
    fun windowThatDiedMidFlightRebuildsTheIdenticalObservationFromStorageAlone() {
        val directory = Files.createTempDirectory("window-372-process-death").toFile()
        val dyingCryptography = VectorCryptography()
        val dying = openAccumulator(directory, dyingCryptography)

        dying.observe(ENIN, RPID_TWO, REPORTER_RPID, recording = true)
        dying.observe(ENIN, RPID_ONE, REPORTER_RPID, recording = true)
        // The process dies here. Nothing closed the window, so on the code
        // before beid#372 both of these observations are gone.
        assertNull(dyingCryptography.signedBytes, "the window must still be open")
        assertTrue(artifacts(directory).isEmpty(), "nothing may be signed yet")

        val relaunchCryptography = VectorCryptography()
        relaunched(directory, relaunchCryptography)

        assertContentEquals(
            EXPECTED_SIGNATURE_STRUCTURE.hexBytes(),
            relaunchCryptography.signedBytes,
            "the restored window must sign the same evidence the dead process had collected",
        )
        val restored = assertNotNull(artifacts(directory).singleOrNull())
        val control = controlArtifact()
        assertEquals(control.name, restored.name)
        assertContentEquals(
            control.readBytes(),
            restored.readBytes(),
            "the recovered .cose must be byte-identical to one produced without a relaunch",
        )
        assertNull(
            WindowObservationDraftStore(draftFile(directory)).load(),
            "a promoted draft must not be left behind to be promoted twice",
        )
    }

    /**
     * Acceptance 2. Acceptance 1 on its own would still pass an
     * implementation that writes the whole set when the window closes, since
     * a test can always close before it inspects. This one never closes: it
     * reads the durable record while the window is open, after a detection
     * that arrived *after* the window had already been opened.
     *
     * That last detail is what also kills the write-once-at-open variant.
     */
    @Test
    fun eachDetectionReachesStorageBeforeTheWindowIsEverClosed() {
        val directory = Files.createTempDirectory("window-372-incremental").toFile()
        val accumulator = openAccumulator(directory, VectorCryptography())

        accumulator.observe(ENIN, RPID_TWO, REPORTER_RPID, recording = true)
        val afterOpeningDetection = assertNotNull(
            WindowObservationDraftStore(draftFile(directory)).load(),
            "the window is open, so its evidence must already be durable",
        )
        accumulator.observe(ENIN, RPID_ONE, REPORTER_RPID, recording = true)
        val afterLaterDetection = assertNotNull(
            WindowObservationDraftStore(draftFile(directory)).load(),
        )

        assertEquals(1, afterOpeningDetection.observedRpidCount)
        assertEquals(RPID_TWO, afterOpeningDetection.observedRpidAt(0))
        assertEquals(
            2,
            afterLaterDetection.observedRpidCount,
            "a detection after the window opened must reach storage without waiting for the close",
        )
        assertEquals(RPID_ONE, afterLaterDetection.observedRpidAt(1))
        assertEquals(WINDOW_ID, afterLaterDetection.windowId)
        assertEquals(ENIN, afterLaterDetection.enin)
        assertTrue(artifacts(directory).isEmpty(), "the window must still be open")
    }

    /**
     * Acceptance 3, first direction. The ledger is given a fully-formed open
     * row and the draft is given nothing. Session state is reconciled — the
     * ledger's own contract runs and advances — and **no** evidence appears.
     *
     * This is the claim the issue's design point exists to forbid: that
     * having restored the window's ledger state amounts to having restored
     * its proof data.
     */
    @Test
    fun anOpenLedgerRowWithNoDraftRecoversSessionStateAndNoEvidence() {
        val directory = Files.createTempDirectory("window-372-ledger-only").toFile()
        val ledgerStore = UnsentWindowLedgerStore(ledgerFile(directory))
        val opened = openUnsentWindow(
            assertNotNull(createUnsentWindowLedger(LEDGER_INSTANCE_ID).ledger),
            WINDOW_ID,
        )
        assertEquals(1L, ledgerStore.persist(opened))
        assertNull(WindowObservationDraftStore(draftFile(directory)).load())
        val cryptography = VectorCryptography()

        relaunched(directory, cryptography)

        assertNull(cryptography.signedBytes, "there is no evidence to sign")
        assertTrue(artifacts(directory).isEmpty(), "no observation may be invented for it")
        assertEquals(
            2L,
            assertNotNull(ledgerStore.load()).persistenceRevision,
            "the ledger's own contract must still have run and discarded the unrecoverable row",
        )
    }

    /**
     * Acceptance 3, second direction, and the one that proves the dependency
     * does not merely run the other way. There is no ledger snapshot at all —
     * the file does not exist — and the evidence still comes back.
     */
    @Test
    fun aDraftWithNoLedgerAtAllStillRecoversItsEvidence() {
        val directory = Files.createTempDirectory("window-372-draft-only").toFile()
        WindowObservationDraftStore(draftFile(directory)).persist(durableDraft(REPORTER_RPID))
        assertFalse(ledgerFile(directory).exists(), "this window has no session state to restore")
        val cryptography = VectorCryptography()

        relaunched(directory, cryptography, ledgerInstanceId = { LEDGER_INSTANCE_ID })

        assertContentEquals(
            EXPECTED_SIGNATURE_STRUCTURE.hexBytes(),
            cryptography.signedBytes,
            "evidence recovery must not depend on the ledger having a row for the window",
        )
        assertContentEquals(
            controlArtifact().readBytes(),
            assertNotNull(artifacts(directory).singleOrNull()).readBytes(),
        )
    }

    /**
     * A draft that is well-formed as text but cannot be turned back into an
     * eligible observation is kept, not deleted and not retried. Its bytes
     * are the only record that observations were lost, and the next window
     * must not inherit it.
     *
     * The reporter RPID here is valid hexadecimal of the wrong width, which
     * is exactly the split the layers are meant to have: shared checks shape,
     * and preparation decides protocol validity.
     */
    @Test
    fun aDraftThatCannotBePreparedIsKeptAsideRatherThanDiscarded() {
        val directory = Files.createTempDirectory("window-372-unusable").toFile()
        WindowObservationDraftStore(draftFile(directory)).persist(durableDraft("0101"))
        val cryptography = VectorCryptography()

        relaunched(directory, cryptography, ledgerInstanceId = { LEDGER_INSTANCE_ID })

        assertNull(cryptography.signedBytes)
        assertTrue(artifacts(directory).isEmpty())
        assertFalse(draftFile(directory).exists())
        assertNotNull(
            directory.listFiles().orEmpty().singleOrNull { it.name.contains(".corrupt-") },
            "the unusable evidence must be preserved for diagnosis",
        )
    }

    /**
     * Constructing the accumulator must recover NOTHING. Recovery reaches the
     * filesystem and the Keystore, and it is scheduled off the main thread by
     * the caller precisely so that neither can happen during Activity setup.
     *
     * This is the witness for that relocation. Putting the work back into
     * `init` would leave every other test in this file green, because they
     * all end up recovering either way — only an assertion made in the gap
     * between constructing and asking can tell the two apart.
     */
    @Test
    fun constructingTheAccumulatorRecoversNothingUntilItIsAskedTo() {
        val directory = Files.createTempDirectory("window-372-not-in-constructor").toFile()
        WindowObservationDraftStore(draftFile(directory)).persist(durableDraft(REPORTER_RPID))
        val cryptography = VectorCryptography()

        val accumulator = WindowObservationAccumulator(
            context = { null },
            cryptography = cryptography,
            ledgerStore = UnsentWindowLedgerStore(ledgerFile(directory)),
            draftStore = WindowObservationDraftStore(draftFile(directory)),
            observationDirectory = observationDirectory(directory),
            nowEpochSeconds = { FINALIZED_AT },
            newWindowId = { error("a relaunch must not invent a window id") },
            ledgerInstanceId = { LEDGER_INSTANCE_ID },
        )

        assertNull(cryptography.signedBytes, "construction must not reach the signing key")
        assertTrue(artifacts(directory).isEmpty(), "construction must not write an artifact")
        assertTrue(draftFile(directory).exists(), "construction must not consume the draft")

        accumulator.recoverAfterRelaunch()

        assertContentEquals(
            EXPECTED_SIGNATURE_STRUCTURE.hexBytes(),
            cryptography.signedBytes,
            "the same work must happen once it is explicitly asked for",
        )
        assertEquals(1, artifacts(directory).size)
    }

    /**
     * A draft outlives its process by design; the event signing key need not.
     * The user may have left the event, or the Keystore entry may have been
     * invalidated by a lock-screen change, between the window being collected
     * and the app next starting.
     *
     * This restore runs inside a constructor, so a key that throws would take
     * the whole app down at launch rather than costing one window. Barnard is
     * a binary dependency here with no sources, so what it actually does for
     * an absent key cannot be read — which is the reason the guard is
     * unconditional rather than tuned to one exception type. Both reachable
     * crypto calls are covered, because covering only the one that looked
     * likelier is how the other survives.
     */
    @Test
    fun aRestoreWhoseSigningKeyIsGoneQuarantinesTheDraftInsteadOfFailingToStart() {
        listOf(true, false).forEach { failsOnPublicKey ->
            val directory = Files.createTempDirectory("window-372-key-gone").toFile()
            WindowObservationDraftStore(draftFile(directory)).persist(durableDraft(REPORTER_RPID))

            relaunched(
                directory,
                ThrowingCryptography(onPublicKey = failsOnPublicKey),
                ledgerInstanceId = { LEDGER_INSTANCE_ID },
            )

            assertTrue(artifacts(directory).isEmpty(), "nothing may be signed without the key")
            assertFalse(draftFile(directory).exists())
            assertNotNull(
                directory.listFiles().orEmpty().singleOrNull { it.name.contains(".corrupt-") },
                "the unsignable evidence must be preserved rather than deleted",
            )
        }
    }

    /**
     * The window is opened in the ledger before its draft is written, so a
     * failure to record the open must leave nothing behind either. Otherwise
     * a relaunch would find evidence for a window the ledger never had, and
     * the retry would then produce a second one.
     */
    @Test
    fun aFailedLedgerOpenLeavesNoDraftToRecover() {
        val directory = Files.createTempDirectory("window-372-open-failure").toFile()
        val accumulator = openAccumulator(directory, VectorCryptography())
        check(ledgerFile(directory).mkdir())

        runCatching { accumulator.observe(ENIN, RPID_ONE, REPORTER_RPID, recording = true) }

        assertFalse(
            draftFile(directory).exists(),
            "a window whose open never became durable must not leave evidence behind",
        )
    }

    /**
     * Closing writes the artifact first and drops the draft second, so a
     * process can die holding both. On relaunch the artifact wins and the
     * draft is discarded without being signed again.
     *
     * Signing it again would not overwrite anything — a later `finalizedAt`
     * gives a different digest and therefore a different filename — it would
     * add a *second* artifact for one window, which relaunch reconciliation
     * then fails closed on. That failure happens at construction, so the
     * symptom is an app that cannot start.
     */
    @Test
    fun aWindowWhoseArtifactIsAlreadyDurableIsNotSignedAgainOnRelaunch() {
        val directory = Files.createTempDirectory("window-372-already-durable").toFile()
        val accumulator = openAccumulator(directory, VectorCryptography())
        accumulator.observe(ENIN, RPID_TWO, REPORTER_RPID, recording = true)
        accumulator.observe(ENIN, RPID_ONE, REPORTER_RPID, recording = true)
        check(accumulator.close())
        // The death happens between the two writes: the artifact is durable
        // and the draft was not dropped.
        WindowObservationDraftStore(draftFile(directory)).persist(durableDraft(REPORTER_RPID))
        val cryptography = VectorCryptography()

        relaunched(directory, cryptography)

        assertNull(cryptography.signedBytes, "the window was already finalized")
        assertEquals(1, artifacts(directory).size, "one window must not leave two artifacts")
        assertFalse(draftFile(directory).exists())
    }

    /**
     * What type this recovery fails with, measured rather than assumed.
     *
     * `EventJoinCoordinator` schedules [WindowObservationAccumulator.recoverAfterRelaunch]
     * into a scope built from a `SupervisorJob` with no
     * `CoroutineExceptionHandler`, and catches whatever escapes it so it can
     * be handed to [logWindowRecoveryFailure]. Anything that catch does not
     * cover reaches the default handler and takes the process down — and the
     * durable input that caused it is still on disk at the next launch, so it
     * recurs every time. That recurrence is the boot loop the catch exists to
     * close, which makes the catch's width the whole question, and nothing
     * measured what this path actually throws until this test.
     *
     * It throws `java.io.IOException`, which extends `java.lang.Exception` and
     * is **not** a `RuntimeException`. A ledger file replaced by a directory is
     * the cheapest condition that reaches it — no full disk, no revoked signing
     * key, and no coroutine, because `recoverAfterRelaunch` is a plain
     * `@Synchronized` method this test calls on its own thread. The same
     * technique already stands in `WindowObservationAccumulatorTest`'s
     * `failedOpenPersistenceDoesNotAdvanceMemoryAndCanRetryTheSameWindow`.
     *
     * ⚠️ **Which half is proven and which is argued.** *Proven:* what this path
     * throws, and that the guard is wide enough to be handed it — narrowing
     * [logWindowRecoveryFailure]'s parameter back to `RuntimeException` stops
     * this file compiling. *Argued:* that the `catch` clause in
     * `EventJoinCoordinator`'s `init` then catches it at runtime. Narrowing
     * *only* that clause back leaves this test green, because a
     * `RuntimeException` still satisfies an `Exception` parameter, and reaching
     * the clause means awaiting a failure inside an async `launch` — the flaky
     * test this deliberately is not.
     *
     * The distinction is the point rather than an apology for it. What made the
     * missing witness unacceptable was never the absence itself but that the
     * absence HID A TYPE ERROR for two hours, and that is the half this closes.
     */
    @Test
    fun relaunchRecoveryFailsWithATypeNarrowingToRuntimeExceptionWouldMiss() {
        val directory = Files.createTempDirectory("window-372-unwritable-ledger").toFile()
        val dying = openAccumulator(directory, VectorCryptography())
        dying.observe(ENIN, RPID_TWO, REPORTER_RPID, recording = true)
        dying.observe(ENIN, RPID_ONE, REPORTER_RPID, recording = true)
        // The process dies with the window still open, which is what leaves the
        // reconcile below a row to close and therefore a ledger write to make.
        assertTrue(artifacts(directory).isEmpty(), "nothing may be signed yet")

        // Built before the ledger file is replaced. The store validates its
        // snapshot on construction, so breaking the file first would move the
        // failure into the constructor and measure a different call.
        val relaunched = relaunchedWithoutRecovering(directory, VectorCryptography())
        check(ledgerFile(directory).delete())
        check(ledgerFile(directory).mkdir())

        val thrown = assertFailsWith<IOException> { relaunched.recoverAfterRelaunch() }

        assertFalse(
            thrown is RuntimeException,
            "recovery fails with a checked exception, so a guard narrowed to RuntimeException never sees it",
        )
        // The guard has to absorb this exact object. This call is the witness:
        // it does not compile while the parameter is narrower than what the
        // line above proves recovery produces.
        logWindowRecoveryFailure(thrown)
    }

    /** A window closed the ordinary way in its own process, for byte comparison. */
    private fun controlArtifact(): File {
        val directory = Files.createTempDirectory("window-372-control").toFile()
        val accumulator = openAccumulator(directory, VectorCryptography())
        accumulator.observe(ENIN, RPID_TWO, REPORTER_RPID, recording = true)
        accumulator.observe(ENIN, RPID_ONE, REPORTER_RPID, recording = true)
        check(accumulator.close())
        return assertNotNull(artifacts(directory).singleOrNull())
    }

    private fun durableDraft(reporterRpidHex: String) = run {
        var draft = assertNotNull(
            createWindowObservationDraft(
                windowId = WINDOW_ID,
                enin = ENIN,
                eventCode = VECTOR_CONTEXT.eventCode,
                eventIdHex = VECTOR_CONTEXT.eventIdHex,
                eventDefinitionDigestHex = VECTOR_CONTEXT.eventDefinitionDigestHex,
                participantCommitmentHex = VECTOR_CONTEXT.participantCommitmentHex,
                reporterRpidHex = reporterRpidHex,
            ).draft,
        )
        listOf(RPID_TWO, RPID_ONE).forEach { rpid ->
            draft = assertNotNull(addWindowObservationDraftRpid(draft, rpid).draft)
        }
        draft
    }

    private fun openAccumulator(directory: File, cryptography: SensingCryptography) =
        WindowObservationAccumulator(
            context = { VECTOR_CONTEXT },
            cryptography = cryptography,
            ledgerStore = UnsentWindowLedgerStore(ledgerFile(directory)),
            draftStore = WindowObservationDraftStore(draftFile(directory)),
            observationDirectory = observationDirectory(directory),
            nowEpochSeconds = { FINALIZED_AT },
            newWindowId = { UUID.fromString(WINDOW_ID) },
            ledgerInstanceId = { LEDGER_INSTANCE_ID },
        )

    private fun relaunched(
        directory: File,
        cryptography: SensingCryptography,
        ledgerInstanceId: () -> String = { error("the existing ledger must be reused") },
    ) = relaunchedWithoutRecovering(directory, cryptography, ledgerInstanceId).also {
        // Recovery is an explicit call, not a constructor side effect —
        // production schedules it off the main thread. A test that recovered
        // by merely constructing would no longer be testing what ships.
        it.recoverAfterRelaunch()
    }

    /**
     * The relaunch shape with the recovery call left to the caller, for the
     * one test that has to change the filesystem in between.
     */
    private fun relaunchedWithoutRecovering(
        directory: File,
        cryptography: SensingCryptography,
        ledgerInstanceId: () -> String = { error("the existing ledger must be reused") },
    ) = WindowObservationAccumulator(
        context = { null },
        cryptography = cryptography,
        ledgerStore = UnsentWindowLedgerStore(ledgerFile(directory)),
        draftStore = WindowObservationDraftStore(draftFile(directory)),
        observationDirectory = observationDirectory(directory),
        nowEpochSeconds = { FINALIZED_AT },
        newWindowId = { error("a relaunch must not invent a window id") },
        ledgerInstanceId = ledgerInstanceId,
    )

    private fun ledgerFile(directory: File) = directory.resolve("ledger.snapshot")

    private fun draftFile(directory: File) = directory.resolve("draft.snapshot")

    private fun observationDirectory(directory: File) = directory.resolve("observations")

    private fun artifacts(directory: File): List<File> =
        observationDirectory(directory).listFiles().orEmpty().filter { it.extension == "cose" }

    /** Fails at exactly one of the two points restore reaches the key. */
    private class ThrowingCryptography(private val onPublicKey: Boolean) : FakeSensingCryptography(
        eventSigningPublicKeyResult = PUBLIC_KEY.hexBytes(),
        signWindowReportResult = SensingRecoverableSignature(
            SIGNATURE_R.hexBytes(),
            SIGNATURE_S.hexBytes(),
            0,
        ),
    ) {
        override fun eventSigningPublicKey(eventCode: String): ByteArray =
            if (onPublicKey) throw IllegalStateException("event signing key is gone") else super.eventSigningPublicKey(eventCode)

        override fun signWindowReport(eventCode: String, bytes: ByteArray): SensingRecoverableSignature =
            if (onPublicKey) super.signWindowReport(eventCode, bytes) else throw IllegalStateException("event signing key is gone")
    }

    private class VectorCryptography : FakeSensingCryptography(
        eventSigningPublicKeyResult = PUBLIC_KEY.hexBytes(),
        signWindowReportResult = SensingRecoverableSignature(
            SIGNATURE_R.hexBytes(),
            SIGNATURE_S.hexBytes(),
            0,
        ),
    ) {
        var signedBytes: ByteArray? = null

        override fun signWindowReport(eventCode: String, bytes: ByteArray): SensingRecoverableSignature {
            signedBytes = bytes.copyOf()
            return super.signWindowReport(eventCode, bytes)
        }
    }

    private companion object {
        const val ENIN = 6_000_000L
        const val FINALIZED_AT = 1_800_000_000.75
        const val LEDGER_INSTANCE_ID = "000102030405060708090a0b0c0d0e0f"
        const val PUBLIC_KEY = "0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798"
        const val REPORTER_RPID = "0110101010101010101010101010101010"
        const val RPID_ONE = "0111111111111111111111111111111111"
        const val RPID_TWO = "0122222222222222222222222222222222"
        const val SIGNATURE_R = "d9b39668ed2e92db7226461f059a1ecd06a732bd5bfdae0b23d43390a8025349"
        const val SIGNATURE_S = "462b3ecfaa8305881ad1a8b8960e9f3f1e6770683e0c178543613de942c8b765"
        const val WINDOW_ID = "00112233-4455-6677-8899-aabbccddeeff"

        /**
         * The same conformance vector `WindowObservationAccumulatorTest`
         * pins, reused deliberately: it fixes the expected bytes outside this
         * file, so a recovery bug cannot be hidden by comparing a recovered
         * value against another recovered value.
         */
        const val EXPECTED_SIGNATURE_STRUCTURE = "846a5369676e6174757265315839a301382e0378286170706c69636174696f6e2f766e642e6c6576617261632e6f62736572766174696f6e2b63626f7204485ef036280edf16eb40590109a80101025000112233445566778899aabbccddeeff0378196c6576617261632e6d757475616c2d73656e73696e672f763104582021212121212121212121212121212121212121212121212121212121212121210558210279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798061a6b49d20007510110101010101010101010101010101010085875a50158202222222222222222222222222222222222222222222222222222222222222222021a005b8d80038251011111111111111111111111111111111151012222222222222222222222222222222204f6055820abababababababababababababababababababababababababababababababab"

        val VECTOR_CONTEXT = WindowObservationContext("event", "21".repeat(32), "22".repeat(32), "ab".repeat(32))
    }
}

private fun String.hexBytes(): ByteArray = chunked(2).map { it.toInt(16).toByte() }.toByteArray()
