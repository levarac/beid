package org.levarac.beid.ui.designsystem

import androidx.compose.material3.Text
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
class BeidPanelTest {
    @get:Rule
    val composeTestRule = createComposeRule()

    @Test
    fun rendersItsContent() {
        composeTestRule.setContent {
            BeidAppTheme {
                BeidPanel {
                    Text("Panel content")
                }
            }
        }

        composeTestRule.onNodeWithText("Panel content").assertIsDisplayed()
    }
}
