package org.levarac.beid.sensing

import java.io.File
import java.nio.file.Files
import java.util.UUID
import java.util.concurrent.CountDownLatch
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import org.levarac.beid.persistence.SubmissionRecord
import org.levarac.beid.persistence.SubmissionRecordStore
import org.levarac.beid.persistence.UnsentWindowLedgerStore
import org.levarac.beid.persistence.WindowObservationDraftStore
import org.levarac.beid.shared.report.addWindowObservationDraftRpid
import org.levarac.beid.shared.report.closeUnsentWindow
import org.levarac.beid.shared.report.confirmUnsentWindowLedgerPersistence
import org.levarac.beid.shared.report.createUnsentWindowLedger
import org.levarac.beid.shared.report.createWindowObservationDraft
import org.levarac.beid.shared.report.openUnsentWindow
import org.levarac.parallax.submission.SubmissionClient
import org.levarac.parallax.submission.SubmissionOperatorConfiguration
import org.levarac.parallax.submission.createSubmissionClient
import org.levarac.parallax.submission.createSubmissionOperatorConfiguration

/**
 * beid#525's four acceptance-criteria tests: the Android submission drain.
 *
 * Every test drives the REAL [WindowObservationAccumulator] and
 * [WindowObservationSubmissionDrain] against the real, on-disk
 * [UnsentWindowLedgerStore]/[SubmissionRecordStore] and a real (loopback)
 * [StubOperatorServer] through the real [SubmissionClient] — no mock of this
 * PR's own logic. "Restart" is simulated by constructing a fresh
 * accumulator+drain pair over the same files, exactly as a real process
 * relaunch would.
 */
class WindowObservationSubmissionDrainTest {
    @Test
    fun retryableFailureSchedulesDrainWhenNoNewObservationArrives() {
        val directory = Files.createTempDirectory("drain-retry-schedule").toFile()
        val server = newStubOperatorServer()
        val endpoint = server.start()
        try {
            var nowEpochMilliseconds = NOW_EPOCH_MILLIS
            val scheduler = RecordingRetryScheduler()
            val resolver = FakeConfigurationResolver(
                listOf(
                    SubmissionConfigurationResolution.RetryableFailure("timeout"),
                    SubmissionConfigurationResolution.Resolved(resolvedConfiguration(endpoint)),
                ),
            )
            val (accumulator, drain) = buildSystem(
                directory = directory,
                cryptography = vectorCryptography(),
                submissionConfiguration = null,
                configurationResolver = resolver,
                retryScheduler = scheduler,
                nowEpochMilliseconds = { nowEpochMilliseconds },
            )
            // The fixture has one durable submission; there is no later
            // observation to provide another trigger.
            closeOneWindow(accumulator)
            drain.drain()

            assertEquals(1, resolver.callCount)
            assertEquals(1, scheduler.scheduledCount)
            assertEquals(RETRY_BACKOFF_MILLIS, scheduler.delayMillis)
            nowEpochMilliseconds += RETRY_BACKOFF_MILLIS
            scheduler.task.invoke()
            waitUntil { server.postCount == 1 }
        } finally {
            server.stop()
        }
    }

    @Test
    fun restoreReservesTimerForFiniteRetryDeadlineBeforeItIsDue() {
        val directory = Files.createTempDirectory("drain-restore-retry-deadline").toFile()
        val server = newStubOperatorServer()
        val endpoint = server.start()
        try {
            var now = NOW_EPOCH_MILLIS
            val firstScheduler = RecordingRetryScheduler()
            val firstResolver = FakeConfigurationResolver(
                listOf(SubmissionConfigurationResolution.RetryableFailure("timeout")),
            )
            val (firstAccumulator, firstDrain) = buildSystem(
                directory, vectorCryptography(), null,
                configurationResolver = firstResolver,
                retryScheduler = firstScheduler,
                nowEpochMilliseconds = { now },
            )
            closeOneWindow(firstAccumulator)
            firstDrain.drain()
            // The first process has a transport failure after selection. Keep
            // the durable finite deadline, but do not fire its in-process timer.
            waitUntil { firstScheduler.scheduledCount == 1 }

            val restoreScheduler = RecordingRetryScheduler()
            val secondResolver = FakeConfigurationResolver(resolvedConfiguration(endpoint))
            val (secondAccumulator, secondDrain) = buildSystem(
                directory, vectorCryptography(), null,
                configurationResolver = secondResolver,
                retryScheduler = restoreScheduler,
                nowEpochMilliseconds = { now },
            )
            secondAccumulator.recoverAfterRelaunch()
            secondDrain.resumeAfterRestore()

            assertEquals(1, restoreScheduler.scheduledCount)
            assertEquals(RETRY_BACKOFF_MILLIS, restoreScheduler.delayMillis)
            assertEquals(0, server.postCount)

            now += RETRY_BACKOFF_MILLIS
            restoreScheduler.task.invoke()
            waitUntil { server.postCount == 1 }
            waitUntil { submissionRecordStore(directory).recordFor(WINDOW_ID)?.acceptanceReceiptHex != null }
            assertNotNull(
                submissionRecordStore(directory).recordFor(WINDOW_ID)?.observationDigestHex,
                "the exact ledger observation reference must be durably bound before submission",
            )
            assertEquals(1, server.getCount)
            assertEquals(1, server.postCount)
        } finally {
            server.stop()
        }
    }
    @Test
    fun happyPathDrainsExactlyOnePostAndPersistsAcceptance() {
        val directory = Files.createTempDirectory("drain-happy-path").toFile()
        val server = newStubOperatorServer()
        val endpoint = server.start()
        try {
            val configuration = resolvedConfiguration(endpoint)
            val (accumulator, drain) = buildSystem(
                directory = directory,
                cryptography = vectorCryptography(),
                submissionConfiguration = configuration,
            )

            closeOneWindow(accumulator)
            drain.drain()

            waitUntil { server.postCount == 1 }
            waitUntil { submissionRecordStore(directory).recordFor(WINDOW_ID)?.acceptanceReceiptHex != null }
            Thread.sleep(150) // give any errant second POST a chance to arrive
            assertEquals(1, server.postCount, "the happy path must produce exactly one POST")
            assertEquals(0, server.getCount, "a first attempt must never look up before posting")
        } finally {
            server.stop()
        }
    }

