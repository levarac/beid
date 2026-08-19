package org.levarac.beid.persistence

import java.nio.file.Files
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertNotNull
import kotlin.test.assertTrue
import org.levarac.beid.shared.report.closeUnsentWindow
import org.levarac.beid.shared.report.confirmUnsentWindowLedgerPersistence
import org.levarac.beid.shared.report.createUnsentWindowLedger
import org.levarac.beid.shared.report.encodeUnsentWindowLedgerSnapshot
import org.levarac.beid.shared.report.markUnsentWindowSubmissionRetryable
import org.levarac.beid.shared.report.openUnsentWindow
import org.levarac.beid.shared.report.prepareNextUnsentWindowSubmission
import org.levarac.beid.shared.report.recordUnsentWindowSubmissionAcceptance
import org.levarac.beid.shared.report.recordUnsentWindowSubmissionInclusion

/**
 * Reproduces the exact reducer call sequences (same ledger id, window ids,
 * and call order) that back
 * `UnsentWindowLedgerSnapshotTest.retryableFailureSnapshotHasStableBytesAndPreservesMultiWindowMembership`
 * and `.acknowledgedInclusionSnapshotHasStableBytes` in
 * `shared/src/commonTest/kotlin/org/levarac/beid/shared/report/UnsentWindowLedgerSnapshotTest.kt`,
 * then asserts the Android store writes and restores the same literal
 * `expected` bytes as those shared golden vectors. The literal strings below
 * are copied verbatim from that shared test, not retyped.
 */
class UnsentWindowLedgerStoreGoldenVectorTest {
    @Test
    fun retryableFailureSnapshotMatchesSharedGoldenVectorBytesOnDisk() {
        val directory = Files.createTempDirectory("beid-ledger-golden-retryable").toFile()
        try {
            val file = directory.resolve("ledger.snapshot")
            val store = UnsentWindowLedgerStore(file)

            var ledger = assertNotNull(
                createUnsentWindowLedger(
                    ledgerInstanceIdHex = "000102030405060708090a0b0c0d0e0f",
                ).ledger,
            )

            val openedA = openUnsentWindow(ledger, "window-a")
            ledger = confirmUnsentWindowLedgerPersistence(
                openedA.ledger,
                openedA.persistenceRevision,
            ).ledger
            val closedA = closeUnsentWindow(ledger, "window-a", "window-a")
            ledger = confirmUnsentWindowLedgerPersistence(
                closedA.ledger,
                closedA.persistenceRevision,
            ).ledger

            val openedB = openUnsentWindow(ledger, "window-b")
            ledger = confirmUnsentWindowLedgerPersistence(
                openedB.ledger,
                openedB.persistenceRevision,
            ).ledger
            val closedB = closeUnsentWindow(ledger, "window-b", "window-b")
            ledger = confirmUnsentWindowLedgerPersistence(
                closedB.ledger,
                closedB.persistenceRevision,
            ).ledger

            val prepared = prepareNextUnsentWindowSubmission(ledger, 10, 0L)
            val preparedPersisted = confirmUnsentWindowLedgerPersistence(
                prepared.ledger,
                prepared.persistenceRevision,
            )
            val submission = assertNotNull(preparedPersisted.submission)
            val failed = markUnsentWindowSubmissionRetryable(
                ledger = preparedPersisted.ledger,
                submissionKey = submission.submissionKey,
                retryNotBeforeEpochMilliseconds = 1_234L,
            )

            store.persist(failed)

            val expected = """
                beid-ledger-snapshot\t1
                revision\t6
                ledger-id\t000102030405060708090a0b0c0d0e0f
                next-window-sequence\t3
                next-report-sequence\t2
                windows\t2
                window\t77696e646f772d61\t1\t2\t77696e646f772d61
                window\t77696e646f772d62\t2\t4\t77696e646f772d62
                reports\t1
                report\t000102030405060708090a0b0c0d0e0f0000000000000001\t6\t1\tretryable_failed\t1234\t-\t77696e646f772d61,77696e646f772d62
                end
            """.trimIndent().replace("\\t", "\t") + "\n"

            assertContentEquals(expected.encodeToByteArray(), file.readBytes())

            val reloaded = assertNotNull(UnsentWindowLedgerStore(file).load())
            assertTrue(reloaded.isSuccess)
            assertContentEquals(
                expected.encodeToByteArray(),
                encodeUnsentWindowLedgerSnapshot(assertNotNull(reloaded.ledger)).encodeToByteArray(),
            )
        } finally {
            directory.deleteRecursively()
        }
    }

    @Test
    fun acknowledgedInclusionSnapshotMatchesSharedGoldenVectorBytesOnDisk() {
        val directory = Files.createTempDirectory("beid-ledger-golden-acknowledged").toFile()
        try {
            val file = directory.resolve("ledger.snapshot")
            val store = UnsentWindowLedgerStore(file)

            var ledger = assertNotNull(
                createUnsentWindowLedger(
                    ledgerInstanceIdHex = "000102030405060708090a0b0c0d0e0f",
                ).ledger,
            )

            val opened = openUnsentWindow(ledger, "window-1")
            ledger = confirmUnsentWindowLedgerPersistence(
                opened.ledger,
                opened.persistenceRevision,
            ).ledger
            val closed = closeUnsentWindow(ledger, "window-1", "window-1")
            ledger = confirmUnsentWindowLedgerPersistence(
                closed.ledger,
                closed.persistenceRevision,
            ).ledger

            val prepared = prepareNextUnsentWindowSubmission(ledger, 10, 0L)
            val preparedPersisted = confirmUnsentWindowLedgerPersistence(
                prepared.ledger,
                prepared.persistenceRevision,
            )
            val submission = assertNotNull(preparedPersisted.submission)
            val accepted = recordUnsentWindowSubmissionAcceptance(
                ledger = preparedPersisted.ledger,
                submissionKey = submission.submissionKey,
                persistedAcceptanceReceiptReference = "acceptance-1",
            )
            ledger = confirmUnsentWindowLedgerPersistence(
                accepted.ledger,
                accepted.persistenceRevision,
            ).ledger
            val included = recordUnsentWindowSubmissionInclusion(
                ledger = ledger,
                submissionKey = submission.submissionKey,
                persistedInclusionReceiptReference = "inclusion-1",
            )

            store.persist(included)

            val expected = """
                beid-ledger-snapshot\t1
                revision\t5
                ledger-id\t000102030405060708090a0b0c0d0e0f
                next-window-sequence\t2
                next-report-sequence\t2
                windows\t1
                window\t77696e646f772d31\t1\t2\t77696e646f772d31
                reports\t1
                report\t000102030405060708090a0b0c0d0e0f0000000000000001\t5\t1\tacknowledged\t616363657074616e63652d31\t696e636c7573696f6e2d31\t77696e646f772d31
                end
            """.trimIndent().replace("\\t", "\t") + "\n"

            assertContentEquals(expected.encodeToByteArray(), file.readBytes())

            val reloaded = assertNotNull(UnsentWindowLedgerStore(file).load())
            assertTrue(reloaded.isSuccess)
            assertContentEquals(
                expected.encodeToByteArray(),
                encodeUnsentWindowLedgerSnapshot(assertNotNull(reloaded.ledger)).encodeToByteArray(),
            )
        } finally {
            directory.deleteRecursively()
        }
    }
}
