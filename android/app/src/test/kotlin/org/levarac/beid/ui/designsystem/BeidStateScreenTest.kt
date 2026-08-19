package org.levarac.beid.ui.designsystem

import androidx.compose.material3.Text
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
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
class BeidStateScreenTest {
    @get:Rule
    val composeTestRule = createComposeRule()

    @Test
    fun composesHeroHeaderAccessoryAndFooter() {
        composeTestRule.setContent {
            BeidAppTheme {
                BeidStateScreen(
                    icon = testIcon,
                    title = "Bluetooth is off",
                    message = "Turn on Bluetooth to sense nearby peers.",
                    tint = Color.Red,
                    accessory = { Text("Accessory", modifier = Modifier.testTag("accessory")) },
                    footer = { Text("Open Settings", modifier = Modifier.testTag("footer")) },
                )
            }
        }

        composeTestRule.onNodeWithText("Bluetooth is off").assertIsDisplayed()
        composeTestRule.onNodeWithText("Turn on Bluetooth to sense nearby peers.").assertIsDisplayed()
        composeTestRule.onNodeWithTag("accessory").assertIsDisplayed()
        composeTestRule.onNodeWithTag("footer").assertIsDisplayed()
    }
}
