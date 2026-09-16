package org.levarac.beid.ui.screens

import android.content.Context
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.core.app.ApplicationProvider
import kotlin.test.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.levarac.beid.R
import org.levarac.beid.shared.clock.ClockPreflightState
import org.levarac.beid.ui.theme.BeidAppTheme
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * beid#464 acceptance: the Join event screen tells the participant, in plain
 * words, when the device clock is off or cannot be checked — through the same
 * [EventJoinContent] renderer production uses.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class ClockPreflightNoticeTest {
    @get:Rule
    val composeTestRule = createComposeRule()

    private val context: Context get() = ApplicationProvider.getApplicationContext()

    private fun render(clockPreflight: ClockPreflightState?, onRetry: () -> Unit = {}) {
        composeTestRule.setContent {
            BeidAppTheme {
                EventJoinContent(
                    state = EventJoinScreenState(clockPreflight = clockPreflight),
                    onOpenAccount = {},
                    onJoinNearbyEvent = {},
                    onOpenSettings = {},
                    onSimulateSignalLost = {},
                    onResumeSensing = {},
                    onRetryClockPreflight = onRetry,
                )
            }
        }
    }

    @Test
    fun undeterminableRendersItsExplanationAndARetry() {
        var retries = 0
        render(ClockPreflightState.UNDETERMINABLE) { retries += 1 }
        composeTestRule.onNodeWithText(context.getString(R.string.clock_preflight_undeterminable_title)).assertIsDisplayed()
        composeTestRule.onNodeWithText(context.getString(R.string.clock_preflight_undeterminable_body)).assertIsDisplayed()
        composeTestRule.onNodeWithTag(EventJoinScreenTestTags.CLOCK_PREFLIGHT_RETRY).assertIsDisplayed().performClick()
        assertEquals(1, retries)
    }

    @Test
    fun overToleranceRendersItsExplanation() {
        render(ClockPreflightState.OVER_TOLERANCE)
        composeTestRule.onNodeWithText(context.getString(R.string.clock_preflight_over_title)).assertIsDisplayed()
        composeTestRule.onNodeWithText(context.getString(R.string.clock_preflight_over_body)).assertIsDisplayed()
        composeTestRule.onNodeWithTag(EventJoinScreenTestTags.CLOCK_PREFLIGHT_RETRY).assertIsDisplayed()
    }

    @Test
    fun withinToleranceShowsNoNotice() {
        render(ClockPreflightState.WITHIN_TOLERANCE)
        composeTestRule.onNodeWithTag(EventJoinScreenTestTags.CLOCK_PREFLIGHT_NOTICE).assertDoesNotExist()
    }

    @Test
    fun anUncheckedClockShowsNoNoticeYet() {
        render(null)
        composeTestRule.onNodeWithTag(EventJoinScreenTestTags.CLOCK_PREFLIGHT_NOTICE).assertDoesNotExist()
    }
}