    /** #525 acceptance criterion 2, "if lookup succeeds" branch. */
    @Test
    fun crashBetweenPostAndReceiptPersistenceLookupSucceedsCausesNoSecondPost() {
        val directory = Files.createTempDirectory("drain-crash-lookup-succeeds").toFile()
        val server = newStubOperatorServer()
        val endpoint = server.start()
        try {
            val configuration = resolvedConfiguration(endpoint)
            val (firstAccumulator, firstDrain) = buildSystem(
                directory = directory,
                cryptography = vectorCryptography(),
                submissionConfiguration = configuration,
                receiptPersistenceGate = { false }, // simulated crash: accepted, but nothing reaches disk
            )
            closeOneWindow(firstAccumulator)
            firstDrain.drain()
            waitUntil { server.postCount == 1 }
            Thread.sleep(150) // let the gated completion finish running (and persist nothing)
            assertNull(
                submissionRecordStore(directory).recordFor(WINDOW_ID)?.acceptanceReceiptHex,
                "the simulated crash must leave no receipt persisted",
            )

            val secondProcessCryptography = vectorCryptography()
            val (secondAccumulator, secondDrain) = buildSystem(
                directory = directory,
                cryptography = secondProcessCryptography,
                submissionConfiguration = configuration,
            )
            secondAccumulator.recoverAfterRelaunch()
            secondDrain.resumeAfterRestore()

            waitUntil { submissionRecordStore(directory).recordFor(WINDOW_ID)?.acceptanceReceiptHex != null }
            Thread.sleep(150)

            assertEquals(1, server.postCount, "a successful lookup must prevent a duplicate POST")
            assertEquals(1, server.getCount, "resuming after restore must look up before doing anything else")
            assertEquals(
                0,
                secondProcessCryptography.calls.count { it is FakeSensingCryptography.Call.SignWindowReport },
                "the drain must never re-sign",
            )
        } finally {
            server.stop()
        }
    }

    /** #525 acceptance criterion 2, "if receipt_not_found" branch. */
    @Test
    fun crashBeforeAnyPostReachedTheOperatorRePostsTheExactStoredBytes() {
        val directory = Files.createTempDirectory("drain-crash-receipt-not-found").toFile()
        val server = newStubOperatorServer()
        val endpoint = server.start()
        try {
            val configuration = resolvedConfiguration(endpoint)
            val (firstAccumulator, _) = buildSystem(
                directory = directory,
                cryptography = vectorCryptography(),
                submissionConfiguration = configuration,
            )
            closeOneWindow(firstAccumulator)
            // The process dies before the drain ever attempts a POST: the
            // ledger is durably IN_FLIGHT (the window was selected and
            // confirmed) but nothing reached the operator. Calling
            // `beginNextSubmissionAttempt` directly, bypassing the drain,
            // constructs exactly this state without needing to interrupt an
            // in-flight network call.
            val submission = requireNotNull(firstAccumulator.beginNextSubmissionAttempt(NOW_EPOCH_MILLIS))
            assertEquals(0, server.postCount, "nothing may have reached the operator yet")
            val originalBytes = requireNotNull(
                firstAccumulator.loadStoredObservationBytes(WINDOW_ID, requireNotNull(submission.observationReferenceAt(0))),
            )

            val secondProcessCryptography = vectorCryptography()
            val (secondAccumulator, secondDrain) = buildSystem(
                directory = directory,
                cryptography = secondProcessCryptography,
                submissionConfiguration = configuration,
            )
            secondAccumulator.recoverAfterRelaunch()
            secondDrain.resumeAfterRestore()

            waitUntil { server.postCount == 1 }
            waitUntil { submissionRecordStore(directory).recordFor(WINDOW_ID)?.acceptanceReceiptHex != null }
            Thread.sleep(150)

            assertEquals(1, server.postCount, "receipt_not_found permits exactly one re-POST")
            assertEquals(1, server.getCount, "resuming after restore must look up first")
            assertContentEquals(
                originalBytes,
                server.postBodies.single(),
                "the re-POST body must be byte-identical to the original stored observation",
            )
            assertEquals(
                0,
                secondProcessCryptography.calls.count { it is FakeSensingCryptography.Call.SignWindowReport },
                "the drain must never re-sign",
            )
        } finally {
            server.stop()
        }
    }

    @Test
    fun duplicateTriggersDoNotProduceConcurrentPosts() {
        val directory = Files.createTempDirectory("drain-duplicate-trigger").toFile()
        val server = newStubOperatorServer()
        val endpoint = server.start()
        try {
            val configuration = resolvedConfiguration(endpoint)
            val (accumulator, drain) = buildSystem(
                directory = directory,
                cryptography = vectorCryptography(),
                submissionConfiguration = configuration,
            )
            closeOneWindow(accumulator)

            val ready = CountDownLatch(2)
            val go = CountDownLatch(1)
            val threads = List(2) {
                Thread {
                    ready.countDown()
                    go.await()
                    drain.drain()
                }
            }
            threads.forEach { it.start() }
            ready.await()
            go.countDown()
            threads.forEach { it.join(5_000) }

            waitUntil { server.postCount >= 1 }
            Thread.sleep(250) // let an errant second POST arrive if the ledger's own IN_FLIGHT guard failed
            assertEquals(1, server.postCount, "duplicate triggers must not produce concurrent POSTs")
        } finally {
            server.stop()
        }
    }

