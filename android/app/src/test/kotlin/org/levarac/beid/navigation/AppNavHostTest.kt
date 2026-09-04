package org.levarac.beid.navigation

import android.bluetooth.BluetoothAdapter
import android.content.Context
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.test.core.app.ApplicationProvider
import java.io.File
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith
import org.levarac.beid.onboarding.OnboardingPreferences
import org.levarac.beid.persistence.ProofRecordStore
import org.levarac.beid.sensing.EventJoinUiState
import org.levarac.beid.sensing.ScanPhase
import org.levarac.beid.ui.screens.AccountScreenTestTags
import org.levarac.beid.ui.screens.BluetoothOffScreenTestTags
import org.levarac.beid.ui.screens.BluetoothPermissionScreenTestTags
import org.levarac.beid.ui.screens.EventJoinScreenTestTags
import org.levarac.beid.ui.screens.FakeEventJoinSession
import org.levarac.beid.ui.screens.RecordsScreenTestTags
import org.levarac.beid.ui.screens.TodaySummaryScreenTestTags
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

    @get:Rule
    val tempFolder = TemporaryFolder()

    private val context: Context get() = ApplicationProvider.getApplicationContext()
    private val shadowAdapter: ShadowBluetoothAdapter get() = shadowOf(BluetoothAdapter.getDefaultAdapter())
    private fun proofRecordStore() = ProofRecordStore(File(tempFolder.root, "proof-records-v1.json"))

    @Test
    fun firstRunWalksWelcomeThroughBluetoothPermissionToBluetoothOffThenToHomeOnceRadioIsEnabled() {
        shadowAdapter.setEnabled(false)
        val session = FakeEventJoinSession()

        composeTestRule.setContent {
            BeidAppTheme { AppNavHost(session, proofRecordStore()) }
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
        composeTestRule.onNodeWithTag(EventJoinScreenTestTags.NEARBY_EVENT_LIST).assertIsDisplayed()
    }

    @Test
    fun restoringAnOnboardedUserWithARadioThatIsNowOffStartsDirectlyOnBluetoothOff() {
        OnboardingPreferences(context).hasCompletedOnboarding = true
        shadowAdapter.setEnabled(false)
        val session = FakeEventJoinSession()

        composeTestRule.setContent {
            BeidAppTheme { AppNavHost(session, proofRecordStore()) }
        }

        composeTestRule.onNodeWithTag(BluetoothOffScreenTestTags.OPEN_SETTINGS_BUTTON).assertIsDisplayed()
        composeTestRule.onNodeWithTag(WelcomeScreenTestTags.GET_STARTED_BUTTON).assertDoesNotExist()
    }

    @Test
    fun restoringAnOnboardedUserWithRadioOnStartsNearbyDiscoveryFromEventJoinEntry() {
        OnboardingPreferences(context).hasCompletedOnboarding = true
        shadowAdapter.setEnabled(true)
        val session = FakeEventJoinSession()

        composeTestRule.setContent {
            BeidAppTheme { AppNavHost(session, proofRecordStore()) }
        }

        composeTestRule.onNodeWithTag(EventJoinScreenTestTags.NEARBY_EVENT_LIST).assertIsDisplayed()
        assertEquals(1, session.nearbyEventDiscoveryStartCalls)
    }

    @Test
    fun openingAccountFromEventJoinAndLeavingAnActiveSessionCallsSessionLeaveEvent() {
        OnboardingPreferences(context).hasCompletedOnboarding = true
        shadowAdapter.setEnabled(true)
        val session = FakeEventJoinSession(EventJoinUiState.Sensing(ScanPhase.Sensing))

        composeTestRule.setContent {
            BeidAppTheme { AppNavHost(session, proofRecordStore()) }
        }

        composeTestRule.onNodeWithTag(EventJoinScreenTestTags.PHASE_STATUS_PILL).assertIsDisplayed()
        composeTestRule.onNodeWithTag(EventJoinScreenTestTags.ACCOUNT_ENTRY).performClick()

        composeTestRule.onNodeWithTag(AccountScreenTestTags.LEAVE_EVENT_BUTTON).assertIsDisplayed()
        composeTestRule.onNodeWithTag(AccountScreenTestTags.LEAVE_EVENT_BUTTON).performClick()

        assertEquals(1, session.leaveEventCallCount)
    }

    @Test
    fun openingRecordsFromAccountShowsTheEmptyRecordsState() {
        OnboardingPreferences(context).hasCompletedOnboarding = true
        shadowAdapter.setEnabled(true)
        val session = FakeEventJoinSession()

        composeTestRule.setContent {
            BeidAppTheme { AppNavHost(session, proofRecordStore()) }
        }

        composeTestRule.onNodeWithTag(EventJoinScreenTestTags.ACCOUNT_ENTRY).performClick()
        composeTestRule.onNodeWithTag(AccountScreenTestTags.RECORDS_BUTTON).performClick()

        composeTestRule.onNodeWithTag(RecordsScreenTestTags.EMPTY_STATE).assertIsDisplayed()
    }

    @Test
    fun openingTodayFromRecordsShowsTheSeparateDailySummaryEmptyState() {
        OnboardingPreferences(context).hasCompletedOnboarding = true
        shadowAdapter.setEnabled(true)

        composeTestRule.setContent {
            BeidAppTheme { AppNavHost(FakeEventJoinSession(), proofRecordStore()) }
        }

        composeTestRule.onNodeWithTag(EventJoinScreenTestTags.ACCOUNT_ENTRY).performClick()
        composeTestRule.onNodeWithTag(AccountScreenTestTags.RECORDS_BUTTON).performClick()
        composeTestRule.onNodeWithTag(RecordsScreenTestTags.TODAY_BUTTON).performClick()

        composeTestRule.onNodeWithTag(TodaySummaryScreenTestTags.EMPTY_STATE).assertIsDisplayed()
    }

    @Test
    fun manualEventCodeEntryIsReachableOnlyThroughAccount() {
        OnboardingPreferences(context).hasCompletedOnboarding = true
        shadowAdapter.setEnabled(true)
        val session = FakeEventJoinSession()
        composeTestRule.setContent { BeidAppTheme { AppNavHost(session, proofRecordStore()) } }

        composeTestRule.onNodeWithTag(EventJoinScreenTestTags.SUBMIT_BUTTON).assertDoesNotExist()
        composeTestRule.onNodeWithTag(EventJoinScreenTestTags.ACCOUNT_ENTRY).performClick()
        composeTestRule.onNodeWithTag(AccountScreenTestTags.MANUAL_EVENT_CODE_BUTTON).performClick()

        composeTestRule.onNodeWithTag(EventJoinScreenTestTags.SUBMIT_BUTTON).assertIsDisplayed()
    }
}
