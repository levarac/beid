package org.levarac.beid.ui.screens

import android.content.Context
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.core.app.ApplicationProvider
import kotlin.test.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.levarac.beid.R
import org.levarac.beid.sensing.EventJoinUiState
import org.levarac.beid.sensing.ScanEventSession
import org.levarac.beid.sensing.ScanPhase
import org.levarac.beid.ui.theme.BeidAppTheme
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * Robolectric-backed Compose test — same shape as [EventJoinScreenTest], see
 * android/README.md "Testing" for why this runs as a JVM
 * `:app:testDebugUnitTest` test instead of an instrumented `androidTest`.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class AccountScreenTest {
    @get:Rule
    val composeTestRule = createComposeRule()

    private val context: Context get() = ApplicationProvider.getApplicationContext()

    @Test
    fun bluetoothOnRendersTheActiveStatusText() {
        val viewModel = AccountViewModel(FakeEventJoinSession())

        composeTestRule.setContent {
            BeidAppTheme {
                AccountScreen(viewModel = viewModel, isBluetoothOn = true)
            }
        }

        composeTestRule.onNodeWithText(context.getString(R.string.account_bluetooth_status_on)).assertIsDisplayed()
    }

    @Test
    fun bluetoothOffRendersTheOffStatusText() {
        val viewModel = AccountViewModel(FakeEventJoinSession())

        composeTestRule.setContent {
            BeidAppTheme {
                AccountScreen(viewModel = viewModel, isBluetoothOn = false)
            }
        }

        composeTestRule.onNodeWithText(context.getString(R.string.account_bluetooth_status_off)).assertIsDisplayed()
    }

    @Test
    fun leaveEventIsDisabledWithNoActiveSession() {
        val viewModel = AccountViewModel(FakeEventJoinSession(EventJoinUiState.Idle))

        composeTestRule.setContent {
            BeidAppTheme {
                AccountScreen(viewModel = viewModel, isBluetoothOn = true)
            }
        }

        composeTestRule.onNodeWithTag(AccountScreenTestTags.LEAVE_EVENT_BUTTON).assertIsNotEnabled()
    }

    @Test
    fun leaveEventIsEnabledWithAnActiveSensingSessionAndCallsSessionLeaveEvent() {
        val session = FakeEventJoinSession(EventJoinUiState.Sensing(ScanPhase.Sensing))
        val viewModel = AccountViewModel(session)

        composeTestRule.setContent {
            BeidAppTheme {
                AccountScreen(viewModel = viewModel, isBluetoothOn = true)
            }
        }

        composeTestRule.onNodeWithTag(AccountScreenTestTags.LEAVE_EVENT_BUTTON).assertIsEnabled()
        composeTestRule.onNodeWithTag(AccountScreenTestTags.LEAVE_EVENT_BUTTON).performClick()

        assertEquals(1, session.leaveEventCallCount)
    }

    @Test
    fun leaveEventIsEnabledDuringRecordingPhaseToo() {
        val session1 = ScanEventSession(eventCode = "ABC123")
        val session = FakeEventJoinSession(EventJoinUiState.Sensing(ScanPhase.Recording(session1, peersVerified = 2)))
        val viewModel = AccountViewModel(session)

        composeTestRule.setContent {
            BeidAppTheme {
                AccountScreen(viewModel = viewModel, isBluetoothOn = true)
            }
        }

        composeTestRule.onNodeWithTag(AccountScreenTestTags.LEAVE_EVENT_BUTTON).assertIsEnabled()
    }
}