    @Test
    fun unresolvableConfigurationHoldsTheArtifactWithoutSubmitting() {
        val directory = Files.createTempDirectory("drain-unresolved-config").toFile()
        val server = newStubOperatorServer()
        server.start()
        try {
            val (accumulator, drain) = buildSystem(
                directory = directory,
                cryptography = vectorCryptography(),
                submissionConfiguration = null, // e.g. the nearby-join path, which has no verified Event Definition
            )
            closeOneWindow(accumulator)

            drain.drain()
            Thread.sleep(250)

            assertEquals(0, server.postCount, "an artifact with no resolvable configuration must never be submitted")
            assertEquals(0, server.getCount)
            val record = requireNotNull(submissionRecordStore(directory).recordFor(WINDOW_ID))
            assertNotNull(record.unresolvedReason, "the record must say why nothing was sent")
            assertEquals("invalid_configuration", record.terminalErrorCode)

            // A later ordinary trigger must not retry it either — held means held.
            drain.drain()
            Thread.sleep(150)
            assertEquals(0, server.postCount)
        } finally {
            server.stop()
        }
    }

    /** The nearby-card-tap join path: no join-time verified Event Definition, resolved fresh by a registry lookup. */
    @Test
    fun nearbyJoinWindowDrainsAfterARegistryLookupResolvesItsConfiguration() {
        val directory = Files.createTempDirectory("drain-nearby-join-resolves").toFile()
        val server = newStubOperatorServer()
        val endpoint = server.start()
        try {
            val resolver = FakeConfigurationResolver(resolvedConfiguration(endpoint))
            val (accumulator, drain) = buildSystem(
                directory = directory,
                cryptography = vectorCryptography(),
                submissionConfiguration = null, // no join-time definition, as on the nearby-card path
                configurationResolver = resolver,
            )
            closeOneWindow(accumulator)

            drain.drain()

            waitUntil { server.postCount == 1 }
            waitUntil { submissionRecordStore(directory).recordFor(WINDOW_ID)?.acceptanceReceiptHex != null }
            Thread.sleep(150)

            assertEquals(1, server.postCount)
            assertEquals(1, resolver.callCount, "the registry lookup must run exactly once for this artifact")
            val record = requireNotNull(submissionRecordStore(directory).recordFor(WINDOW_ID))
            assertNull(record.unresolvedReason, "a resolved lookup must clear the unresolved reason")
            assertNotNull(record.submissionEndpoint, "the resolved configuration must be persisted")
        } finally {
            server.stop()
        }
    }

    /** A transport failure is deferred, then the exact durable bytes are submitted after registry recovery. */
    @Test
    fun nearbyJoinWindowWhoseRegistryLookupTimesOutRetriesTheSameBytesOnceAfterResolution() {
        val directory = Files.createTempDirectory("drain-nearby-join-lookup-retries").toFile()
        val server = newStubOperatorServer()
        val endpoint = server.start()
        try {
            var nowEpochMilliseconds = NOW_EPOCH_MILLIS
            val resolver = FakeConfigurationResolver(
                resolutions = listOf(
                    submissionConfigurationResolutionForRegistryResult(configuration = null, errorCode = "timeout"),
                    SubmissionConfigurationResolution.Resolved(resolvedConfiguration(endpoint)),
                ),
            )
            val (accumulator, drain) = buildSystem(
                directory = directory,
                cryptography = vectorCryptography(),
                submissionConfiguration = null,
                configurationResolver = resolver,
                nowEpochMilliseconds = { nowEpochMilliseconds },
            )
            closeOneWindow(accumulator)
            val originalBytes = requireNotNull(directory.resolve("observations").listFiles()?.singleOrNull()).readBytes()

            drain.drain()
            Thread.sleep(250)

            assertEquals(0, server.postCount, "a timed-out registry lookup must never be guessed around")
            assertEquals(1, resolver.callCount)
            val record = requireNotNull(submissionRecordStore(directory).recordFor(WINDOW_ID))
            assertNull(record.terminalErrorCode, "a transport failure must not become invalid_configuration")
            assertTrue(
                ledgerFile(directory).readText().contains("\tretryable_failed\t${NOW_EPOCH_MILLIS + RETRY_BACKOFF_MILLIS}\t"),
                "the durable retry deadline must be finite",
            )

            nowEpochMilliseconds += RETRY_BACKOFF_MILLIS
            drain.drain()
            waitUntil { server.postCount == 1 }
            waitUntil { submissionRecordStore(directory).recordFor(WINDOW_ID)?.acceptanceReceiptHex != null }
            Thread.sleep(150)

            assertEquals(2, resolver.callCount)
            assertEquals(1, server.getCount, "attempt two must look up a receipt before re-POSTing")
            assertEquals(1, server.postCount)
            assertContentEquals(originalBytes, server.postBodies.single())
        } finally {
            server.stop()
        }
    }

