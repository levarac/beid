package org.levarac.beid.shared.report

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull

class UnsentWindowSubmissionSummaryTest {
    @Test fun openAndUnpersistedClosedWindowsAreExcluded() {
        val initial = assertNotNull(createUnsentWindowLedger("000102030405060708090a0b0c0d0e0f").ledger)
        val open = openUnsentWindow(initial, "one")
        assertEquals(UnsentWindowSubmissionSummary(), summarizeUnsentWindowSubmissions(open.ledger))
        val closed = closeUnsentWindow(open.ledger, "one", "one")
        assertEquals(UnsentWindowSubmissionSummary(), summarizeUnsentWindowSubmissions(closed.ledger))
        assertEquals(UnsentWindowSubmissionSummary(queued = 1), summarizeUnsentWindowSubmissions(durable(closed)))
    }

    @Test fun batchCountsObservationWindowsAndPreservesMixedQueuedAndAccepted() {
        var ledger = assertNotNull(createUnsentWindowLedger("000102030405060708090a0b0c0d0e0f").ledger)
        for (id in listOf("one", "two", "three")) {
            ledger = durable(closeUnsentWindow(openUnsentWindow(ledger, id).ledger, id, id))
        }
        val prepared = prepareNextUnsentWindowSubmission(ledger, 2, 0)
        val sending = confirmUnsentWindowLedgerPersistence(prepared.ledger, prepared.persistenceRevision)
        val key = assertNotNull(sending.submission).submissionKey
        assertEquals(UnsentWindowSubmissionSummary(queued = 1, sending = 2), summarizeUnsentWindowSubmissions(sending.ledger))
        val retry = markUnsentWindowSubmissionRetryable(sending.ledger, key, 30000)
        assertEquals(UnsentWindowSubmissionSummary(queued = 1, retrying = 2), summarizeUnsentWindowSubmissions(durable(retry)))
        val hold = markUnsentWindowSubmissionRetryable(sending.ledger, key, Long.MAX_VALUE)
        assertEquals(UnsentWindowSubmissionSummary(queued = 1, stopped = 2), summarizeUnsentWindowSubmissions(durable(hold)))
        val accepted = recordUnsentWindowSubmissionAcceptance(sending.ledger, key, "receipt")
        // A receipt that has not been persisted cannot be reported as received.
        assertEquals(0, summarizeUnsentWindowSubmissions(accepted.ledger).accepted)
        val restored = assertNotNull(decodeUnsentWindowLedgerSnapshot(assertNotNull(accepted.snapshotText)).ledger)
        assertEquals(UnsentWindowSubmissionSummary(queued = 1, accepted = 2), summarizeUnsentWindowSubmissions(restored))
    }

    private fun durable(transition: UnsentWindowLedgerTransition) =
        confirmUnsentWindowLedgerPersistence(transition.ledger, transition.persistenceRevision).ledger
}
