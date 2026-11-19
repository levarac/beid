package org.levarac.beid.ui.designsystem

import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performTextInput
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
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
class BeidTextFieldTest {
    @get:Rule
    val composeTestRule = createComposeRule()

    @Test
    fun rendersPlaceholderWhenEmpty() {
        composeTestRule.setContent {
            BeidAppTheme {
                BeidTextField(
                    value = "",
                    onValueChange = {},
                    placeholder = "Event code",
                    isError = false,
                )
            }
        }

        composeTestRule.onNodeWithText("Event code").assertIsDisplayed()
    }

    @Test
    fun forwardsTypedInputToOnValueChange() {
        var latestValue = ""
        composeTestRule.setContent {
            BeidAppTheme {
                BeidTextField(
                    value = "",
                    onValueChange = { latestValue = it },
                    placeholder = "Event code",
                    isError = false,
                )
            }
        }

        composeTestRule.onNodeWithText("Event code").performTextInput("ABC123")

        assert(latestValue == "ABC123") { "expected onValueChange to be called with ABC123, got $latestValue" }
    }

    @Test
    fun disabledFieldReportsNotEnabledAndRejectsInput() {
        var latestValue = ""
        composeTestRule.setContent {
            BeidAppTheme {
                BeidTextField(
                    value = "",
                    onValueChange = { latestValue = it },
                    placeholder = "Event code",
                    isError = false,
                    enabled = false,
                    modifier = Modifier.testTag("field"),
                )
            }
        }

        composeTestRule.onNodeWithTag("field").assertIsNotEnabled()
        runCatching { composeTestRule.onNodeWithTag("field").performTextInput("ABC123") }
        assert(latestValue == "") { "a disabled field must not forward input, got $latestValue" }
    }

    @Test
    fun fieldIsEnabledByDefault() {
        composeTestRule.setContent {
            BeidAppTheme {
                BeidTextField(
                    value = "",
                    onValueChange = {},
                    placeholder = "Event code",
                    isError = false,
                    modifier = Modifier.testTag("field"),
                )
            }
        }

        composeTestRule.onNodeWithTag("field").assertIsEnabled()
    }
}
