package org.levarac.beid.ui.screens

import android.content.Context
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.test.core.app.ApplicationProvider
import kotlin.test.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.levarac.beid.R
import org.levarac.beid.ui.theme.BeidAppTheme
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class BluetoothPermissionScreenTest {
    @get:Rule
    val composeTestRule = createComposeRule()

    @Test
    fun rendersTitleBulletsAndInvokesCallbackOnAllowBluetooth() {
        var allowTapped = false

        composeTestRule.setContent {
            BeidAppTheme {
                BluetoothPermissionScreen(onAllowBluetooth = { allowTapped = true })
            }
        }

        val context = ApplicationProvider.getApplicationContext<Context>()
        composeTestRule.onNodeWithText(context.getString(R.string.bluetooth_permission_title)).assertIsDisplayed()
        composeTestRule.onNodeWithText(
            context.getString(R.string.bluetooth_permission_bullet_events_find_you_title),
        ).assertIsDisplayed()
        composeTestRule.onNodeWithText(
            context.getString(R.string.bluetooth_permission_bullet_private_title),
        ).assertIsDisplayed()
        // The header icon roundel (beid#338) plus 3 bullets no longer reliably fit
        // above the footer on every viewport, so the body scrolls — this bullet can
        // start below the fold, hence the explicit scroll before asserting.
        composeTestRule.onNodeWithText(
            context.getString(R.string.bluetooth_permission_bullet_zero_effort_title),
        ).performScrollTo().assertIsDisplayed()

        composeTestRule.onNodeWithTag(BluetoothPermissionScreenTestTags.ALLOW_BUTTON).performClick()
        assertTrue(allowTapped)
    }
}
