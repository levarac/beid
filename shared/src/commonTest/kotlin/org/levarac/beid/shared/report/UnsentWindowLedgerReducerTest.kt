package org.levarac.beid.shared.report

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class UnsentWindowLedgerReducerTest {
    @Test
    fun closeMustBeDurableBeforeReportPreparationAndPreparedReportMustBeDurableBeforeSubmission() {
        val created = createUnsentWindowLedger(
            ledgerInstanceIdHex = "000102030405060708090a0b0c0d0e0f",
        )
        assertTrue(created.isSuccess)
        var ledger = assertNotNull(created.ledger)

        val opened = openUnsentWindow(
            ledger = ledger,
            windowId = "window-1",
        )
        assertTrue(opened.isSuccess)
        assertTrue(opened.changed)
        assertEquals(1L, opened.persistenceRevision)
        ledger = opened.ledger

        val closed = closeUnsentWindow(
            ledger = ledger,
            windowId = "window-1",
            persistedObservationReference = "window-1",
        )
        assertTrue(closed.isSuccess)
        assertTrue(closed.changed)
        assertEquals(2L, closed.persistenceRevision)
        ledger = closed.ledger

        val beforeClosePersistence = prepareNextUnsentWindowSubmission(
            ledger = ledger,
            maximumWindowCount = 10,
            nowEpochMilliseconds = 0L,
        )
        assertTrue(beforeClosePersistence.isSuccess)
        assertFalse(beforeClosePersistence.changed)
        assertEquals(0L, beforeClosePersistence.persistenceRevision)
        assertNull(beforeClosePersistence.submission)
        ledger = beforeClosePersistence.ledger

        val closePersisted = confirmUnsentWindowLedgerPersistence(
            ledger = ledger,
            revision = closed.persistenceRevision,
        )
        assertTrue(closePersisted.isSuccess)
        assertFalse(closePersisted.changed)
        assertEquals(0L, closePersisted.persistenceRevision)
        assertNull(closePersisted.submission)
        ledger = closePersisted.ledger

        val prepared = prepareNextUnsentWindowSubmission(
            ledger = ledger,
            maximumWindowCount = 10,
            nowEpochMilliseconds = 0L,
        )
        assertTrue(prepared.isSuccess)
        assertTrue(prepared.changed)
        assertEquals(3L, prepared.persistenceRevision)
        assertNull(prepared.submission)
        ledger = prepared.ledger

        val reportPersisted = confirmUnsentWindowLedgerPersistence(
            ledger = ledger,
            revision = prepared.persistenceRevision,
        )
        assertTrue(reportPersisted.isSuccess)
        assertFalse(reportPersisted.changed)
        assertEquals(0L, reportPersisted.persistenceRevision)

        val submission = assertNotNull(reportPersisted.submission)
        assertEquals("000102030405060708090a0b0c0d0e0f0000000000000001", submission.submissionKey)
        assertEquals(1, submission.attempt)
        assertEquals(1, submission.windowCount)
        assertEquals("window-1", submission.windowIdAt(0))
    }

    @Test
    fun persistenceConfirmationMustMatchTheExactLedgerRevision() {
        var ledger = assertNotNull(
            createUnsentWindowLedger(
                ledgerInstanceIdHex = "000102030405060708090a0b0c0d0e0f",
            ).ledger,
        )
        val opened = openUnsentWindow(ledger, "window-1")
        val closed = closeUnsentWindow(opened.ledger, "window-1", "window-1")

        val staleConfirmation = confirmUnsentWindowLedgerPersistence(
            ledger = closed.ledger,
            revision = opened.persistenceRevision,
        )
        assertFalse(staleConfirmation.isSuccess)
        assertEquals("invalid_persistence_revision", staleConfirmation.errorCode)
        assertNull(staleConfirmation.submission)

        val stillBlocked = prepareNextUnsentWindowSubmission(
            ledger = staleConfirmation.ledger,
            maximumWindowCount = 10,
            nowEpochMilliseconds = 0L,
        )
        assertTrue(stillBlocked.isSuccess)
        assertFalse(stillBlocked.changed)
        assertNull(stillBlocked.submission)
    }

    @Test
    fun closeRequiresAPersistedObservationReferenceAndRestorePreservesIt() {
        var ledger = assertNotNull(
            createUnsentWindowLedger(
                ledgerInstanceIdHex = "000102030405060708090a0b0c0d0e0f",
            ).ledger,
        )
        ledger = openUnsentWindow(ledger, "window-1").ledger

        val missingObservation = closeUnsentWindow(
            ledger = ledger,
            windowId = "window-1",
            persistedObservationReference = "",
        )
        assertFalse(missingObservation.isSuccess)
        assertFalse(missingObservation.changed)
        assertEquals("invalid_observation_reference", missingObservation.errorCode)

        val closed = closeUnsentWindow(
            ledger = ledger,
            windowId = "window-1",
            persistedObservationReference = "observation-1",
        )
        ledger = confirmUnsentWindowLedgerPersistence(
            ledger = closed.ledger,
            revision = closed.persistenceRevision,
        ).ledger
        val prepared = prepareNextUnsentWindowSubmission(ledger, 10, 0L)
        val persisted = confirmUnsentWindowLedgerPersistence(
            ledger = prepared.ledger,
            revision = prepared.persistenceRevision,
        )
        val submission = assertNotNull(persisted.submission)
        assertEquals("observation-1", submission.observationReferenceAt(0))

        val restored = assertNotNull(
            decodeUnsentWindowLedgerSnapshot(
                encodeUnsentWindowLedgerSnapshot(persisted.ledger),
            ).ledger,
        )
        val resumed = assertNotNull(
            resumeUnsentWindowSubmissionAfterRestore(restored).submission,
        )
        assertEquals("observation-1", resumed.observationReferenceAt(0))
    }

    @Test
    fun retryAtTheExactDeadlineKeepsTheSubmissionIdentityAndPersistsTheAttemptBeforeDispatch() {
        val initial = createDurableSubmission(windowId = "window-1")

        val failed = markUnsentWindowSubmissionRetryable(
            ledger = initial.ledger,
            submissionKey = initial.submission.submissionKey,
            retryNotBeforeEpochMilliseconds = 1_000L,
        )
        assertTrue(failed.isSuccess)
        assertTrue(failed.changed)
        assertEquals(4L, failed.persistenceRevision)
        assertNull(failed.submission)

        val beforeFailurePersistence = prepareNextUnsentWindowSubmission(
            ledger = failed.ledger,
            maximumWindowCount = 10,
            nowEpochMilliseconds = 1_000L,
        )
        assertTrue(beforeFailurePersistence.isSuccess)
        assertFalse(beforeFailurePersistence.changed)
        assertNull(beforeFailurePersistence.submission)

        val failurePersisted = confirmUnsentWindowLedgerPersistence(
            ledger = failed.ledger,
            revision = failed.persistenceRevision,
        )
        assertTrue(failurePersisted.isSuccess)
        assertNull(failurePersisted.submission)

        val beforeDeadline = prepareNextUnsentWindowSubmission(
            ledger = failurePersisted.ledger,
            maximumWindowCount = 10,
            nowEpochMilliseconds = 999L,
        )
        assertTrue(beforeDeadline.isSuccess)
        assertFalse(beforeDeadline.changed)
        assertNull(beforeDeadline.submission)

        val retryPrepared = prepareNextUnsentWindowSubmission(
            ledger = beforeDeadline.ledger,
            maximumWindowCount = 10,
            nowEpochMilliseconds = 1_000L,
        )
        assertTrue(retryPrepared.isSuccess)
        assertTrue(retryPrepared.changed)
        assertEquals(5L, retryPrepared.persistenceRevision)
        assertNull(retryPrepared.submission)

        val retryPersisted = confirmUnsentWindowLedgerPersistence(
            ledger = retryPrepared.ledger,
            revision = retryPrepared.persistenceRevision,
        )
        val retriedSubmission = assertNotNull(retryPersisted.submission)
        assertEquals(initial.submission.submissionKey, retriedSubmission.submissionKey)
        assertEquals(2, retriedSubmission.attempt)
        assertEquals(initial.submission.windowCount, retriedSubmission.windowCount)
        assertEquals(initial.submission.windowIdAt(0), retriedSubmission.windowIdAt(0))
    }

    @Test
    fun inFlightSnapshotHasCanonicalBytesAndRestoreResumesTheSameSubmissionOnce() {
        val initial = createDurableSubmission(windowId = "window-1")

        val snapshot = encodeUnsentWindowLedgerSnapshot(initial.ledger)
        val expectedSnapshot =
            "beid-ledger-snapshot\t1\n" +
                "revision\t3\n" +
                "ledger-id\t000102030405060708090a0b0c0d0e0f\n" +
                "next-window-sequence\t2\n" +
                "next-report-sequence\t2\n" +
                "windows\t1\n" +
                "window\t77696e646f772d31\t1\t2\t77696e646f772d31\n" +
                "reports\t1\n" +
                "report\t000102030405060708090a0b0c0d0e0f0000000000000001\t3\t1\tin_flight\t-\t-\t77696e646f772d31\n" +
                "end\n"
        assertEquals(expectedSnapshot, snapshot)

        val decoded = decodeUnsentWindowLedgerSnapshot(snapshot)
        assertTrue(decoded.isSuccess)
        assertNull(decoded.errorCode)
        assertEquals(3L, decoded.persistenceRevision)
        val restoredLedger = assertNotNull(decoded.ledger)
        assertEquals(snapshot, encodeUnsentWindowLedgerSnapshot(restoredLedger))

        val resumed = resumeUnsentWindowSubmissionAfterRestore(restoredLedger)
        assertTrue(resumed.isSuccess)
        assertFalse(resumed.changed)
        assertEquals(0L, resumed.persistenceRevision)
        val resumedSubmission = assertNotNull(resumed.submission)
        assertEquals(initial.submission.submissionKey, resumedSubmission.submissionKey)
        assertEquals(initial.submission.attempt, resumedSubmission.attempt)
        assertEquals(initial.submission.windowCount, resumedSubmission.windowCount)
        assertEquals(initial.submission.windowIdAt(0), resumedSubmission.windowIdAt(0))

        val duplicateResume = resumeUnsentWindowSubmissionAfterRestore(resumed.ledger)
        assertTrue(duplicateResume.isSuccess)
        assertNull(duplicateResume.submission)
    }

    @Test
    fun pendingClosedWindowSurvivesRestoreAndBecomesAReportOnlyAfterSelectionIsPersisted() {
        var ledger = assertNotNull(
            createUnsentWindowLedger(
                ledgerInstanceIdHex = "000102030405060708090a0b0c0d0e0f",
            ).ledger,
        )
        ledger = openUnsentWindow(ledger, "window-1").ledger
        val closed = closeUnsentWindow(ledger, "window-1", "observation-1")
        val closePersisted = confirmUnsentWindowLedgerPersistence(
            ledger = closed.ledger,
            revision = closed.persistenceRevision,
        )
        val restored = assertNotNull(
            decodeUnsentWindowLedgerSnapshot(
                assertNotNull(closed.snapshotText),
            ).ledger,
        )

        val prepared = prepareNextUnsentWindowSubmission(
            ledger = restored,
            maximumWindowCount = 10,
            nowEpochMilliseconds = 0L,
        )
        assertTrue(prepared.changed)
        assertNull(prepared.submission)
        val persisted = confirmUnsentWindowLedgerPersistence(
            ledger = prepared.ledger,
            revision = prepared.persistenceRevision,
        )
        val submission = assertNotNull(persisted.submission)
        assertEquals(1, submission.windowCount)
        assertEquals("window-1", submission.windowIdAt(0))
        assertEquals("observation-1", submission.observationReferenceAt(0))

        // The in-memory confirmation and the decoded durable snapshot describe
        // the same pending state before selection.
        assertEquals(
            encodeUnsentWindowLedgerSnapshot(closePersisted.ledger),
            encodeUnsentWindowLedgerSnapshot(restored),
        )
    }

    @Test
    fun acceptedAndIncludedSubmissionSurvivesRestoreAndCanNeverBeResent() {
        val initial = createDurableSubmission(windowId = "window-1")

        val accepted = recordUnsentWindowSubmissionAcceptance(
            ledger = initial.ledger,
            submissionKey = initial.submission.submissionKey,
            persistedAcceptanceReceiptReference = "acceptance-1",
        )
        assertTrue(accepted.isSuccess)
        assertTrue(accepted.changed)
        assertEquals(4L, accepted.persistenceRevision)
        assertNull(accepted.submission)

        val beforeAcceptancePersistence = prepareNextUnsentWindowSubmission(
            ledger = accepted.ledger,
            maximumWindowCount = 10,
            nowEpochMilliseconds = 0L,
        )
        assertTrue(beforeAcceptancePersistence.isSuccess)
        assertFalse(beforeAcceptancePersistence.changed)
        assertNull(beforeAcceptancePersistence.submission)

        val acceptancePersisted = confirmUnsentWindowLedgerPersistence(
            ledger = accepted.ledger,
            revision = accepted.persistenceRevision,
        )
        assertTrue(acceptancePersisted.isSuccess)
        assertNull(acceptancePersisted.submission)

        val included = recordUnsentWindowSubmissionInclusion(
            ledger = acceptancePersisted.ledger,
            submissionKey = initial.submission.submissionKey,
            persistedInclusionReceiptReference = "inclusion-1",
        )
        assertTrue(included.isSuccess)
        assertTrue(included.changed)
        assertEquals(5L, included.persistenceRevision)
        val inclusionPersisted = confirmUnsentWindowLedgerPersistence(
            ledger = included.ledger,
            revision = included.persistenceRevision,
        )

        val restored = assertNotNull(
            decodeUnsentWindowLedgerSnapshot(
                encodeUnsentWindowLedgerSnapshot(inclusionPersisted.ledger),
            ).ledger,
        )
        assertNull(resumeUnsentWindowSubmissionAfterRestore(restored).submission)
        assertNull(
            prepareNextUnsentWindowSubmission(
                ledger = restored,
                maximumWindowCount = 10,
                nowEpochMilliseconds = 0L,
            ).submission,
        )

        val duplicateAcceptance = recordUnsentWindowSubmissionAcceptance(
            ledger = restored,
            submissionKey = initial.submission.submissionKey,
            persistedAcceptanceReceiptReference = "acceptance-1",
        )
        assertTrue(duplicateAcceptance.isSuccess)
        assertFalse(duplicateAcceptance.changed)

        val conflictingAcceptance = recordUnsentWindowSubmissionAcceptance(
            ledger = restored,
            submissionKey = initial.submission.submissionKey,
            persistedAcceptanceReceiptReference = "acceptance-2",
        )
        assertFalse(conflictingAcceptance.isSuccess)
        assertEquals("acceptance_receipt_conflict", conflictingAcceptance.errorCode)

        val duplicateInclusion = recordUnsentWindowSubmissionInclusion(
            ledger = restored,
            submissionKey = initial.submission.submissionKey,
            persistedInclusionReceiptReference = "inclusion-1",
        )
        assertTrue(duplicateInclusion.isSuccess)
        assertFalse(duplicateInclusion.changed)

        val conflictingInclusion = recordUnsentWindowSubmissionInclusion(
            ledger = restored,
            submissionKey = initial.submission.submissionKey,
            persistedInclusionReceiptReference = "inclusion-2",
        )
        assertFalse(conflictingInclusion.isSuccess)
        assertEquals("inclusion_receipt_conflict", conflictingInclusion.errorCode)
    }

    @Test
    fun repeatedIdenticalCloseInputsCloseOneWindowExactlyOnce() {
        var ledger = assertNotNull(
            createUnsentWindowLedger(
                ledgerInstanceIdHex = "000102030405060708090a0b0c0d0e0f",
            ).ledger,
        )
        ledger = openUnsentWindow(ledger, "window-1").ledger

        val first = closeUnsentWindow(ledger, "window-1", "window-1")
        assertTrue(first.isSuccess)
        assertTrue(first.changed)

        val second = closeUnsentWindow(first.ledger, "window-1", "window-1")
        assertTrue(second.isSuccess)
        assertFalse(second.changed)
        assertEquals(0L, second.persistenceRevision)

        val third = closeUnsentWindow(second.ledger, "window-1", "window-1")
        assertTrue(third.isSuccess)
        assertFalse(third.changed)
        assertEquals(0L, third.persistenceRevision)

        ledger = confirmUnsentWindowLedgerPersistence(
            ledger = third.ledger,
            revision = first.persistenceRevision,
        ).ledger
        val prepared = prepareNextUnsentWindowSubmission(ledger, 10, 0L)
        val persisted = confirmUnsentWindowLedgerPersistence(
            ledger = prepared.ledger,
            revision = prepared.persistenceRevision,
        )
        val submission = assertNotNull(persisted.submission)
        assertEquals(1, submission.windowCount)
        assertEquals("window-1", submission.windowIdAt(0))
    }

    @Test
    fun guestLedgerBatchesMultipleClosedWindowsAndLaterSelectsOnlyNewUnsentWindows() {
        var ledger = assertNotNull(
            createUnsentWindowLedger(
                ledgerInstanceIdHex = "000102030405060708090a0b0c0d0e0f",
            ).ledger,
        )
        ledger = openUnsentWindow(ledger, "window-a").ledger
        ledger = closeUnsentWindow(ledger, "window-a", "window-a").ledger
        ledger = openUnsentWindow(ledger, "window-b").ledger
        ledger = closeUnsentWindow(ledger, "window-b", "window-b").ledger
        val openWindow = openUnsentWindow(ledger, "window-still-open")
        ledger = confirmUnsentWindowLedgerPersistence(
            ledger = openWindow.ledger,
            revision = openWindow.persistenceRevision,
        ).ledger

        val firstPrepared = prepareNextUnsentWindowSubmission(ledger, 10, 0L)
        val firstPersisted = confirmUnsentWindowLedgerPersistence(
            ledger = firstPrepared.ledger,
            revision = firstPrepared.persistenceRevision,
        )
        val firstSubmission = assertNotNull(firstPersisted.submission)
        assertEquals(2, firstSubmission.windowCount)
        assertEquals("window-a", firstSubmission.windowIdAt(0))
        assertEquals("window-b", firstSubmission.windowIdAt(1))

        val firstAcknowledged = recordUnsentWindowSubmissionAcceptance(
            ledger = firstPersisted.ledger,
            submissionKey = firstSubmission.submissionKey,
            persistedAcceptanceReceiptReference = "acceptance-1",
        )
        ledger = confirmUnsentWindowLedgerPersistence(
            ledger = firstAcknowledged.ledger,
            revision = firstAcknowledged.persistenceRevision,
        ).ledger

        ledger = openUnsentWindow(ledger, "window-c").ledger
        val closedC = closeUnsentWindow(ledger, "window-c", "window-c")
        ledger = confirmUnsentWindowLedgerPersistence(
            ledger = closedC.ledger,
            revision = closedC.persistenceRevision,
        ).ledger

        val secondPrepared = prepareNextUnsentWindowSubmission(ledger, 10, 0L)
        val secondPersisted = confirmUnsentWindowLedgerPersistence(
            ledger = secondPrepared.ledger,
            revision = secondPrepared.persistenceRevision,
        )
        val secondSubmission = assertNotNull(secondPersisted.submission)
        assertEquals("000102030405060708090a0b0c0d0e0f0000000000000002", secondSubmission.submissionKey)
        assertEquals(1, secondSubmission.windowCount)
        assertEquals("window-c", secondSubmission.windowIdAt(0))
    }

    @Test
    fun relaunchRecoveryClosesDurableObservationsAndDiscardsOnlyUnrecoverableOpenWindows() {
        var ledger = assertNotNull(
            createUnsentWindowLedger(
                ledgerInstanceIdHex = "000102030405060708090a0b0c0d0e0f",
            ).ledger,
        )

        val recoverableOpened = openUnsentWindow(ledger, "window-with-artifact")
        ledger = confirmUnsentWindowLedgerPersistence(
            recoverableOpened.ledger,
            recoverableOpened.persistenceRevision,
        ).ledger
        val lostOpened = openUnsentWindow(ledger, "window-lost-with-process")
        ledger = confirmUnsentWindowLedgerPersistence(
            lostOpened.ledger,
            lostOpened.persistenceRevision,
        ).ledger

        val recoveryInput = createUnsentWindowObservationRecoveryInput()
        assertTrue(
            addPersistedUnsentWindowObservationForRecovery(
                recoveryInput = recoveryInput,
                windowId = "not-in-this-ledger",
                persistedObservationReference = "old-observation",
            ),
        )
        assertTrue(
            addPersistedUnsentWindowObservationForRecovery(
                recoveryInput = recoveryInput,
                windowId = "window-with-artifact",
                persistedObservationReference = "observation-1",
            ),
        )
        assertEquals(2, recoveryInput.observationCount)

        val recovered = reconcileUnsentWindowLedgerAfterRelaunch(
            ledger = ledger,
            recoveryInput = recoveryInput,
        )
        assertTrue(recovered.isSuccess)
        assertTrue(recovered.changed)
        ledger = confirmUnsentWindowLedgerPersistence(
            recovered.ledger,
            recovered.persistenceRevision,
        ).ledger

        val secondReconciliation = reconcileUnsentWindowLedgerAfterRelaunch(
            ledger = ledger,
            recoveryInput = recoveryInput,
        )
        assertTrue(secondReconciliation.isSuccess)
        assertFalse(secondReconciliation.changed)

        val invalidRecoveryInput = createUnsentWindowObservationRecoveryInput()
        assertFalse(
            addPersistedUnsentWindowObservationForRecovery(
                recoveryInput = invalidRecoveryInput,
                windowId = "window-with-artifact",
                persistedObservationReference = charArrayOf(0xd800.toChar()).concatToString(),
            ),
        )

        val conflictingRecoveryInput = createUnsentWindowObservationRecoveryInput()
        assertTrue(
            addPersistedUnsentWindowObservationForRecovery(
                recoveryInput = conflictingRecoveryInput,
                windowId = "window-with-artifact",
                persistedObservationReference = "different-observation",
            ),
        )
        val conflict = reconcileUnsentWindowLedgerAfterRelaunch(
            ledger = ledger,
            recoveryInput = conflictingRecoveryInput,
        )
        assertFalse(conflict.isSuccess)
        assertEquals("observation_reference_conflict", conflict.errorCode)

        val discardedWindowCannotBeClosed = closeUnsentWindow(
            ledger,
            "window-lost-with-process",
            "impossible-observation",
        )
        assertFalse(discardedWindowCannotBeClosed.isSuccess)
        assertEquals("unknown_window_id", discardedWindowCannotBeClosed.errorCode)

        // The orphaned artifact (no LedgerWindow row ever existed for it) must
        // now be adopted as an already-closed window rather than staying
        // permanently invisible to every reducer function that only traverses
        // ledger.state.windows.
        val orphanNowCloseable = closeUnsentWindow(
            ledger,
            "not-in-this-ledger",
            "old-observation",
        )
        assertTrue(orphanNowCloseable.isSuccess)
        assertFalse(
            orphanNowCloseable.changed,
            "reconciliation already adopted the orphan as closed with this exact reference",
        )

        val orphanReferenceConflict = closeUnsentWindow(
            ledger,
            "not-in-this-ledger",
            "different-observation",
        )
        assertFalse(orphanReferenceConflict.isSuccess)
        assertEquals("observation_reference_conflict", orphanReferenceConflict.errorCode)

        val prepared = prepareNextUnsentWindowSubmission(ledger, 10, 0L)
        val persisted = confirmUnsentWindowLedgerPersistence(
            prepared.ledger,
            prepared.persistenceRevision,
        )
        val submission = assertNotNull(persisted.submission)
        assertEquals(2, submission.windowCount)
        assertEquals("not-in-this-ledger", submission.windowIdAt(0))
        assertEquals("old-observation", submission.observationReferenceAt(0))
        assertEquals("window-with-artifact", submission.windowIdAt(1))
        assertEquals("observation-1", submission.observationReferenceAt(1))
    }

    @Test
    fun orphanArrivingAtExactWindowCapacityFailsClosedRatherThanExceedingIt() {
        val instanceId = "000102030405060708090a0b0c0d0e0f"
        val windows = (1L..MAX_LEDGER_RECORD_COUNT.toLong()).map { sequence ->
            LedgerWindow(
                windowId = "window-$sequence",
                openedSequence = sequence,
                closedRevision = 1L,
                observationReference = "observation-$sequence",
            )
        }
        val ledger = UnsentWindowLedger(
            LedgerState(
                ledgerInstanceIdHex = instanceId,
                revision = 1L,
                durableRevision = 1L,
                nextWindowSequence = MAX_LEDGER_RECORD_COUNT.toLong() + 1L,
                nextReportSequence = 1L,
                windows = windows,
            ),
        )

        val recoveryInput = createUnsentWindowObservationRecoveryInput()
        assertTrue(
            addPersistedUnsentWindowObservationForRecovery(
                recoveryInput = recoveryInput,
                windowId = "orphan-over-capacity",
                persistedObservationReference = "orphan-observation",
            ),
        )

        val reconciled = reconcileUnsentWindowLedgerAfterRelaunch(
            ledger = ledger,
            recoveryInput = recoveryInput,
        )
        assertFalse(reconciled.isSuccess)
        assertFalse(reconciled.changed)
        assertEquals("ledger_capacity_exceeded", reconciled.errorCode)
        assertNull(reconciled.snapshotText)
    }

    @Test
    fun multipleOrphansGetDeterministicOrderingAndReconciliationIsIdempotent() {
        var ledger = assertNotNull(
            createUnsentWindowLedger(
                ledgerInstanceIdHex = "000102030405060708090a0b0c0d0e0f",
            ).ledger,
        )

        val recoveryInput = createUnsentWindowObservationRecoveryInput()
        assertTrue(
            addPersistedUnsentWindowObservationForRecovery(
                recoveryInput = recoveryInput,
                windowId = "orphan-b",
                persistedObservationReference = "observation-b",
            ),
        )
        assertTrue(
            addPersistedUnsentWindowObservationForRecovery(
                recoveryInput = recoveryInput,
                windowId = "orphan-a",
                persistedObservationReference = "observation-a",
            ),
        )

        val firstReconciliation = reconcileUnsentWindowLedgerAfterRelaunch(ledger, recoveryInput)
        assertTrue(firstReconciliation.isSuccess)
        assertTrue(firstReconciliation.changed)
        // Native never recorded an openedSequence for either orphan (openUnsentWindow
        // never ran), so ordering has no real chronology to preserve — it must
        // still be assigned deterministically, here by windowId, not by
        // insertion order into recoveryInput ("orphan-b" was added first above).
        val orderedIds = firstReconciliation.ledger.state.windows
            .sortedBy { it.openedSequence }
            .map { it.windowId }
        assertEquals(listOf("orphan-a", "orphan-b"), orderedIds)

        ledger = confirmUnsentWindowLedgerPersistence(
            firstReconciliation.ledger,
            firstReconciliation.persistenceRevision,
        ).ledger

        val secondReconciliation = reconcileUnsentWindowLedgerAfterRelaunch(ledger, recoveryInput)
        assertTrue(secondReconciliation.isSuccess)
        assertFalse(
            secondReconciliation.changed,
            "repeated reconciliation of the same recovery input must be idempotent",
        )
        assertEquals(
            firstReconciliation.ledger.state.windows.map { it.windowId to it.openedSequence },
            secondReconciliation.ledger.state.windows.map { it.windowId to it.openedSequence },
        )

        val prepared = prepareNextUnsentWindowSubmission(ledger, 10, 0L)
        val persisted = confirmUnsentWindowLedgerPersistence(
            prepared.ledger,
            prepared.persistenceRevision,
        )
        val submission = assertNotNull(persisted.submission)
        assertEquals(2, submission.windowCount)
        assertEquals("orphan-a", submission.windowIdAt(0))
        assertEquals("orphan-b", submission.windowIdAt(1))
    }

    @Test
    fun recoveryEntryMatchingACurrentlyOpenWindowClosesItRatherThanSynthesizingADuplicateRow() {
        var ledger = assertNotNull(
            createUnsentWindowLedger(
                ledgerInstanceIdHex = "000102030405060708090a0b0c0d0e0f",
            ).ledger,
        )
        val opened = openUnsentWindow(ledger, "shared-window-id")
        ledger = confirmUnsentWindowLedgerPersistence(
            opened.ledger,
            opened.persistenceRevision,
        ).ledger

        // Native always mints a fresh UUID per window, so this exact
        // shape — a recovery-input key equal to a currently-open window's ID —
        // should not be reachable in practice. The reducer cannot assume that
        // native invariant, so this proves the outcome is still safe: the
        // existing "matched, currently-open" path takes it, and no duplicate
        // LedgerWindow row is ever synthesized for the same ID.
        val recoveryInput = createUnsentWindowObservationRecoveryInput()
        assertTrue(
            addPersistedUnsentWindowObservationForRecovery(
                recoveryInput = recoveryInput,
                windowId = "shared-window-id",
                persistedObservationReference = "observation-1",
            ),
        )

        val reconciled = reconcileUnsentWindowLedgerAfterRelaunch(ledger, recoveryInput)
        assertTrue(reconciled.isSuccess)
        assertTrue(reconciled.changed)

        val matchingWindows = reconciled.ledger.state.windows.filter {
            it.windowId == "shared-window-id"
        }
        assertEquals(
            1,
            matchingWindows.size,
            "a recovery entry matching an existing open window must close it, " +
                "not also synthesize a duplicate row",
        )
        assertEquals(reconciled.persistenceRevision, matchingWindows.single().closedRevision)
        assertEquals("observation-1", matchingWindows.single().observationReference)
    }

    @Test
    fun emptyRecoveryInputStillDiscardsUnmatchedOpenWindowsExactlyAsBeforeThisFix() {
        var ledger = assertNotNull(
            createUnsentWindowLedger(
                ledgerInstanceIdHex = "000102030405060708090a0b0c0d0e0f",
            ).ledger,
        )
        val opened = openUnsentWindow(ledger, "window-lost-with-process")
        ledger = confirmUnsentWindowLedgerPersistence(
            opened.ledger,
            opened.persistenceRevision,
        ).ledger

        val emptyRecoveryInput = createUnsentWindowObservationRecoveryInput()
        assertEquals(0, emptyRecoveryInput.observationCount)

        val reconciled = reconcileUnsentWindowLedgerAfterRelaunch(ledger, emptyRecoveryInput)
        assertTrue(reconciled.isSuccess)
        assertTrue(reconciled.changed)
        assertTrue(reconciled.ledger.state.windows.isEmpty())

        val discardedWindowCannotBeClosed = closeUnsentWindow(
            reconciled.ledger,
            "window-lost-with-process",
            "impossible-observation",
        )
        assertFalse(discardedWindowCannotBeClosed.isSuccess)
        assertEquals("unknown_window_id", discardedWindowCannotBeClosed.errorCode)
    }

    private fun createDurableSubmission(windowId: String): DurableSubmission {
        var ledger = assertNotNull(
            createUnsentWindowLedger(
                ledgerInstanceIdHex = "000102030405060708090a0b0c0d0e0f",
            ).ledger,
        )
        ledger = openUnsentWindow(ledger, windowId).ledger
        val closed = closeUnsentWindow(ledger, windowId, windowId)
        ledger = confirmUnsentWindowLedgerPersistence(
            ledger = closed.ledger,
            revision = closed.persistenceRevision,
        ).ledger
        val prepared = prepareNextUnsentWindowSubmission(
            ledger = ledger,
            maximumWindowCount = 10,
            nowEpochMilliseconds = 0L,
        )
        val persisted = confirmUnsentWindowLedgerPersistence(
            ledger = prepared.ledger,
            revision = prepared.persistenceRevision,
        )
        return DurableSubmission(
            ledger = persisted.ledger,
            submission = assertNotNull(persisted.submission),
        )
    }

    private data class DurableSubmission(
        val ledger: UnsentWindowLedger,
        val submission: UnsentWindowSubmission,
    )

}
