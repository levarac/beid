package org.levarac.beid.ui.designsystem

import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import kotlin.test.assertEquals
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
class BeidButtonsTest {
    @get:Rule
    val composeTestRule = createComposeRule()

    @Test
    fun primaryButtonRendersLabelAndInvokesOnClick() {
        var clicks = 0
        composeTestRule.setContent {
            BeidAppTheme {
                BeidPrimaryButton(
                    text = "Join event",
                    containerColor = Color.Black,
                    contentColor = Color.White,
                    onClick = { clicks++ },
                    modifier = Modifier.testTag("primary_button"),
                )
            }
        }

        composeTestRule.onNodeWithText("Join event").assertIsDisplayed()
        composeTestRule.onNodeWithTag("primary_button").performClick()
        assertEquals(1, clicks)
    }

    @Test
    fun disabledPrimaryButtonIsNotEnabled() {
        composeTestRule.setContent {
            BeidAppTheme {
                BeidPrimaryButton(
                    text = "Join event",
                    containerColor = Color.Black,
                    contentColor = Color.White,
                    onClick = {},
                    enabled = false,
                    modifier = Modifier.testTag("primary_button"),
                )
            }
        }

        composeTestRule.onNodeWithTag("primary_button").assertIsNotEnabled()
    }

    @Test
    fun secondaryButtonRendersLabelAndInvokesOnClick() {
        var clicks = 0
        composeTestRule.setContent {
            BeidAppTheme {
                BeidSecondaryButton(
                    text = "Open Settings",
                    contentColor = Color.Black,
                    borderColor = Color.Gray,
                    onClick = { clicks++ },
                    modifier = Modifier.testTag("secondary_button"),
                )
            }
        }

        composeTestRule.onNodeWithText("Open Settings").assertIsDisplayed()
        composeTestRule.onNodeWithTag("secondary_button").performClick()
        assertEquals(1, clicks)
    }
}
