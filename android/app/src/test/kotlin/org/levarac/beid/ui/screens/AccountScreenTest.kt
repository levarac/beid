package org.levarac.beid.ui.screens

import android.content.Context
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.test.core.app.ApplicationProvider
import kotlin.test.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.levarac.beid.R
import org.levarac.beid.sensing.EventJoinUiState
import org.levarac.beid.sensing.CachedWalletHint
import org.levarac.beid.sensing.WalletConnectorState
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
                AccountScreen(viewModel = viewModel, isBluetoothOn = true, onOpenRecords = {})
            }
        }

        composeTestRule.onNodeWithText(context.getString(R.string.account_bluetooth_status_on)).assertIsDisplayed()
    }

    @Test
    fun bluetoothOffRendersTheOffStatusText() {
        val viewModel = AccountViewModel(FakeEventJoinSession())

        composeTestRule.setContent {
            BeidAppTheme {
                AccountScreen(viewModel = viewModel, isBluetoothOn = false, onOpenRecords = {})
            }
        }

        composeTestRule.onNodeWithText(context.getString(R.string.account_bluetooth_status_off)).assertIsDisplayed()
    }

    @Test
    fun leaveEventIsDisabledWithNoActiveSession() {
        val viewModel = AccountViewModel(FakeEventJoinSession(EventJoinUiState.Idle))

        composeTestRule.setContent {
            BeidAppTheme {
                AccountScreen(viewModel = viewModel, isBluetoothOn = true, onOpenRecords = {})
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
                AccountScreen(viewModel = viewModel, isBluetoothOn = true, onOpenRecords = {})
            }
        }

        composeTestRule.onNodeWithTag(AccountScreenTestTags.LEAVE_EVENT_BUTTON).performScrollTo().assertIsEnabled()
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
                AccountScreen(viewModel = viewModel, isBluetoothOn = true, onOpenRecords = {})
            }
        }

        composeTestRule.onNodeWithTag(AccountScreenTestTags.LEAVE_EVENT_BUTTON).assertIsEnabled()
    }

    @Test
    fun recordsButtonNavigatesToRecords() {
        val viewModel = AccountViewModel(FakeEventJoinSession())
        var openRecordsCallCount = 0

        composeTestRule.setContent {
            BeidAppTheme {
                AccountScreen(viewModel = viewModel, isBluetoothOn = true, onOpenRecords = { openRecordsCallCount++ })
            }
        }

        composeTestRule.onNodeWithTag(AccountScreenTestTags.RECORDS_BUTTON).assertIsDisplayed()
        composeTestRule.onNodeWithTag(AccountScreenTestTags.RECORDS_BUTTON).performClick()

        assertEquals(1, openRecordsCallCount)
    }

    @Test
    fun venueBroadcastEntryIsPresentedInAccount() {
        val viewModel = AccountViewModel(FakeEventJoinSession())

        composeTestRule.setContent {
            BeidAppTheme {
                AccountScreen(viewModel = viewModel, isBluetoothOn = true, onOpenRecords = {})
            }
        }

        composeTestRule
            .onNodeWithTag("account_venue_broadcast_button")
            .performScrollTo()
            .assertIsDisplayed()
    }

    @Test
    fun restoredWalletIsShownImmediatelyAsReferenceOnly() {
        val viewModel = AccountViewModel(FakeEventJoinSession())
        val hint = CachedWalletHint("0x1234567890abcdef1234567890abcdef12345678", 8453L)

        composeTestRule.setContent {
            BeidAppTheme {
                AccountScreen(
                    viewModel = viewModel,
                    isBluetoothOn = true,
                    onOpenRecords = {},
                    walletState = WalletConnectorState.Restored(hint),
                )
            }
        }

        composeTestRule.onNodeWithText(context.getString(R.string.account_wallet_reference_title)).assertIsDisplayed()
        composeTestRule.onNodeWithText(
            context.getString(R.string.account_wallet_reference_value, "0x1234...5678", 8453L),
        ).assertIsDisplayed()
        composeTestRule.onNodeWithText(context.getString(R.string.account_wallet_restored_reference_note)).assertIsDisplayed()
    }

    @Test
    fun noWalletConnectedStillRendersOptionalStateAndKeepsTheAppActionsUsable() {
        val viewModel = AccountViewModel(FakeEventJoinSession())
        var openRecordsCallCount = 0

        composeTestRule.setContent {
            BeidAppTheme {
                AccountScreen(
                    viewModel = viewModel,
                    isBluetoothOn = true,
                    onOpenRecords = { openRecordsCallCount += 1 },
                    walletState = WalletConnectorState.Idle,
                )
            }
        }

        composeTestRule.onNodeWithText(context.getString(R.string.account_wallet_optional)).assertIsDisplayed()
        composeTestRule.onNodeWithTag(AccountScreenTestTags.RECORDS_BUTTON).performClick()
        assertEquals(1, openRecordsCallCount)
    }
}