    /** A definition that was fetched but failed verification stays held and is never POSTed. */
    @Test
    fun nearbyJoinWindowWhoseRegistryDefinitionIsUnusableIsHeldWithZeroPosts() {
        val directory = Files.createTempDirectory("drain-nearby-join-unusable-definition").toFile()
        val server = newStubOperatorServer()
        server.start()
        try {
            val resolver = FakeConfigurationResolver(
                submissionConfigurationResolutionForRegistryResult(
                    configuration = null,
                    errorCode = "definition_hash_mismatch",
                ),
            )
            val (accumulator, drain) = buildSystem(
                directory = directory,
                cryptography = vectorCryptography(),
                submissionConfiguration = null,
                configurationResolver = resolver,
            )
            closeOneWindow(accumulator)

            drain.drain()
            Thread.sleep(250)

            assertEquals(0, server.postCount)
            assertEquals(1, resolver.callCount)
            val record = requireNotNull(submissionRecordStore(directory).recordFor(WINDOW_ID))
            assertEquals("invalid_configuration", record.terminalErrorCode)
            assertTrue(
                ledgerFile(directory).readText().contains("\tretryable_failed\t${Long.MAX_VALUE}\t"),
                "permanently unusable verified evidence must remain held",
            )

            drain.drain()
            Thread.sleep(150)
            assertEquals(1, resolver.callCount)
            assertEquals(0, server.postCount)
        } finally {
            server.stop()
        }
    }

    /**
     * A crash between `persistDraft()` and `persistSubmissionRecord()`
     * (`WindowObservationAccumulator.kt:340-341`) leaves a durable draft
     * with no `SubmissionRecord` at all — not merely an unresolved one.
     * Built directly on the shared ledger/draft primitives (the same ones
     * `WindowObservationAccumulator` itself uses) rather than by
     * interrupting the accumulator mid-call, since there is no seam to
     * interrupt a private function at.
     *
     * The assertion is durable evidence of recovery (a POST actually
     * happens after restart), not merely that a code path was reached —
     * this is precisely the failure that made the original defect silent.
     */
    @Test
    fun crashBetweenDraftAndSubmissionRecordDoesNotStallTheDeviceForever() {
        val directory = Files.createTempDirectory("drain-crash-at-open").toFile()
        val server = newStubOperatorServer()
        val endpoint = server.start()
        try {
            // Simulate the crash: ledger open row + draft are durable, no
            // SubmissionRecord was ever written for this window.
            val ledgerStore = UnsentWindowLedgerStore(ledgerFile(directory))
            val created = requireNotNull(createUnsentWindowLedger(LEDGER_INSTANCE_ID).ledger)
            val opened = openUnsentWindow(created, WINDOW_ID)
            ledgerStore.persist(opened)
            confirmUnsentWindowLedgerPersistence(opened.ledger, opened.persistenceRevision)

            val draftStore = WindowObservationDraftStore(directory.resolve("draft.snapshot"))
            var draft = requireNotNull(
                createWindowObservationDraft(
                    windowId = WINDOW_ID,
                    enin = ENIN,
                    eventCode = EVENT_CODE,
                    eventIdHex = EVENT_ID_HEX,
                    eventDefinitionDigestHex = DEFINITION_DIGEST_HEX,
                    participantCommitmentHex = PARTICIPANT_COMMITMENT_HEX,
                    reporterRpidHex = REPORTER_RPID,
                ).draft,
            )
            listOf(RPID_ONE, RPID_TWO).forEach { rpid ->
                draft = requireNotNull(addWindowObservationDraftRpid(draft, rpid).draft)
            }
            draftStore.persist(draft)
            assertNull(submissionRecordStore(directory).recordFor(WINDOW_ID), "precondition: the crash left no record at all")

            // "Restart": fresh accumulator + drain over the same files. The
            // registry-lookup fallback (not the context's own
            // submissionConfiguration, which recovery never consults) is
            // what must resolve this window's configuration.
            val resolver = FakeConfigurationResolver(resolvedConfiguration(endpoint))
            val (accumulator, drain) = buildSystem(
                directory = directory,
                cryptography = vectorCryptography(),
                submissionConfiguration = null,
                configurationResolver = resolver,
            )
            accumulator.recoverAfterRelaunch()
            drain.resumeAfterRestore()

            waitUntil { server.postCount == 1 }
            waitUntil { submissionRecordStore(directory).recordFor(WINDOW_ID)?.acceptanceReceiptHex != null }
            Thread.sleep(150)

            assertEquals(1, server.postCount, "the recovered window must actually drain, not stall forever")
            assertEquals(1, resolver.callCount)
        } finally {
            server.stop()
        }
    }

