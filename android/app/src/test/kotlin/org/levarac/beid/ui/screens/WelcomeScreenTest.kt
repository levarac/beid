package org.levarac.beid.ui.screens

import android.content.Context
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.core.app.ApplicationProvider
import kotlin.test.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.levarac.beid.R
import org.levarac.beid.ui.theme.BeidAppTheme
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class WelcomeScreenTest {
    @get:Rule
    val composeTestRule = createComposeRule()

    @Test
    fun rendersTitleSubtitleAndInvokesCallbackOnGetStarted() {
        var getStartedTapped = false

        composeTestRule.setContent {
            BeidAppTheme {
                WelcomeScreen(onGetStarted = { getStartedTapped = true })
            }
        }

        val context = ApplicationProvider.getApplicationContext<Context>()
        composeTestRule.onNodeWithText(context.getString(R.string.welcome_title)).assertIsDisplayed()
        composeTestRule.onNodeWithText(context.getString(R.string.welcome_subtitle)).assertIsDisplayed()

        composeTestRule.onNodeWithTag(WelcomeScreenTestTags.GET_STARTED_BUTTON).performClick()
        assertTrue(getStartedTapped)
    }
}
