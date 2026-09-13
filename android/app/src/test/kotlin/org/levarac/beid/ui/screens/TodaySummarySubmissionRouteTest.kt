package org.levarac.beid.ui.screens

import android.content.Context
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onAllNodesWithText
import androidx.test.core.app.ApplicationProvider
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.levarac.beid.persistence.ProofRecordStore
import org.levarac.beid.persistence.UnsentWindowLedgerStore
import org.levarac.beid.shared.report.*
import org.levarac.beid.ui.theme.BeidAppTheme
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class TodaySummarySubmissionRouteTest {
    @get:Rule val compose = createComposeRule()
    private val context: Context get() = ApplicationProvider.getApplicationContext()
    private val file get() = UnsentWindowLedgerStore.defaultFile(context.filesDir)

    @Before fun resetLedger() {
        file.delete()
        context.filesDir.resolve("route-test-proofs.json").delete()
    }

    @Test fun acceptedDurableReportIsShownAsReceived() {
        persistReport("accepted")
        showRoute()
        awaitText("Received by the operator: 1")
        compose.onNodeWithText("Sending isn't turned on for this build.").assertDoesNotExist()
        compose.onNodeWithText("Not sent yet.").assertDoesNotExist()
    }

    @Test fun retryableDurableReportIsShownAsWaiting() {
        persistReport("retry")
        showRoute()
        awaitText("Waiting to retry: 1")
    }

    @Test fun heldDurableReportIsShownAsStopped() {
        persistReport("held")
        showRoute()
        awaitText("Sending stopped: 1")
    }

    @Test fun visibleRouteObservesAcceptanceWrittenByAnotherStoreInstance() {
        persistReport("retry")
        showRoute()
        awaitText("Waiting to retry: 1")
        val writer = UnsentWindowLedgerStore(file)
        val ledger = requireNotNull(writer.load()?.ledger)
        val accepted = recordUnsentWindowSubmissionAcceptance(
            ledger, "000102030405060708090a0b0c0d0e0f0000000000000001", "receipt-after-retry",
        )
        check(accepted.isSuccess)
        writer.persist(accepted)
        awaitText("Received by the operator: 1")
        compose.onNodeWithText("Waiting to retry: 1").assertDoesNotExist()
    }

    @Test fun missingLedgerDoesNotInferPendingFromProofs() {
        ProofRecordStore(context.filesDir.resolve("route-test-proofs.json")).add(
            org.levarac.beid.persistence.ProofRecord(
                id = java.util.UUID.randomUUID(), eventCode = "EVENT",
                createdAt = java.time.Instant.now(), peersVerified = 0,
            ),
        )
        showRoute()
        awaitText("No reports waiting to be sent.")
    }

    @Test fun corruptLedgerShowsUnavailableInsteadOfEmptyOrAccepted() {
        file.writeText("corrupt")
        kotlin.test.assertNull(readTodaySubmissionStatus(context.filesDir))
        kotlin.test.assertEquals("corrupt", file.readText())
        showRoute()
        compose.onNodeWithText("Sending status is unavailable.").assertIsDisplayed()
    }

    private fun awaitText(text: String) {
        compose.waitUntil(5_000) { compose.onAllNodesWithText(text).fetchSemanticsNodes().isNotEmpty() }
        compose.onNodeWithText(text).assertIsDisplayed()
    }

    private fun showRoute() {
        val proofs = ProofRecordStore(context.filesDir.resolve("route-test-proofs.json"))
        compose.setContent { BeidAppTheme { TodaySummaryRoute(proofs) } }
    }

    private fun persistReport(state: String) {
        val store = UnsentWindowLedgerStore(file)
        var ledger = requireNotNull(createUnsentWindowLedger("000102030405060708090a0b0c0d0e0f").ledger)
        val closed = closeUnsentWindow(openUnsentWindow(ledger, "window-1").ledger, "window-1", "observation-1")
        ledger = confirmUnsentWindowLedgerPersistence(closed.ledger, store.persist(closed)).ledger
        val prepared = prepareNextUnsentWindowSubmission(ledger, 1, 0)
        val confirmed = confirmUnsentWindowLedgerPersistence(prepared.ledger, store.persist(prepared))
        val key = requireNotNull(confirmed.submission).submissionKey
        val result = when (state) {
            "accepted" -> recordUnsentWindowSubmissionAcceptance(confirmed.ledger, key, "receipt-1")
            "held" -> markUnsentWindowSubmissionRetryable(confirmed.ledger, key, Long.MAX_VALUE)
            else -> markUnsentWindowSubmissionRetryable(confirmed.ledger, key, 30000)
        }
        check(result.isSuccess)
        store.persist(result)
    }
}
