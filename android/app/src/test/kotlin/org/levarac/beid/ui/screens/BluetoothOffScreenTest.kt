package org.levarac.beid.ui.screens

import android.content.Context
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
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
class BluetoothOffScreenTest {
    @get:Rule
    val composeTestRule = createComposeRule()

    @Test
    fun rendersTitleStepsAndInvokesEachButtonsCallback() {
        var openSettingsTapped = false
        var turnedOnTapped = false

        composeTestRule.setContent {
            BeidAppTheme {
                BluetoothOffScreen(
                    onOpenSettings = { openSettingsTapped = true },
                    onTurnedOn = { turnedOnTapped = true },
                )
            }
        }

        val context = ApplicationProvider.getApplicationContext<Context>()
        composeTestRule.onNodeWithText(context.getString(R.string.bluetooth_off_title)).assertIsDisplayed()
        composeTestRule.onNodeWithText(context.getString(R.string.bluetooth_off_step_tap_bluetooth)).assertIsDisplayed()
        composeTestRule.onNodeWithText(context.getString(R.string.bluetooth_off_step_switch_on)).assertIsDisplayed()

        composeTestRule.onNodeWithTag(BluetoothOffScreenTestTags.OPEN_SETTINGS_BUTTON).performClick()
        assertTrue(openSettingsTapped)

        composeTestRule.onNodeWithTag(BluetoothOffScreenTestTags.TURNED_ON_BUTTON).performClick()
        assertTrue(turnedOnTapped)
    }
}