    /**
     * The second instance of the same defect, one call-frame up in the same
     * function: a crash AFTER `restoreDurableDraftEvidence()`'s own
     * `persistObservation(...)` made the artifact durable, but before it
     * could reach `submissionRecordStore` — so the artifact is durable, the
     * draft is still present (never cleared), and no `SubmissionRecord`
     * exists. On the next relaunch, `hasDurableArtifactFor(...)` is true, so
     * the pre-fix code took the early `draftStore.clear(); return` branch
     * without ever touching the record store — a second, narrower crash
     * window into the same permanent, device-wide, silent stall as
     * [crashBetweenDraftAndSubmissionRecordDoesNotStallTheDeviceForever].
     *
     * The durable artifact is produced by a throwaway "source" accumulator
     * — the same technique `WindowObservationAccumulatorTest`'s own
     * `relaunchReconcilesAnArtifactMovedBeforeItsLedgerClose` uses — rather
     * than hand-built bytes, since `reconcileDurableArtifactsAfterRelaunch`
     * later verifies the artifact's digest against its filename.
     */
    @Test
    fun crashAfterArtifactBecomesDurableButBeforeSubmissionRecordDoesNotStallTheDeviceForever() {
        val directory = Files.createTempDirectory("drain-crash-after-artifact").toFile()
        val server = newStubOperatorServer()
        val endpoint = server.start()
        try {
            val sourceDirectory = Files.createTempDirectory("drain-crash-after-artifact-source").toFile()
            val sourceAccumulator = WindowObservationAccumulator(
                context = {
                    WindowObservationContext(
                        eventCode = EVENT_CODE,
                        eventIdHex = EVENT_ID_HEX,
                        eventDefinitionDigestHex = DEFINITION_DIGEST_HEX,
                        participantCommitmentHex = PARTICIPANT_COMMITMENT_HEX,
                    )
                },
                cryptography = vectorCryptography(),
                ledgerStore = UnsentWindowLedgerStore(sourceDirectory.resolve("ledger.snapshot")),
                draftStore = WindowObservationDraftStore(sourceDirectory.resolve("draft.snapshot")),
                observationDirectory = sourceDirectory.resolve("observations"),
                nowEpochSeconds = { FINALIZED_AT },
                newWindowId = { UUID.fromString(WINDOW_ID) },
                ledgerInstanceId = { LEDGER_INSTANCE_ID },
            )
            sourceAccumulator.observe(ENIN, RPID_ONE, REPORTER_RPID, recording = true)
            sourceAccumulator.observe(ENIN, RPID_TWO, REPORTER_RPID, recording = true)
            check(sourceAccumulator.close())
            val sourceArtifact = requireNotNull(sourceDirectory.resolve("observations").listFiles()?.singleOrNull())

            // Ledger row for WINDOW_ID is still OPEN: relaunch A's crash was
            // inside `restoreDurableDraftEvidence`, before
            // `reconcileDurableArtifactsAfterRelaunch` — the function that
            // would close it — ever ran.
            val ledgerStore = UnsentWindowLedgerStore(ledgerFile(directory))
            val created = requireNotNull(createUnsentWindowLedger(LEDGER_INSTANCE_ID).ledger)
            val opened = openUnsentWindow(created, WINDOW_ID)
            ledgerStore.persist(opened)
            confirmUnsentWindowLedgerPersistence(opened.ledger, opened.persistenceRevision)

            // The draft is still present — relaunch A died before
            // `draftStore.clear()`.
            val draftStore = WindowObservationDraftStore(directory.resolve("draft.snapshot"))
            var draft = requireNotNull(
                createWindowObservationDraft(
                    windowId = WINDOW_ID,
                    enin = ENIN,
                    eventCode = EVENT_CODE,
                    eventIdHex = EVENT_ID_HEX,
                    eventDefinitionDigestHex = DEFINITION_DIGEST_HEX,
                    participantCommitmentHex = PARTICIPANT_COMMITMENT_HEX,
                    reporterRpidHex = REPORTER_RPID,
                ).draft,
            )
            listOf(RPID_ONE, RPID_TWO).forEach { rpid ->
                draft = requireNotNull(addWindowObservationDraftRpid(draft, rpid).draft)
            }
            draftStore.persist(draft)

            // The artifact IS durable — relaunch A's `persistObservation`
            // already succeeded.
            val observationDirectory = directory.resolve("observations").also { it.mkdirs() }
            sourceArtifact.copyTo(observationDirectory.resolve(sourceArtifact.name))

            assertNull(submissionRecordStore(directory).recordFor(WINDOW_ID), "precondition: the crash left no record at all")

            // "Relaunch B": fresh accumulator + drain over the same files.
            val resolver = FakeConfigurationResolver(resolvedConfiguration(endpoint))
            val secondProcessCryptography = vectorCryptography()
            val (accumulator, drain) = buildSystem(
                directory = directory,
                cryptography = secondProcessCryptography,
                submissionConfiguration = null,
                configurationResolver = resolver,
            )
            accumulator.recoverAfterRelaunch()
            drain.resumeAfterRestore()

            waitUntil { server.postCount == 1 }
            waitUntil { submissionRecordStore(directory).recordFor(WINDOW_ID)?.acceptanceReceiptHex != null }
            Thread.sleep(150)

            assertEquals(1, server.postCount, "the recovered window must actually drain, not stall forever")
            assertEquals(1, resolver.callCount)
            assertEquals(
                0,
                secondProcessCryptography.calls.count { it is FakeSensingCryptography.Call.SignWindowReport },
                "relaunch B must never re-sign an artifact that is already durable",
            )
        } finally {
            server.stop()
        }
    }

    @Test
    fun missingSubmissionRecordDoesNotSilentlyBecomeAPermanentHold() {
        val directory = Files.createTempDirectory("drain-missing-record").toFile()
        val (accumulator, _) = buildSystem(directory, vectorCryptography(), null)
        closeOneWindow(accumulator)
        val emptyStore = SubmissionRecordStore(directory.resolve("missing-records.json"))
        val drain = WindowObservationSubmissionDrain(
            accumulator = accumulator,
            submissionRecordStore = emptyStore,
            client = createSubmissionClient(),
            nowEpochMilliseconds = { NOW_EPOCH_MILLIS },
        )

        drain.drain()

        assertTrue(
            ledgerFile(directory).readText().contains("\tretryable_failed\t${NOW_EPOCH_MILLIS + RETRY_BACKOFF_MILLIS}\t"),
            "a missing diagnostic record must surface as a finite persistence retry, not a successful permanent hold",
        )
        assertNull(emptyStore.recordFor(WINDOW_ID))
    }

