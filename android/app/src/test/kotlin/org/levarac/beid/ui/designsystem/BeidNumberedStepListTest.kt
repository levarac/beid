package org.levarac.beid.ui.designsystem

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
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
class BeidNumberedStepListTest {
    @get:Rule
    val composeTestRule = createComposeRule()

    @Test
    fun rendersEachStepWithItsIndexBadge() {
        composeTestRule.setContent {
            BeidAppTheme {
                BeidNumberedStepList(
                    steps = listOf("Open Settings", "Tap Bluetooth", "Switch it on"),
                    badgeColor = Color.Red,
                    labelColor = Color.White,
                )
            }
        }

        composeTestRule.onNodeWithText("1").assertIsDisplayed()
        composeTestRule.onNodeWithText("Open Settings").assertIsDisplayed()
        composeTestRule.onNodeWithText("2").assertIsDisplayed()
        composeTestRule.onNodeWithText("Tap Bluetooth").assertIsDisplayed()
        composeTestRule.onNodeWithText("3").assertIsDisplayed()
        composeTestRule.onNodeWithText("Switch it on").assertIsDisplayed()
    }
}
