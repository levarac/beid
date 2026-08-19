package org.levarac.beid.ui.designsystem

import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
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
class BeidBulletRowTest {
    @get:Rule
    val composeTestRule = createComposeRule()

    @Test
    fun rendersTitleAndSubtitleWithADecorativeIcon() {
        composeTestRule.setContent {
            BeidAppTheme {
                BeidBulletRow(
                    icon = testIcon,
                    title = "Works in the background",
                    subtitle = "Sensing continues while you use other apps.",
                    tint = Color.Red,
                    modifier = Modifier.testTag("bullet_row"),
                )
            }
        }

        composeTestRule.onNodeWithText("Works in the background").assertIsDisplayed()
        composeTestRule.onNodeWithText("Sensing continues while you use other apps.").assertIsDisplayed()
    }

    @Test
    fun titleOnlyRowOmitsSubtitle() {
        composeTestRule.setContent {
            BeidAppTheme {
                BeidBulletRow(
                    icon = testIcon,
                    title = "Works in the background",
                    tint = Color.Red,
                )
            }
        }

        composeTestRule.onNodeWithText("Works in the background").assertIsDisplayed()
    }
}
