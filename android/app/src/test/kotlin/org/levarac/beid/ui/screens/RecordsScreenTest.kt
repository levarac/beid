package org.levarac.beid.ui.screens

import android.content.Context
import androidx.compose.ui.test.assertHasNoClickAction
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.core.app.ApplicationProvider
import java.time.Instant
import java.util.UUID
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.levarac.beid.R
import org.levarac.beid.persistence.ProofRecord
import org.levarac.beid.ui.theme.BeidAppTheme
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * Robolectric-backed Compose test — same shape as [AccountScreenTest], see
 * android/README.md "Testing" for why this runs as a JVM
 * `:app:testDebugUnitTest` test instead of an instrumented `androidTest`.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class RecordsScreenTest {
    @get:Rule
    val composeTestRule = createComposeRule()

    private val context: Context get() = ApplicationProvider.getApplicationContext()

    private fun record(
        id: UUID = UUID.randomUUID(),
        eventCode: String = "ETHTOKYO2026",
        peersVerified: Int = 3,
        hasSelfProof: Boolean = false,
        hasBinding: Boolean = false,
    ) = ProofRecord(
        id = id,
        eventCode = eventCode,
        createdAt = Instant.parse("2026-01-01T00:00:00Z"),
        peersVerified = peersVerified,
        hasSelfProof = hasSelfProof,
        hasBinding = hasBinding,
    )

    @Test
    fun emptyListRendersTheEmptyStateMessage() {
        composeTestRule.setContent {
            BeidAppTheme { RecordsScreen(records = emptyList()) }
        }

        composeTestRule.onNodeWithText(context.getString(R.string.records_empty_message)).assertIsDisplayed()
    }

    @Test
    fun todayEntryOpensTheSeparateDailySummarySurface() {
        var openTodayCallCount = 0
        composeTestRule.setContent {
            BeidAppTheme {
                RecordsScreen(records = emptyList(), onOpenToday = { openTodayCallCount++ })
            }
        }

        composeTestRule.onNodeWithTag(RecordsScreenTestTags.TODAY_BUTTON).performClick()

        kotlin.test.assertEquals(1, openTodayCallCount)
    }

    @Test
    fun aRecordRendersItsEventCodeAndPeersVerified() {
        val record = record(eventCode = "DEVCON-SEA", peersVerified = 5)

        composeTestRule.setContent {
            BeidAppTheme { RecordsScreen(records = listOf(record)) }
        }

        composeTestRule.onNodeWithText("DEVCON-SEA").assertIsDisplayed()
        composeTestRule.onNodeWithText("5").assertIsDisplayed()
    }

    @Test
    fun signatureStatusDefaultsToNotYetSigned() {
        val record = record(hasSelfProof = false, hasBinding = false)

        composeTestRule.setContent {
            BeidAppTheme { RecordsScreen(records = listOf(record)) }
        }

        composeTestRule.onNodeWithText(context.getString(R.string.records_signature_status_not_signed)).assertIsDisplayed()
    }

    @Test
    fun signatureStatusShowsSelfProofRecordedWithNoBindingYet() {
        val record = record(hasSelfProof = true, hasBinding = false)

        composeTestRule.setContent {
            BeidAppTheme { RecordsScreen(records = listOf(record)) }
        }

        composeTestRule.onNodeWithText(context.getString(R.string.records_signature_status_self_proof)).assertIsDisplayed()
    }

    @Test
    fun signatureStatusShowsBoundOnceABindingExists() {
        val record = record(hasSelfProof = true, hasBinding = true)

        composeTestRule.setContent {
            BeidAppTheme { RecordsScreen(records = listOf(record)) }
        }

        composeTestRule.onNodeWithText(context.getString(R.string.records_signature_status_bound)).assertIsDisplayed()
    }

    /** No tap-to-detail on this slice (beid#122 is a separate, not-yet-built issue) — rows are inert. */
    @Test
    fun rowsHaveNoClickAction() {
        val record = record()

        composeTestRule.setContent {
            BeidAppTheme { RecordsScreen(records = listOf(record)) }
        }

        composeTestRule.onNodeWithTag(RecordsScreenTestTags.recordRow(record.id)).assertHasNoClickAction()
    }

    @Test
    fun rendersMultipleRecordsNewestFirstOrderPreservedFromCaller() {
        val first = record(eventCode = "FIRST")
        val second = record(eventCode = "SECOND")

        composeTestRule.setContent {
            BeidAppTheme { RecordsScreen(records = listOf(first, second)) }
        }

        composeTestRule.onNodeWithText("FIRST").assertIsDisplayed()
        composeTestRule.onNodeWithText("SECOND").assertIsDisplayed()
    }
}
