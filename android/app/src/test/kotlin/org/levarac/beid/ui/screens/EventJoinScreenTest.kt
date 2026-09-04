package org.levarac.beid.ui.screens

import android.content.Context
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.assertHasClickAction
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsSelected
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.test.core.app.ApplicationProvider
import kotlin.test.assertNull
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.levarac.beid.R
import org.levarac.beid.sensing.EventJoinUiState
import org.levarac.beid.sensing.NearbyEventCard
import org.levarac.beid.sensing.ScanEventSession
import org.levarac.beid.sensing.ScanPhase
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
class EventJoinScreenTest {
    @get:Rule
    val composeTestRule = createComposeRule()

    private val session1 = ScanEventSession(eventCode = "ABC123")

    @Test
    fun manualEntrySubmittingAnEmptyEventCodeShowsTheInlineErrorAndDoesNotJoin() {
        val session = FakeEventJoinSession()
        val viewModel = EventJoinViewModel(session)

        composeTestRule.setContent {
            BeidAppTheme {
                ManualEventCodeScreen(viewModel)
            }
        }

        composeTestRule.onNodeWithTag(EventJoinScreenTestTags.SUBMIT_BUTTON).performClick()

        val context = ApplicationProvider.getApplicationContext<Context>()
        val expectedError = context.getString(R.string.event_join_error_empty_code)
        composeTestRule.onNodeWithTag(EventJoinScreenTestTags.FIELD_ERROR).assertIsDisplayed()
        composeTestRule.onNodeWithText(expectedError).assertIsDisplayed()
        assertNull(session.joinedCode)
    }

    @Test
    fun zeroCandidatesShowsSearchingAndRescueWithoutManualEntry() {
        val viewModel = EventJoinViewModel(FakeEventJoinSession())
        composeTestRule.setContent { BeidAppTheme { EventJoinScreen(viewModel, onOpenAccount = {}) } }

        composeTestRule.onNodeWithText("Searching for nearby events…").assertIsDisplayed()
        composeTestRule.onNodeWithText("You can enter a code from Account if no event appears.").assertIsDisplayed()
        composeTestRule.onNodeWithTag(EventJoinScreenTestTags.SUBMIT_BUTTON).assertDoesNotExist()
    }

    @Test
    fun sensingPhaseRendersItsOwnStatusTextAndNoPhaseDetailControls() {
        val session = FakeEventJoinSession(EventJoinUiState.Sensing(ScanPhase.Sensing))
        val viewModel = EventJoinViewModel(session)

        composeTestRule.setContent {
            BeidAppTheme {
                EventJoinScreen(viewModel, onOpenAccount = {})
            }
        }

        val context = ApplicationProvider.getApplicationContext<Context>()
        composeTestRule.onNodeWithText(context.getString(R.string.event_join_status_sensing)).assertIsDisplayed()
        composeTestRule.onNodeWithTag(EventJoinScreenTestTags.PEERS_VERIFIED_ROW).assertDoesNotExist()
        composeTestRule.onNodeWithTag(EventJoinScreenTestTags.RESUME_BUTTON).assertDoesNotExist()
    }

    @Test
    fun eventFoundPhaseRendersItsOwnStatusText() {
        val session = FakeEventJoinSession(EventJoinUiState.Sensing(ScanPhase.EventFound(session1)))
        val viewModel = EventJoinViewModel(session)

        composeTestRule.setContent {
            BeidAppTheme {
                EventJoinScreen(viewModel, onOpenAccount = {})
            }
        }

        val context = ApplicationProvider.getApplicationContext<Context>()
        composeTestRule.onNodeWithText(context.getString(R.string.event_join_status_event_found)).assertIsDisplayed()
    }

    @Test
    fun recordingPhaseRendersPeersVerifiedAndASimulateSignalLostControl() {
        val session = FakeEventJoinSession(EventJoinUiState.Sensing(ScanPhase.Recording(session1, peersVerified = 2)))
        val viewModel = EventJoinViewModel(session)

        composeTestRule.setContent {
            BeidAppTheme {
                EventJoinScreen(viewModel, onOpenAccount = {})
            }
        }

        val context = ApplicationProvider.getApplicationContext<Context>()
        composeTestRule.onNodeWithText(context.getString(R.string.event_join_status_recording)).assertIsDisplayed()
        composeTestRule.onNodeWithTag(EventJoinScreenTestTags.PEERS_VERIFIED_ROW).assertIsDisplayed()
        composeTestRule.onNodeWithText("2").assertIsDisplayed()

        composeTestRule.onNodeWithTag(EventJoinScreenTestTags.SIMULATE_SIGNAL_LOST_BUTTON)
            .performScrollTo()
            .assertIsDisplayed()
            .performClick()
        assertTrue(session.signalLostSimulated)
    }

    @Test
    fun tappingTheAccountEntryInvokesOnOpenAccount() {
        val session = FakeEventJoinSession()
        val viewModel = EventJoinViewModel(session)
        var accountOpened = false

        composeTestRule.setContent {
            BeidAppTheme {
                EventJoinScreen(viewModel, onOpenAccount = { accountOpened = true })
            }
        }

        composeTestRule.onNodeWithTag(EventJoinScreenTestTags.ACCOUNT_ENTRY).performClick()
        assertTrue(accountOpened)
    }

    @Test
    fun signalLostPhaseRendersAResumeControlThatCallsResumeSensing() {
        val session = FakeEventJoinSession(EventJoinUiState.Sensing(ScanPhase.SignalLost(session1, peersVerified = 2)))
        val viewModel = EventJoinViewModel(session)

        composeTestRule.setContent {
            BeidAppTheme {
                EventJoinScreen(viewModel, onOpenAccount = {})
            }
        }

        val context = ApplicationProvider.getApplicationContext<Context>()
        composeTestRule.onNodeWithText(context.getString(R.string.event_join_status_signal_lost)).assertIsDisplayed()
        composeTestRule.onNodeWithTag(EventJoinScreenTestTags.PEERS_VERIFIED_ROW).assertIsDisplayed()

        composeTestRule.onNodeWithTag(EventJoinScreenTestTags.RESUME_BUTTON)
            .performScrollTo()
            .assertIsDisplayed()
            .performClick()
        assertTrue(session.sensingResumed)
    }

    @Test
    fun oneVerifiedNearbyCandidateIsSelectedAndJoinsWithItsExactEventId() {
        val eventId = "0x0123456789abcdef"
        val session = FakeEventJoinSession(
            nearbyEventCards = listOf(
                NearbyEventCard("Beacon name", eventId, 100L, 200L, "1111111111111111"),
            ),
        )
        val viewModel = EventJoinViewModel(session)

        composeTestRule.setContent {
            BeidAppTheme { EventJoinScreen(viewModel, onOpenAccount = {}) }
        }

        composeTestRule.onNodeWithTag(EventJoinScreenTestTags.NEARBY_EVENT_LIST).assertIsDisplayed()
        composeTestRule.onNodeWithTag(EventJoinScreenTestTags.nearbyEventCard("1111111111111111"))
            .assertIsSelected()
            .assertHasClickAction()
            .assert(SemanticsMatcher.expectValue(SemanticsProperties.Role, Role.RadioButton))
            .performClick()
        composeTestRule.runOnIdle {
            assertEquals(eventId, viewModel.uiState.value.nearbyEventCards.single().eventIdHex)
            assertEquals("1111111111111111", viewModel.uiState.value.selectedNearbyEventHashHex)
        }
        composeTestRule.runOnIdle {
            assertEquals(eventId, session.joinedDiscoveredEventId)
        }
    }

}