    @Test
    fun receiptWriteFailureDoesNotAcknowledgeAndRetryLooksUpWithoutReposting() {
        val directory = Files.createTempDirectory("drain-receipt-write-failure").toFile()
        val server = newStubOperatorServer()
        val endpoint = server.start()
        val recordFile = directory.resolve("submission-records.json")
        var originalRecords = byteArrayOf()
        var now = NOW_EPOCH_MILLIS
        try {
            val (accumulator, drain) = buildSystem(
                directory, vectorCryptography(), resolvedConfiguration(endpoint),
                nowEpochMilliseconds = { now },
                receiptPersistenceGate = {
                    originalRecords = recordFile.readBytes()
                    check(recordFile.delete())
                    check(recordFile.mkdir())
                    recordFile.resolve("keep").writeText("block atomic replacement")
                    true
                },
            )
            closeOneWindow(accumulator)
            drain.drain()
            waitUntil { server.postCount == 1 }
            waitUntil {
                ledgerFile(directory).readText().contains("\tretryable_failed\t${NOW_EPOCH_MILLIS + RETRY_BACKOFF_MILLIS}\t")
            }
            assertTrue(recordFile.isDirectory, "failed receipt storage must remain untouched")

            check(recordFile.resolve("keep").delete())
            check(recordFile.delete())
            recordFile.writeBytes(originalRecords)
            now += RETRY_BACKOFF_MILLIS
            drain.drain()
            waitUntil { submissionRecordStore(directory).recordFor(WINDOW_ID)?.acceptanceReceiptHex != null }
            assertEquals(1, server.postCount, "storage recovery must look up the accepted receipt, never repost it")
            assertEquals(1, server.getCount)
        } finally {
            server.stop()
        }
    }

    @Test
    fun observationDigestWriteFailureStopsBeforeNetworkAndRemainsRetryable() {
        val directory = Files.createTempDirectory("drain-observation-digest-write-failure").toFile()
        val server = newStubOperatorServer()
        val endpoint = server.start()
        val recordFile = directory.resolve("submission-records.json")
        val scheduler = RecordingRetryScheduler()
        try {
            val (accumulator, drain) = buildSystem(
                directory,
                vectorCryptography(),
                resolvedConfiguration(endpoint),
                retryScheduler = scheduler,
            )
            closeOneWindow(accumulator)

            check(recordFile.delete())
            check(recordFile.mkdir())
            recordFile.resolve("keep").writeText("block atomic replacement")

            drain.drain()

            assertEquals(0, server.postCount, "a failed observation digest write must not reach the operator")
            assertEquals(0, server.getCount)
            assertEquals(1, scheduler.scheduledCount)
            assertTrue(
                ledgerFile(directory).readText().contains(
                    "\tretryable_failed\t${NOW_EPOCH_MILLIS + RETRY_BACKOFF_MILLIS}\t",
                ),
                "a failed observation digest write must leave the submission retryable",
            )
            assertTrue(recordFile.isDirectory, "failed digest storage must remain untouched")
        } finally {
            server.stop()
        }
    }

    @Test
    fun resolvedConfigurationWriteFailureStopsBeforeNetworkAndRemainsRetryable() {
        val directory = Files.createTempDirectory("drain-configuration-write-failure").toFile()
        val server = newStubOperatorServer()
        val endpoint = server.start()
        val recordFile = directory.resolve("submission-records.json")
        try {
            val resolver = WindowObservationSubmissionDrain.SubmissionConfigurationResolver { _, completion ->
                check(recordFile.delete())
                check(recordFile.mkdir())
                recordFile.resolve("keep").writeText("block atomic replacement")
                completion(SubmissionConfigurationResolution.Resolved(resolvedConfiguration(endpoint)))
            }
            val (accumulator, drain) = buildSystem(
                directory, vectorCryptography(), null, configurationResolver = resolver,
            )
            closeOneWindow(accumulator)

            drain.drain()

            assertEquals(0, server.postCount)
            assertEquals(0, server.getCount)
            assertTrue(
                ledgerFile(directory).readText().contains("\tretryable_failed\t${NOW_EPOCH_MILLIS + RETRY_BACKOFF_MILLIS}\t"),
                "a failed configuration write must not strand an in-flight submission",
            )
        } finally {
            server.stop()
        }
    }

    /**
     * beid#607, fresh-install shape: a window whose registry evidence is
     * permanently unusable is held, and a window closed after it must still
     * reach the operator. The held window is built from ledger primitives
     * (the conformance-vector signature is valid for exactly one window id,
     * which the real window [WINDOW_ID] behind it needs).
     */
    @Test
    fun aHeldWindowDoesNotBlockTheWindowClosedAfterIt() {
        val directory = Files.createTempDirectory("drain-held-head").toFile()
        val server = newStubOperatorServer()
        val endpoint = server.start()
        try {
            val ledgerStore = UnsentWindowLedgerStore(ledgerFile(directory))
            val created = requireNotNull(createUnsentWindowLedger(LEDGER_INSTANCE_ID).ledger)
            val opened = openUnsentWindow(created, HELD_WINDOW_ID)
            ledgerStore.persist(opened)
            val openedLedger = confirmUnsentWindowLedgerPersistence(opened.ledger, opened.persistenceRevision).ledger
            val closed = closeUnsentWindow(openedLedger, HELD_WINDOW_ID, HELD_OBSERVATION_DIGEST_HEX)
            ledgerStore.persist(closed)
            submissionRecordStore(directory).add(unresolvedRecord(HELD_WINDOW_ID))

            val resolver = FakeConfigurationResolver(
                resolutions = listOf(
                    SubmissionConfigurationResolution.PermanentlyUnusable("definition_hash_mismatch"),
                    SubmissionConfigurationResolution.Resolved(resolvedConfiguration(endpoint)),
                ),
            )
            val (accumulator, drain) = buildSystem(
                directory = directory,
                cryptography = vectorCryptography(),
                submissionConfiguration = null,
                configurationResolver = resolver,
            )
            closeOneWindow(accumulator)

            drain.drain()

            waitUntil { server.postCount == 1 }
            waitUntil { submissionRecordStore(directory).recordFor(WINDOW_ID)?.acceptanceReceiptHex != null }
            Thread.sleep(150)
            assertEquals(2, resolver.callCount, "the held window and the window behind it must each be resolved once")
            assertEquals(1, server.postCount, "the window behind the held one must be POSTed exactly once")
            assertEquals(
                "invalid_configuration",
                submissionRecordStore(directory).recordFor(HELD_WINDOW_ID)?.terminalErrorCode,
                "held still means held: the held window itself is never sent",
            )
        } finally {
            server.stop()
        }
    }

