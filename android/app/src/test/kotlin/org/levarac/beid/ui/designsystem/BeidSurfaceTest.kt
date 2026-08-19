package org.levarac.beid.ui.designsystem

import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.Box
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
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class BeidSurfaceTest {
    @get:Rule
    val composeTestRule = createComposeRule()

    @Test
    fun beidSurfaceRendersWithoutCrashing() {
        composeTestRule.setContent {
            BeidAppTheme {
                Box(
                    modifier = Modifier
                        .size(48.dp)
                        .beidSurface(cornerRadius = 12.dp)
                        .testTag("surface_box"),
                )
            }
        }

        composeTestRule.onNodeWithTag("surface_box").assertIsDisplayed()
    }
}
