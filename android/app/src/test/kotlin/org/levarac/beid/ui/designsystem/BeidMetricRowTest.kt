package org.levarac.beid.ui.designsystem

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
class BeidMetricRowTest {
    @get:Rule
    val composeTestRule = createComposeRule()

    @Test
    fun rendersLabelAndValue() {
        composeTestRule.setContent {
            BeidAppTheme {
                BeidMetricRow(label = "Method", value = "BLE mutual observation")
            }
        }

        composeTestRule.onNodeWithText("Method").assertIsDisplayed()
        composeTestRule.onNodeWithText("BLE mutual observation").assertIsDisplayed()
    }
}