    /**
     * beid#607, the shape already on devices: a ledger written before the
     * fix, whose head report was held as RETRYABLE_FAILED with a
     * Long.MAX_VALUE deadline. A relaunched process must drain past it
     * without rewriting, rejecting or retrying the held report.
     */
    @Test
    fun aLedgerHeldByAnEarlierBuildDrainsTheWindowClosedAfterRelaunch() {
        val directory = Files.createTempDirectory("drain-legacy-held-head").toFile()
        val server = newStubOperatorServer()
        val endpoint = server.start()
        try {
            ledgerFile(directory).writeText(legacyHeldLedgerSnapshot())
            submissionRecordStore(directory).add(
                unresolvedRecord(HELD_WINDOW_ID).copy(terminalErrorCode = "invalid_configuration"),
            )
            val resolver = FakeConfigurationResolver(resolvedConfiguration(endpoint))
            val (accumulator, drain) = buildSystem(
                directory = directory,
                cryptography = vectorCryptography(),
                submissionConfiguration = null,
                configurationResolver = resolver,
            )
            accumulator.recoverAfterRelaunch()
            drain.resumeAfterRestore()
            closeOneWindow(accumulator)

            drain.drain()

            waitUntil { server.postCount == 1 }
            waitUntil { submissionRecordStore(directory).recordFor(WINDOW_ID)?.acceptanceReceiptHex != null }
            Thread.sleep(150)
            assertEquals(1, server.postCount)
            assertEquals(1, resolver.callCount, "only the new window is resolved; the held one is never retried")
        } finally {
            server.stop()
        }
    }

    private fun unresolvedRecord(windowId: String) = SubmissionRecord(
        windowId = windowId,
        eventIdHex = HELD_EVENT_ID_HEX,
        submissionEndpoint = null,
        receiptPublicKeyHex = null,
        operatorIdHex = null,
        eventDefinitionDigestHex = null,
        validFrom = null,
        validUntil = null,
        unresolvedReason = "no verified Event Definition was available when this window opened",
    )

    /** open (r1), close (r2), select (r3), hold with Long.MAX_VALUE (r4) — what the drain wrote before #607. */
    private fun legacyHeldLedgerSnapshot(): String {
        val windowHex = HELD_WINDOW_ID.encodeToByteArray().toLowercaseHex()
        val referenceHex = HELD_OBSERVATION_DIGEST_HEX.encodeToByteArray().toLowercaseHex()
        return listOf(
            "beid-ledger-snapshot\t1",
            "revision\t4",
            "ledger-id\t$LEDGER_INSTANCE_ID",
            "next-window-sequence\t2",
            "next-report-sequence\t2",
            "windows\t1",
            "window\t$windowHex\t1\t2\t$referenceHex",
            "reports\t1",
            "report\t${LEDGER_INSTANCE_ID}0000000000000001\t4\t1\tretryable_failed\t${Long.MAX_VALUE}\t-\t$windowHex",
            "end",
        ).joinToString("\n", postfix = "\n")
    }

    private class FakeConfigurationResolver(
        private val resolutions: List<SubmissionConfigurationResolution>,
    ) : WindowObservationSubmissionDrain.SubmissionConfigurationResolver {
        constructor(configuration: SubmissionOperatorConfiguration?) : this(
            listOf(
                if (configuration != null) {
                    SubmissionConfigurationResolution.Resolved(configuration)
                } else {
                    SubmissionConfigurationResolution.PermanentlyUnusable(errorCode = null)
                },
            ),
        )

        constructor(resolution: SubmissionConfigurationResolution) : this(listOf(resolution))

        var callCount = 0
            private set

        override fun resolve(eventIdHex: String, completion: (SubmissionConfigurationResolution) -> Unit) {
            callCount++
            completion(resolutions.getOrElse(callCount - 1) { resolutions.last() })
        }
    }

    private class RecordingRetryScheduler : WindowObservationSubmissionDrain.RetryScheduler {
        var scheduledCount = 0
        var delayMillis = 0L
        lateinit var task: () -> Unit

        override fun schedule(delayMillis: Long, task: () -> Unit): WindowObservationSubmissionDrain.RetryHandle {
            scheduledCount++
            this.delayMillis = delayMillis
            this.task = task
            return WindowObservationSubmissionDrain.RetryHandle { }
        }
    }

    // --- fixtures ---

