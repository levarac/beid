package org.levarac.beid.ui.designsystem

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.unit.dp
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
 *
 * `Canvas`-drawn pixels aren't verifiable through Compose's semantics tree
 * in a Robolectric/JVM test (no emulator/simulator is available in this
 * environment either), so these tests are a smoke check only: each
 * composable must compose and lay out inside its container without
 * throwing. They do not verify the drawn geometry pixel-for-pixel.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class IllustrationsTest {
    @get:Rule
    val composeTestRule = createComposeRule()

    @Test
    fun welcomeMarkGlyphComposesInsideItsContainer() {
        composeTestRule.setContent {
            BeidAppTheme {
                Box(modifier = Modifier.size(72.dp).testTag("welcome_mark")) {
                    WelcomeMarkGlyph()
                }
            }
        }

        composeTestRule.onNodeWithTag("welcome_mark").assertIsDisplayed()
    }

    @Test
    fun encounterFieldPulseGlyphComposesInsideItsContainer() {
        composeTestRule.setContent {
            BeidAppTheme {
                Box(modifier = Modifier.size(72.dp).testTag("encounter_field_pulse")) {
                    EncounterFieldPulseGlyph()
                }
            }
        }

        composeTestRule.onNodeWithTag("encounter_field_pulse").assertIsDisplayed()
    }

    @Test
    fun proofSealMarkGlyphComposesInsideItsContainer() {
        composeTestRule.setContent {
            BeidAppTheme {
                Box(modifier = Modifier.size(72.dp).testTag("proof_seal_mark")) {
                    ProofSealMarkGlyph()
                }
            }
        }

        composeTestRule.onNodeWithTag("proof_seal_mark").assertIsDisplayed()
    }
}
