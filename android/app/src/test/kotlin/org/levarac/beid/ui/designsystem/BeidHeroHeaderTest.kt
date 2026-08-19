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
class BeidHeroHeaderTest {
    @get:Rule
    val composeTestRule = createComposeRule()

    @Test
    fun rendersTitleAndSubtitle() {
        composeTestRule.setContent {
            BeidAppTheme {
                BeidHeroHeader(
                    icon = testIcon,
                    title = "Welcome",
                    subtitle = "Sense nearby peers to collect proofs.",
                    tint = Color.Red,
                )
            }
        }

        composeTestRule.onNodeWithText("Welcome").assertIsDisplayed()
        composeTestRule.onNodeWithText("Sense nearby peers to collect proofs.").assertIsDisplayed()
    }

    @Test
    fun rendersWithoutASubtitle() {
        composeTestRule.setContent {
            BeidAppTheme {
                BeidHeroHeader(
                    icon = testIcon,
                    title = "Welcome",
                    tint = Color.Red,
                )
            }
        }

        composeTestRule.onNodeWithText("Welcome").assertIsDisplayed()
    }
}
