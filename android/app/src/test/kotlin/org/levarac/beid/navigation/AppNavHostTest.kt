package org.levarac.beid.navigation

import android.bluetooth.BluetoothAdapter
import android.content.Context
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.test.core.app.ApplicationProvider
import kotlin.test.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.levarac.beid.onboarding.OnboardingPreferences
import org.levarac.beid.ui.screens.BluetoothOffScreenTestTags
import org.levarac.beid.ui.screens.BluetoothPermissionScreenTestTags
import org.levarac.beid.ui.screens.EventJoinScreenTestTags
import org.levarac.beid.ui.screens.FakeEventJoinSession
import org.levarac.beid.ui.screens.WelcomeScreenTestTags
import org.levarac.beid.ui.theme.BeidAppTheme
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowBluetoothAdapter

/**
 * End-to-end navigation test driving the whole onboarding sequence through
 * [AppNavHost] with a [FakeEventJoinSession] and a real
 * [ShadowBluetoothAdapter] standing in for radio power state — proves both
 * of Issue #123's acceptance criteria directly: the settled
 * Welcome → BluetoothPermission → Home/BluetoothOff flow, and the #194
 * restore-fix mirror for a since-powered-off radio.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class AppNavHostTest {
    @get:Rule
    val composeTestRule = createComposeRule()

    private val context: Context get() = ApplicationProvider.getApplicationContext()
    private val shadowAdapter: ShadowBluetoothAdapter get() = shadowOf(BluetoothAdapter.getDefaultAdapter())

    @Test
    fun firstRunWalksWelcomeThroughBluetoothPermissionToBluetoothOffThenToHomeOnceRadioIsEnabled() {
        shadowAdapter.setEnabled(false)
        val session = FakeEventJoinSession()

        composeTestRule.setContent {
            BeidAppTheme { AppNavHost(session) }
        }

        // 1. Welcome -> tap Get Started -> BluetoothPermission screen shown.
        composeTestRule.onNodeWithTag(WelcomeScreenTestTags.GET_STARTED_BUTTON).performClick()
        composeTestRule.onNodeWithTag(BluetoothPermissionScreenTestTags.ALLOW_BUTTON).assertIsDisplayed()

        // 2. Tap Allow Bluetooth (fake completes synchronously) with the shadow adapter
        // disabled -> lands on BluetoothOff, not Home.
        composeTestRule.onNodeWithTag(BluetoothPermissionScreenTestTags.ALLOW_BUTTON).performClick()
        assertTrue(session.permissionRequested)
        composeTestRule.onNodeWithTag(BluetoothOffScreenTestTags.TURNED_ON_BUTTON).assertIsDisplayed()

        // 3. On BluetoothOff, tap "I've turned it on" while still disabled -> still on
        // BluetoothOff (no navigation).
        composeTestRule.onNodeWithTag(BluetoothOffScreenTestTags.TURNED_ON_BUTTON).performClick()
        composeTestRule.onNodeWithTag(BluetoothOffScreenTestTags.TURNED_ON_BUTTON).assertIsDisplayed()

        // 4. Enable the shadow adapter, tap "I've turned it on" again -> lands on
        // the EventJoin/Home screen.
        shadowAdapter.setEnabled(true)
        composeTestRule.onNodeWithTag(BluetoothOffScreenTestTags.TURNED_ON_BUTTON).performClick()
        composeTestRule.onNodeWithTag(EventJoinScreenTestTags.SUBMIT_BUTTON).assertIsDisplayed()
    }

    @Test
    fun restoringAnOnboardedUserWithARadioThatIsNowOffStartsDirectlyOnBluetoothOff() {
        OnboardingPreferences(context).hasCompletedOnboarding = true
        shadowAdapter.setEnabled(false)
        val session = FakeEventJoinSession()

        composeTestRule.setContent {
            BeidAppTheme { AppNavHost(session) }
        }

        composeTestRule.onNodeWithTag(BluetoothOffScreenTestTags.OPEN_SETTINGS_BUTTON).assertIsDisplayed()
        composeTestRule.onNodeWithTag(WelcomeScreenTestTags.GET_STARTED_BUTTON).assertDoesNotExist()
    }
}