    private fun buildSystem(
        directory: File,
        cryptography: SensingCryptography,
        submissionConfiguration: SubmissionOperatorConfiguration?,
        receiptPersistenceGate: () -> Boolean = { true },
        configurationResolver: WindowObservationSubmissionDrain.SubmissionConfigurationResolver? = null,
        retryScheduler: WindowObservationSubmissionDrain.RetryScheduler? = null,
        nowEpochMilliseconds: () -> Long = { NOW_EPOCH_MILLIS },
    ): Pair<WindowObservationAccumulator, WindowObservationSubmissionDrain> {
        val context = WindowObservationContext(
            eventCode = EVENT_CODE,
            eventIdHex = EVENT_ID_HEX,
            eventDefinitionDigestHex = DEFINITION_DIGEST_HEX,
            participantCommitmentHex = PARTICIPANT_COMMITMENT_HEX,
            submissionConfiguration = submissionConfiguration,
        )
        val submissionRecordStore = submissionRecordStore(directory)
        lateinit var drain: WindowObservationSubmissionDrain
        val accumulator = WindowObservationAccumulator(
            context = { context },
            cryptography = cryptography,
            ledgerStore = UnsentWindowLedgerStore(ledgerFile(directory)),
            draftStore = WindowObservationDraftStore(directory.resolve("draft.snapshot")),
            observationDirectory = directory.resolve("observations"),
            nowEpochSeconds = { FINALIZED_AT },
            submissionRecordStore = submissionRecordStore,
            newWindowId = { UUID.fromString(WINDOW_ID) },
            ledgerInstanceId = { LEDGER_INSTANCE_ID },
            onSubmissionEmitted = { submission, origin -> drain.receiveEmittedSubmission(submission, origin) },
        )
        drain = WindowObservationSubmissionDrain(
            accumulator = accumulator,
            submissionRecordStore = submissionRecordStore,
            client = createSubmissionClient(),
            nowEpochMilliseconds = nowEpochMilliseconds,
            allowInsecureLoopbackForTests = true,
            receiptPersistenceGate = receiptPersistenceGate,
            configurationResolver = configurationResolver,
            retryScheduler = retryScheduler,
        )
        return accumulator to drain
    }

    private fun closeOneWindow(accumulator: WindowObservationAccumulator) {
        accumulator.observe(ENIN, RPID_ONE, REPORTER_RPID, recording = true)
        accumulator.observe(ENIN, RPID_TWO, REPORTER_RPID, recording = true)
        check(accumulator.close())
    }

    private fun resolvedConfiguration(endpoint: String): SubmissionOperatorConfiguration = requireNotNull(
        createSubmissionOperatorConfiguration(
            endpoint = endpoint,
            receiptPublicKeyHex = RECEIPT_PUBLIC_KEY_HEX,
            eventIdHex = EVENT_ID_HEX,
            eventDefinitionDigestHex = DEFINITION_DIGEST_HEX,
            allowInsecureLoopbackForTests = true,
        ),
    )

    private fun newStubOperatorServer(): StubOperatorServer = StubOperatorServer(
        operatorIdHex = OPERATOR_ID_HEX,
        eventIdHex = EVENT_ID_HEX,
        receiptPublicKeyHex = RECEIPT_PUBLIC_KEY_HEX,
        receiptPrivateScalar = RECEIPT_PRIVATE_SCALAR,
        nowEpochSeconds = { NOW_EPOCH_MILLIS / 1_000L },
    )

    private fun submissionRecordStore(directory: File): SubmissionRecordStore =
        SubmissionRecordStore(directory.resolve("submission-records.json"))

    private fun ledgerFile(directory: File): File = directory.resolve("ledger.snapshot")

    /** The one conformance-vector-valid cryptography fixture every test uses — see the companion object's constants doc. */
    private fun vectorCryptography(): FakeSensingCryptography = FakeSensingCryptography(
        eventSigningPublicKeyResult = EVENT_SIGNING_PUBLIC_KEY_HEX.hexToByteArray(),
        signWindowReportResult = SensingRecoverableSignature(
            EVENT_SIGNATURE_R.hexToByteArray(),
            EVENT_SIGNATURE_S.hexToByteArray(),
            0,
        ),
    )

    private fun waitUntil(timeoutMillis: Long = 5_000L, condition: () -> Boolean) {
        val deadline = System.currentTimeMillis() + timeoutMillis
        while (System.currentTimeMillis() < deadline) {
            if (condition()) return
            Thread.sleep(10)
        }
        check(condition()) { "condition not met within ${timeoutMillis}ms" }
    }

    private companion object {
        // Same conformance vector WindowObservationAccumulatorTest pins
        // (window id, RPIDs, event identity, participant commitment,
        // finalizedAt, event-signing public key and signature): the shared
        // observation-signing path cryptographically verifies the signature
        // against the exact message these produce, so this suite reuses the
        // one message that vector is known valid for rather than minting a
        // new one.
        const val ENIN = 6_000_000L
        const val FINALIZED_AT = 1_800_000_000.75
        const val NOW_EPOCH_MILLIS = 1_800_000_000_000L
        const val RETRY_BACKOFF_MILLIS = 30_000L
        const val EVENT_CODE = "event"
        val EVENT_ID_HEX = "21".repeat(32)
        val DEFINITION_DIGEST_HEX = "22".repeat(32)
        val PARTICIPANT_COMMITMENT_HEX = "ab".repeat(32)
        const val LEDGER_INSTANCE_ID = "000102030405060708090a0b0c0d0e0f"
        const val WINDOW_ID = "00112233-4455-6677-8899-aabbccddeeff"
        const val HELD_WINDOW_ID = "ffeeddcc-bbaa-9988-7766-554433221100"
        val HELD_OBSERVATION_DIGEST_HEX = "44".repeat(32)
        val HELD_EVENT_ID_HEX = "33".repeat(32)
        const val REPORTER_RPID = "0110101010101010101010101010101010"
        const val RPID_ONE = "0111111111111111111111111111111111"
        const val RPID_TWO = "0122222222222222222222222222222222"
        const val EVENT_SIGNING_PUBLIC_KEY_HEX = "0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798"
        const val EVENT_SIGNATURE_R = "d9b39668ed2e92db7226461f059a1ecd06a732bd5bfdae0b23d43390a8025349"
        const val EVENT_SIGNATURE_S = "462b3ecfaa8305881ad1a8b8960e9f3f1e6770683e0c178543613de942c8b765"
        const val RECEIPT_PUBLIC_KEY_HEX = "02c6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee5"
        const val RECEIPT_PRIVATE_SCALAR = 2
        val OPERATOR_ID_HEX = testAcceptanceOperatorIdHex(RECEIPT_PUBLIC_KEY_HEX)
    }
}
