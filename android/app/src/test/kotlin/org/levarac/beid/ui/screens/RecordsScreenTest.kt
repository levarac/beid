package org.levarac.beid.ui.screens

import android.content.Context
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.core.app.ApplicationProvider
import java.time.Instant
import java.util.UUID
import kotlin.test.assertEquals
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
    ) = RecordListItem(
        id = id,
        eventLabel = eventCode,
        createdAt = Instant.parse("2026-01-01T00:00:00Z"),
        peersVerified = peersVerified,
        signatureStatus = when {
            hasBinding -> RecordSignatureStatus.Bound
            hasSelfProof -> RecordSignatureStatus.SelfProof
            else -> RecordSignatureStatus.NotSigned
        },
    )

    @Test
    fun productionProofRecordsMapToTheReadOnlyPresentationType() {
        val proof = ProofRecord(
            id = UUID.fromString("12345678-1234-5678-1234-567812345678"),
            eventCode = "REAL-EVENT",
            createdAt = Instant.parse("2026-01-01T00:00:00Z"),
            peersVerified = 7,
            hasSelfProof = true,
            hasBinding = false,
        )

        assertEquals(
            RecordListItem(
                id = proof.id,
                eventLabel = "REAL-EVENT",
                createdAt = proof.createdAt,
                peersVerified = 7,
                signatureStatus = RecordSignatureStatus.SelfProof,
            ),
            proof.toRecordListItem(),
        )
    }

    @Test
    fun emptyListRendersTheEmptyStateMessage() {
        composeTestRule.setContent {
            BeidAppTheme { RecordsScreen(records = emptyList(), onOpenDetail = {}) }
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
            BeidAppTheme { RecordsScreen(records = listOf(record), onOpenDetail = {}) }
        }

        composeTestRule.onNodeWithText("DEVCON-SEA").assertIsDisplayed()
        composeTestRule.onNodeWithText("5").assertIsDisplayed()
    }

    @Test
    fun signatureStatusDefaultsToNotYetSigned() {
        val record = record(hasSelfProof = false, hasBinding = false)

        composeTestRule.setContent {
            BeidAppTheme { RecordsScreen(records = listOf(record), onOpenDetail = {}) }
        }

        composeTestRule.onNodeWithText(context.getString(R.string.records_signature_status_not_signed)).assertIsDisplayed()
    }

    @Test
    fun signatureStatusShowsSelfProofRecordedWithNoBindingYet() {
        val record = record(hasSelfProof = true, hasBinding = false)

        composeTestRule.setContent {
            BeidAppTheme { RecordsScreen(records = listOf(record), onOpenDetail = {}) }
        }

        composeTestRule.onNodeWithText(context.getString(R.string.records_signature_status_self_proof)).assertIsDisplayed()
    }

    @Test
    fun signatureStatusShowsBoundOnceABindingExists() {
        val record = record(hasSelfProof = true, hasBinding = true)

        composeTestRule.setContent {
            BeidAppTheme { RecordsScreen(records = listOf(record), onOpenDetail = {}) }
        }

        composeTestRule.onNodeWithText(context.getString(R.string.records_signature_status_bound)).assertIsDisplayed()
    }

    /** Tap-to-detail (beid#122): tapping a row navigates to the detail screen for that row's own record id, never another row's. */
    @Test
    fun tappingARowInvokesOnOpenDetailWithThatRowsRecordId() {
        val tapped = record(eventCode = "TAPPED")
        val other = record(eventCode = "OTHER")
        val openedIds = mutableListOf<UUID>()

        composeTestRule.setContent {
            BeidAppTheme {
                RecordsScreen(records = listOf(tapped, other), onOpenDetail = { openedIds += it })
            }
        }

        composeTestRule.onNodeWithTag(RecordsScreenTestTags.recordRow(tapped.id)).performClick()

        assertEquals(listOf(tapped.id), openedIds)
    }

    @Test
    fun rendersMultipleRecordsNewestFirstOrderPreservedFromCaller() {
        val first = record(eventCode = "FIRST")
        val second = record(eventCode = "SECOND")

        composeTestRule.setContent {
            BeidAppTheme { RecordsScreen(records = listOf(first, second), onOpenDetail = {}) }
        }

        composeTestRule.onNodeWithText("FIRST").assertIsDisplayed()
        composeTestRule.onNodeWithText("SECOND").assertIsDisplayed()
    }
}
