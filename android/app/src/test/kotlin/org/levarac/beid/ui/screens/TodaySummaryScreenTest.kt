package org.levarac.beid.ui.screens

import android.content.Context
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.test.core.app.ApplicationProvider
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.levarac.beid.R
import org.levarac.beid.ui.theme.BeidAppTheme
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class TodaySummaryScreenTest {
    @get:Rule
    val composeTestRule = createComposeRule()

    private val context: Context get() = ApplicationProvider.getApplicationContext()

    @Test
    fun nonzeroRecordCountDoesNotRenderAnUngroundedSubmissionStage() {
        composeTestRule.setContent {
            BeidAppTheme { TodaySummaryScreen(recordCount = 2) }
        }

        composeTestRule.onNodeWithText(
            context.resources.getQuantityString(R.plurals.today_summary_record_count, 2, 2),
        ).assertIsDisplayed()
        composeTestRule.onNodeWithText(context.getString(R.string.today_summary_submission_unavailable)).assertIsDisplayed()
        composeTestRule.onNodeWithText("Sending isn't turned on for this build.").assertDoesNotExist()
        composeTestRule.onNodeWithText("Not sent yet.").assertDoesNotExist()
    }

    @Test
    fun zeroRecordDayRendersExplicitEmptyState() {
        composeTestRule.setContent {
            BeidAppTheme { TodaySummaryScreen(recordCount = 0) }
        }

        composeTestRule.onNodeWithText(context.getString(R.string.today_summary_empty_title)).assertIsDisplayed()
        composeTestRule.onNodeWithText(context.getString(R.string.today_summary_empty_message)).assertIsDisplayed()
        composeTestRule.onNodeWithTag(TodaySummaryScreenTestTags.EMPTY_STATE).assertIsDisplayed()
    }

    @Test
    fun neverRendersUngroundedAcceptedVerifiedOrPublicScopeRows() {
        composeTestRule.setContent {
            BeidAppTheme { TodaySummaryScreen(recordCount = 2) }
        }

        composeTestRule.onNodeWithText("Accepted").assertDoesNotExist()
        composeTestRule.onNodeWithText("Verified").assertDoesNotExist()
        composeTestRule.onNodeWithText("Public").assertDoesNotExist()
    }
}
