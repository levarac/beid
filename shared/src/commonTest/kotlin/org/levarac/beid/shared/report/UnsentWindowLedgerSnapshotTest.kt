package org.levarac.beid.shared.report

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class UnsentWindowLedgerSnapshotTest {
    @Test
    fun rejectsAReportWhoseWindowMembershipIsNotInCanonicalCloseOrder() {
        var ledger = assertNotNull(
            createUnsentWindowLedger(
                ledgerInstanceIdHex = "000102030405060708090a0b0c0d0e0f",
            ).ledger,
        )
        ledger = openUnsentWindow(ledger, "window-a").ledger
        ledger = closeUnsentWindow(ledger, "window-a", "window-a").ledger
        ledger = openUnsentWindow(ledger, "window-b").ledger
        val closedB = closeUnsentWindow(ledger, "window-b", "window-b")
        ledger = confirmUnsentWindowLedgerPersistence(
            ledger = closedB.ledger,
            revision = closedB.persistenceRevision,
        ).ledger
        val prepared = prepareNextUnsentWindowSubmission(ledger, 10, 0L)
        val persisted = confirmUnsentWindowLedgerPersistence(
            ledger = prepared.ledger,
            revision = prepared.persistenceRevision,
        )
        val canonical = encodeUnsentWindowLedgerSnapshot(persisted.ledger)
        assertTrue(decodeUnsentWindowLedgerSnapshot(canonical).isSuccess)

        val reordered = canonical.replace(
            oldValue = "77696e646f772d61,77696e646f772d62",
            newValue = "77696e646f772d62,77696e646f772d61",
        )
        val decoded = decodeUnsentWindowLedgerSnapshot(reordered)
        assertFalse(decoded.isSuccess)
        assertNull(decoded.ledger)
        assertNotNull(decoded.errorCode)
    }

    @Test
    fun everyChangedTransitionCarriesAnExactRestorableSnapshotAndRejectsOversizedFields() {
        val ledger = assertNotNull(
            createUnsentWindowLedger(
                ledgerInstanceIdHex = "000102030405060708090a0b0c0d0e0f",
            ).ledger,
        )

        val oversizedWindow = openUnsentWindow(
            ledger = ledger,
            windowId = "w".repeat(4_097),
        )
        assertFalse(oversizedWindow.isSuccess)
        assertFalse(oversizedWindow.changed)
        assertEquals("invalid_window_id", oversizedWindow.errorCode)
        assertNull(oversizedWindow.snapshotText)

        val opened = openUnsentWindow(
            ledger = ledger,
            windowId = "w".repeat(4_096),
        )
        assertTrue(opened.isSuccess)
        val openedSnapshot = assertNotNull(opened.snapshotText)
        assertEquals(opened.persistenceRevision, 1L)
        assertTrue(decodeUnsentWindowLedgerSnapshot(openedSnapshot).isSuccess)
        assertEquals(openedSnapshot, encodeUnsentWindowLedgerSnapshot(opened.ledger))

        val oversizedObservation = closeUnsentWindow(
            ledger = opened.ledger,
            windowId = "w".repeat(4_096),
            persistedObservationReference = "o".repeat(4_097),
        )
        assertFalse(oversizedObservation.isSuccess)
        assertEquals("invalid_observation_reference", oversizedObservation.errorCode)
        assertNull(oversizedObservation.snapshotText)

        val closed = closeUnsentWindow(
            ledger = opened.ledger,
            windowId = "w".repeat(4_096),
            persistedObservationReference = "o".repeat(4_096),
        )
        val closedSnapshot = assertNotNull(closed.snapshotText)
        assertTrue(decodeUnsentWindowLedgerSnapshot(closedSnapshot).isSuccess)
        assertEquals(closedSnapshot, encodeUnsentWindowLedgerSnapshot(closed.ledger))
    }

    @Test
    fun exhaustedCountersAndMalformedUnicodeFailWithoutProducingAnInvalidSnapshot() {
        val instanceId = "000102030405060708090a0b0c0d0e0f"
        val exhaustedRevision = UnsentWindowLedger(
            LedgerState(
                ledgerInstanceIdHex = instanceId,
                revision = Long.MAX_VALUE,
                durableRevision = Long.MAX_VALUE,
            ),
        )
        assertTrue(
            decodeUnsentWindowLedgerSnapshot(
                encodeUnsentWindowLedgerSnapshot(exhaustedRevision),
            ).isSuccess,
        )
        val revisionOverflow = openUnsentWindow(exhaustedRevision, "window-1")
        assertFalse(revisionOverflow.isSuccess)
        assertFalse(revisionOverflow.changed)
        assertEquals("ledger_capacity_exceeded", revisionOverflow.errorCode)
        assertNull(revisionOverflow.snapshotText)

        val exhaustedWindowSequence = UnsentWindowLedger(
            LedgerState(
                ledgerInstanceIdHex = instanceId,
                nextWindowSequence = Long.MAX_VALUE,
            ),
        )
        val windowSequenceOverflow = openUnsentWindow(exhaustedWindowSequence, "window-1")
        assertFalse(windowSequenceOverflow.isSuccess)
        assertEquals("ledger_capacity_exceeded", windowSequenceOverflow.errorCode)

        val closedWindow = LedgerWindow(
            windowId = "window-1",
            openedSequence = 1L,
            closedRevision = 1L,
            observationReference = "observation-1",
        )
        val exhaustedReportSequence = UnsentWindowLedger(
            LedgerState(
                ledgerInstanceIdHex = instanceId,
                revision = 1L,
                durableRevision = 1L,
                nextWindowSequence = 2L,
                nextReportSequence = Long.MAX_VALUE,
                windows = listOf(closedWindow),
            ),
        )
        val reportSequenceOverflow = prepareNextUnsentWindowSubmission(
            exhaustedReportSequence,
            1,
            0L,
        )
        assertFalse(reportSequenceOverflow.isSuccess)
        assertEquals("ledger_capacity_exceeded", reportSequenceOverflow.errorCode)

        val submissionKey = instanceId + "0000000000000001"
        val exhaustedAttempt = UnsentWindowLedger(
            LedgerState(
                ledgerInstanceIdHex = instanceId,
                revision = 1L,
                durableRevision = 1L,
                nextWindowSequence = 2L,
                nextReportSequence = 2L,
                windows = listOf(closedWindow.copy(reportKey = submissionKey)),
                reports = listOf(
                    LedgerReport(
                        submissionKey = submissionKey,
                        updatedRevision = 1L,
                        attempt = Int.MAX_VALUE,
                        windowIds = listOf("window-1"),
                        status = LedgerReportStatus.RETRYABLE_FAILED,
                        retryNotBeforeEpochMilliseconds = 0L,
                    ),
                ),
            ),
        )
        val attemptOverflow = prepareNextUnsentWindowSubmission(exhaustedAttempt, 1, 0L)
        assertFalse(attemptOverflow.isSuccess)
        assertEquals("ledger_capacity_exceeded", attemptOverflow.errorCode)

        val malformedUnicode = charArrayOf(0xd800.toChar()).concatToString()
        val empty = assertNotNull(createUnsentWindowLedger(instanceId).ledger)
        val malformedWindow = openUnsentWindow(empty, malformedUnicode)
        assertFalse(malformedWindow.isSuccess)
        assertEquals("invalid_window_id", malformedWindow.errorCode)

        val opened = openUnsentWindow(empty, "window-1")
        val malformedObservation = closeUnsentWindow(
            opened.ledger,
            "window-1",
            malformedUnicode,
        )
        assertFalse(malformedObservation.isSuccess)
        assertEquals("invalid_observation_reference", malformedObservation.errorCode)
    }

    @Test
    fun bulkRelaunchRecoveryRejectsAnOversizedSnapshotBeforeEncodingIt() {
        val windows = (1L..1_100L).map { sequence ->
            LedgerWindow(
                windowId = "window-$sequence",
                openedSequence = sequence,
            )
        }
        val ledger = UnsentWindowLedger(
            LedgerState(
                ledgerInstanceIdHex = "000102030405060708090a0b0c0d0e0f",
                revision = 1_100L,
                durableRevision = 1_100L,
                nextWindowSequence = 1_101L,
                windows = windows,
            ),
        )
        assertTrue(
            encodeUnsentWindowLedgerSnapshot(ledger).encodeToByteArray().size <
                MAX_LEDGER_SNAPSHOT_BYTES,
        )

        val maximumReference = "r".repeat(MAX_LEDGER_TEXT_FIELD_BYTES)
        val recoveryInput = createUnsentWindowObservationRecoveryInput()
        windows.forEach { window ->
            assertTrue(
                addPersistedUnsentWindowObservationForRecovery(
                    recoveryInput = recoveryInput,
                    windowId = window.windowId,
                    persistedObservationReference = maximumReference,
                ),
            )
        }

        val recovered = reconcileUnsentWindowLedgerAfterRelaunch(
            ledger = ledger,
            recoveryInput = recoveryInput,
        )
        assertFalse(recovered.isSuccess)
        assertFalse(recovered.changed)
        assertEquals("ledger_capacity_exceeded", recovered.errorCode)
        assertNull(recovered.snapshotText)
    }

    @Test
    fun corruptOrNoncanonicalSnapshotsAreRejectedInsteadOfBecomingEmptyLedgers() {
        val canonical = canonicalInFlightSnapshot()
        val corruptions = mapOf(
            "empty" to "",
            "unknown version" to canonical.replaceFirst(
                "beid-ledger-snapshot\t1",
                "beid-ledger-snapshot\t2",
            ),
            "CRLF" to canonical.replace("\n", "\r\n"),
            "missing final LF" to canonical.dropLast(1),
            "noncanonical revision" to canonical.replaceFirst("revision\t3", "revision\t03"),
            "uppercase hex" to canonical.replaceFirst("77696e646f772d31", "77696E646f772d31"),
            "closed window without observation" to canonical.replaceFirst(
                "\t1\t2\t77696e646f772d31\n",
                "\t1\t2\t-\n",
            ),
            "dangling membership" to canonical.replaceFirst(
                "\t-\t-\t77696e646f772d31\n",
                "\t-\t-\t6d697373696e67\n",
            ),
            "data after end" to canonical + "trailing\n",
            "truncated record" to canonical.dropLast(12),
        )

        corruptions.forEach { (name, corrupted) ->
            val decoded = decodeUnsentWindowLedgerSnapshot(corrupted)
            assertFalse(decoded.isSuccess, name)
            assertNull(decoded.ledger, name)
            assertNotNull(decoded.errorCode, name)
        }
    }

    private fun canonicalInFlightSnapshot(): String {
        var ledger = assertNotNull(
            createUnsentWindowLedger(
                ledgerInstanceIdHex = "000102030405060708090a0b0c0d0e0f",
            ).ledger,
        )
        ledger = openUnsentWindow(ledger, "window-1").ledger
        val closed = closeUnsentWindow(ledger, "window-1", "window-1")
        ledger = confirmUnsentWindowLedgerPersistence(
            ledger = closed.ledger,
            revision = closed.persistenceRevision,
        ).ledger
        val prepared = prepareNextUnsentWindowSubmission(ledger, 10, 0L)
        return assertNotNull(prepared.snapshotText)
    }
}
