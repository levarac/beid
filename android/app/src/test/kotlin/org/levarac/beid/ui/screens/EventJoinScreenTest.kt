package org.levarac.beid.ui.screens

import android.content.Context
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.core.app.ApplicationProvider
import kotlin.test.assertNull
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.levarac.beid.R
import org.levarac.beid.ui.theme.BeidAppTheme
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * Robolectric-backed Compose test — see android/README.md "Testing" for why
 * this runs as a JVM `:app:testDebugUnitTest` test instead of an
 * instrumented `androidTest`.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class EventJoinScreenTest {
    @get:Rule
    val composeTestRule = createComposeRule()

    @Test
    fun submittingAnEmptyEventCodeShowsTheInlineErrorAndDoesNotJoin() {
        val session = FakeEventJoinSession()
        val viewModel = EventJoinViewModel(session)

        composeTestRule.setContent {
            BeidAppTheme {
                EventJoinScreen(viewModel)
            }
        }

        composeTestRule.onNodeWithTag(EventJoinScreenTestTags.SUBMIT_BUTTON).performClick()

        val context = ApplicationProvider.getApplicationContext<Context>()
        val expectedError = context.getString(R.string.event_join_error_empty_code)
        composeTestRule.onNodeWithTag(EventJoinScreenTestTags.FIELD_ERROR).assertIsDisplayed()
        composeTestRule.onNodeWithText(expectedError).assertIsDisplayed()
        assertNull(session.joinedCode)
    }
}
