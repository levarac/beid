package org.levarac.beid.ui.designsystem

import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onChildren
import androidx.compose.ui.test.onNodeWithTag
import kotlin.test.assertTrue
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
class BeidGlyphTest {
    @get:Rule
    val composeTestRule = createComposeRule()

    @Test
    fun rendersAndIsExcludedFromTheAccessibilityTree() {
        composeTestRule.setContent {
            BeidAppTheme {
                BeidGlyph(
                    icon = testIcon,
                    tint = Color.Red,
                    modifier = Modifier.testTag("glyph"),
                )
            }
        }

        composeTestRule.onNodeWithTag("glyph").assertIsDisplayed()
        // Decorative — iOS marks the equivalent view .accessibilityHidden(true); the
        // Compose contract is that the icon contributes zero semantics nodes.
        val children = composeTestRule.onNodeWithTag("glyph").onChildren().fetchSemanticsNodes()
        assertTrue(children.isEmpty())
    }

    @Test
    fun customContentSlotTakesPrecedenceOverIcon() {
        composeTestRule.setContent {
            BeidAppTheme {
                BeidGlyph(
                    icon = testIcon,
                    tint = Color.Red,
                    modifier = Modifier.testTag("glyph"),
                    contentSlot = {
                        androidx.compose.material3.Text(
                            text = "custom",
                            modifier = Modifier.testTag("custom_slot"),
                        )
                    },
                )
            }
        }

        composeTestRule.onNodeWithTag("custom_slot").assertIsDisplayed()
    }
}
