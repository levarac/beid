package org.levarac.beid.shared.report

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/**
 * beid#607: a report whose automatic submission was stopped for good must
 * not occupy the ledger's head, or every window closed after it is never
 * selected again.
 */
class UnsentWindowLedgerStoppedReportTest {
    /**
     * The exact on-disk shape an Android build before #607 wrote for a held
     * report: RETRYABLE_FAILED with a deadline of Long.MAX_VALUE. Devices in
     * the field already carry this, so the fix must drain behind it without
     * rewriting or rejecting it.
     */
    @Test
    fun legacyHeldReportDoesNotBlockAWindowClosedAfterIt() {
        val decoded = decodeUnsentWindowLedgerSnapshot(LEGACY_HELD_SNAPSHOT)
        assertTrue(decoded.isSuccess, "precondition: the legacy fixture must decode (${decoded.errorCode})")
        val legacy = assertNotNull(decoded.ledger)

        val ready = closeDurably(legacy, "b")
        val prepared = prepareNextUnsentWindowSubmission(ready, maximumWindowCount = 1, nowEpochMilliseconds = NOW)
        assertTrue(prepared.isSuccess, "prepare failed: ${prepared.errorCode}")
        assertTrue(prepared.changed, "a window closed behind a held report must be selected into a new report")
        val emitted = confirmUnsentWindowLedgerPersistence(prepared.ledger, prepared.persistenceRevision)
        val submission = assertNotNull(emitted.submission, "the new report must be handed to the drain")
        assertEquals("b", submission.windowIdAt(0))

        val restored = decodeUnsentWindowLedgerSnapshot(assertNotNull(prepared.snapshotText))
        assertTrue(restored.isSuccess, "a held report plus a live report must survive a relaunch (${restored.errorCode})")
        assertEquals(null, retryNotBeforeEpochMilliseconds(emitted.ledger), "the held report must not be reported as the head's retry deadline")
    }

    @Test
    fun aDeadlineThatNeverArrivesIsNotARetry() {
        val durable = inFlight("a")
        val result = markUnsentWindowSubmissionRetryable(durable.ledger, durable.submission.submissionKey, Long.MAX_VALUE)
        assertFalse(result.isSuccess, "Long.MAX_VALUE must be refused; a stop is stated with the terminal transition")
        assertEquals("invalid_retry_not_before", result.errorCode)
    }

    private data class InFlight(val ledger: UnsentWindowLedger, val submission: UnsentWindowSubmission)

    private fun inFlight(windowId: String): InFlight {
        val ready = closeDurably(assertNotNull(createUnsentWindowLedger(LEDGER_ID).ledger), windowId)
        val prepared = prepareNextUnsentWindowSubmission(ready, maximumWindowCount = 1, nowEpochMilliseconds = NOW)
        val emitted = confirmUnsentWindowLedgerPersistence(prepared.ledger, prepared.persistenceRevision)
        return InFlight(emitted.ledger, assertNotNull(emitted.submission))
    }

    private fun closeDurably(ledger: UnsentWindowLedger, windowId: String): UnsentWindowLedger {
        val opened = openUnsentWindow(ledger, windowId)
        val openedLedger = confirmUnsentWindowLedgerPersistence(opened.ledger, opened.persistenceRevision).ledger
        val closed = closeUnsentWindow(openedLedger, windowId, windowId)
        assertTrue(closed.isSuccess, "close failed: ${closed.errorCode}")
        return confirmUnsentWindowLedgerPersistence(closed.ledger, closed.persistenceRevision).ledger
    }

    private companion object {
        const val LEDGER_ID = "000102030405060708090a0b0c0d0e0f"
        const val NOW = 1_800_000_000_000L

        /** open a (r1), close a (r2), select a (r3), hold with Long.MAX_VALUE (r4). */
        val LEGACY_HELD_SNAPSHOT = """
            beid-ledger-snapshot\t1
            revision\t4
            ledger-id\t000102030405060708090a0b0c0d0e0f
            next-window-sequence\t2
            next-report-sequence\t2
            windows\t1
            window\t61\t1\t2\t61
            reports\t1
            report\t000102030405060708090a0b0c0d0e0f0000000000000001\t4\t1\tretryable_failed\t9223372036854775807\t-\t61
            end
        """.trimIndent().replace("\\t", "\t") + "\n"
    }
}
