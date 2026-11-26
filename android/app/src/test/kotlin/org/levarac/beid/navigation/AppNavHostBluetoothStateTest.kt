package org.levarac.beid.navigation

import android.bluetooth.BluetoothAdapter
import android.content.Context
import android.content.Intent
import androidx.activity.ComponentActivity
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.StateRestorationTester
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.lifecycle.Lifecycle
import androidx.test.core.app.ApplicationProvider
import java.io.File
import kotlin.test.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith
import org.levarac.beid.onboarding.OnboardingPreferences
import org.levarac.beid.persistence.ProofRecordStore
import org.levarac.beid.sensing.BluetoothPermissionState
import org.levarac.beid.ui.screens.BluetoothDeniedScreenTestTags
import org.levarac.beid.ui.screens.BluetoothOffScreenTestTags
import org.levarac.beid.ui.screens.EventJoinScreenTestTags
import org.levarac.beid.ui.screens.FakeEventJoinSession
import org.levarac.beid.ui.theme.BeidAppTheme
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowBluetoothAdapter
import org.robolectric.shadows.ShadowLooper

/**
 * Bluetooth state changes while the app runs, after onboarding. Follows iOS
 * #832 (`AppCoordinator.swift:273-278` on
 * `fix/ios-1.1.1-bluetooth-denied-recovery`): the denied guidance recovers on
 * a later state update, other screens keep their route. A revoked permission
 * reaches the denied guidance from any post-onboarding screen, as iOS does
 * through its terminate-and-restore path.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class AppNavHostBluetoothStateTest {
    @get:Rule
    val composeTestRule = createAndroidComposeRule<ComponentActivity>()

    @get:Rule
    val tempFolder = TemporaryFolder()

    private val context: Context get() = ApplicationProvider.getApplicationContext()
    private val shadowAdapter: ShadowBluetoothAdapter get() = shadowOf(BluetoothAdapter.getDefaultAdapter())
    private fun proofRecordStore() = ProofRecordStore(File(tempFolder.root, "proof-records-v1.json"))

    @Test
    fun deniedGuidanceRoutesHomeWhenPermissionIsGrantedWhileAway() {
        OnboardingPreferences(context).hasCompletedOnboarding = true
        shadowAdapter.setEnabled(true)
        val session = FakeEventJoinSession(initialBluetoothPermissionState = BluetoothPermissionState.Denied)
        composeTestRule.setContent { BeidAppTheme { AppNavHost(session, proofRecordStore()) } }
        composeTestRule.onNodeWithTag(BluetoothDeniedScreenTestTags.OPEN_SETTINGS_BUTTON).assertIsDisplayed()

        session.bluetoothPermissionState = BluetoothPermissionState.Granted
        pauseAndResume()

        composeTestRule.onNodeWithTag(EventJoinScreenTestTags.NEARBY_EVENT_LIST).assertIsDisplayed()
        composeTestRule.onNodeWithTag(BluetoothDeniedScreenTestTags.OPEN_SETTINGS_BUTTON).assertDoesNotExist()
    }

    @Test
    fun deniedGuidanceRoutesToBluetoothOffWhenGrantedWithTheRadioOff() {
        OnboardingPreferences(context).hasCompletedOnboarding = true
        shadowAdapter.setEnabled(true)
        val session = FakeEventJoinSession(initialBluetoothPermissionState = BluetoothPermissionState.Denied)
        composeTestRule.setContent { BeidAppTheme { AppNavHost(session, proofRecordStore()) } }
        composeTestRule.onNodeWithTag(BluetoothDeniedScreenTestTags.OPEN_SETTINGS_BUTTON).assertIsDisplayed()

        session.bluetoothPermissionState = BluetoothPermissionState.Granted
        shadowAdapter.setEnabled(false)
        pauseAndResume()

        composeTestRule.onNodeWithTag(BluetoothOffScreenTestTags.TURNED_ON_BUTTON).assertIsDisplayed()
    }

    @Test
    fun permissionRevokedWhileAwayRoutesHomeToDeniedGuidanceOnResume() {
        OnboardingPreferences(context).hasCompletedOnboarding = true
        shadowAdapter.setEnabled(true)
        val session = FakeEventJoinSession()
        composeTestRule.setContent { BeidAppTheme { AppNavHost(session, proofRecordStore()) } }
        composeTestRule.onNodeWithTag(EventJoinScreenTestTags.NEARBY_EVENT_LIST).assertIsDisplayed()

        session.bluetoothPermissionState = BluetoothPermissionState.Denied
        pauseAndResume()

        composeTestRule.onNodeWithTag(BluetoothDeniedScreenTestTags.OPEN_SETTINGS_BUTTON).assertIsDisplayed()
    }

    /**
     * Android kills the process when a runtime permission is revoked, then
     * restores the saved navigation back stack — which ignores the start
     * destination that would otherwise have chosen the denied guidance.
     */
    @Test
    fun savedStateRestoreWithARevokedPermissionLandsOnDeniedGuidance() {
        OnboardingPreferences(context).hasCompletedOnboarding = true
        shadowAdapter.setEnabled(true)
        val session = FakeEventJoinSession()
        val store = proofRecordStore()
        val restorationTester = StateRestorationTester(composeTestRule)
        restorationTester.setContent { BeidAppTheme { AppNavHost(session, store) } }
        composeTestRule.onNodeWithTag(EventJoinScreenTestTags.NEARBY_EVENT_LIST).assertIsDisplayed()

        session.bluetoothPermissionState = BluetoothPermissionState.Denied
        restorationTester.emulateSavedInstanceStateRestore()

        composeTestRule.onNodeWithTag(BluetoothDeniedScreenTestTags.OPEN_SETTINGS_BUTTON).assertIsDisplayed()
        composeTestRule.onNodeWithTag(EventJoinScreenTestTags.NEARBY_EVENT_LIST).assertDoesNotExist()
    }

    /** iOS's Bluetooth-off screen recovers only through "I've turned it on" (#832 ignores it). */
    @Test
    fun bluetoothOffScreenStaysWhenTheRadioComesBack() {
        OnboardingPreferences(context).hasCompletedOnboarding = true
        shadowAdapter.setEnabled(false)
        val session = FakeEventJoinSession()
        composeTestRule.setContent { BeidAppTheme { AppNavHost(session, proofRecordStore()) } }
        composeTestRule.onNodeWithTag(BluetoothOffScreenTestTags.TURNED_ON_BUTTON).assertIsDisplayed()

        shadowAdapter.setEnabled(true)
        broadcastRadioState(BluetoothAdapter.STATE_ON)
        pauseAndResume()

        composeTestRule.onNodeWithTag(BluetoothOffScreenTestTags.TURNED_ON_BUTTON).assertIsDisplayed()
    }

    @Test
    fun radioChangesReachTheSessionWhileHomeIsShown() {
        OnboardingPreferences(context).hasCompletedOnboarding = true
        shadowAdapter.setEnabled(true)
        val session = FakeEventJoinSession()
        composeTestRule.setContent { BeidAppTheme { AppNavHost(session, proofRecordStore()) } }
        composeTestRule.onNodeWithTag(EventJoinScreenTestTags.NEARBY_EVENT_LIST).assertIsDisplayed()

        shadowAdapter.setEnabled(false)
        broadcastRadioState(BluetoothAdapter.STATE_OFF)
        composeTestRule.waitForIdle()
        shadowAdapter.setEnabled(true)
        broadcastRadioState(BluetoothAdapter.STATE_ON)
        composeTestRule.waitForIdle()

        assertEquals(listOf(true, false, true), session.bluetoothRadioChanges)
        composeTestRule.onNodeWithTag(EventJoinScreenTestTags.NEARBY_EVENT_LIST).assertIsDisplayed()
    }

    private fun pauseAndResume() {
        composeTestRule.activityRule.scenario.moveToState(Lifecycle.State.STARTED)
        composeTestRule.activityRule.scenario.moveToState(Lifecycle.State.RESUMED)
        composeTestRule.waitForIdle()
    }

    private fun broadcastRadioState(state: Int) {
        context.sendBroadcast(
            Intent(BluetoothAdapter.ACTION_STATE_CHANGED).putExtra(BluetoothAdapter.EXTRA_STATE, state),
        )
        ShadowLooper.idleMainLooper()
    }
}
