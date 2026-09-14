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
import org.levarac.beid.sensing.ScanEventSession
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
class ScanFlowScreensTest {
    @get:Rule
    val composeTestRule = createComposeRule()

    private val session = ScanEventSession(eventCode = "ABC123")

    private val context: Context
        get() = ApplicationProvider.getApplicationContext()

    @Test
    fun sensingScreenRendersItsStatusPillAndMessage() {
        composeTestRule.setContent {
            BeidAppTheme { SensingScreen() }
        }

        composeTestRule.onNodeWithTag(EventJoinScreenTestTags.PHASE_STATUS_PILL).assertIsDisplayed()
        composeTestRule.onNodeWithText(context.getString(R.string.scan_sensing_message)).assertIsDisplayed()
    }

    @Test
    fun eventFoundScreenRendersItsTitleAndMessage() {
        composeTestRule.setContent {
            BeidAppTheme { EventFoundScreen(session) }
        }

        composeTestRule.onNodeWithText(context.getString(R.string.scan_event_found_title)).assertIsDisplayed()
        composeTestRule.onNodeWithText(context.getString(R.string.scan_event_found_message)).assertIsDisplayed()
        composeTestRule.onNodeWithText(context.getString(R.string.scan_event_found_status)).assertIsDisplayed()
    }

    @Test
    fun signalLostScreenRendersPeersVerifiedAndResumeControl() {
        var resumed = false
        composeTestRule.setContent {
            BeidAppTheme {
                SignalLostScreen(session = session, peersVerified = 5, onResumeSensing = { resumed = true })
            }
        }

        composeTestRule.onNodeWithText(context.getString(R.string.scan_signal_lost_title)).assertIsDisplayed()
        composeTestRule.onNodeWithTag(EventJoinScreenTestTags.PEERS_VERIFIED_ROW).assertIsDisplayed()
        composeTestRule.onNodeWithText("5").assertIsDisplayed()

        composeTestRule.onNodeWithTag(EventJoinScreenTestTags.RESUME_BUTTON).performClick()
        assertTrue(resumed)
    }

    @Test
    fun recordingScreenShowsCeremonyThenTransitionsToSteadyStateAfterTheDwellAndMarksItShownImmediately() {
        var finished = false
        composeTestRule.mainClock.autoAdvance = false

        composeTestRule.setContent {
            BeidAppTheme {
                RecordingScreen(
                    session = session,
                    peersVerified = 2,
                    showEntranceCeremony = true,
                    onCeremonyFinished = { finished = true },
                    onSimulateSignalLost = {},
                    ceremonyDwellMillis = 1000,
                )
            }
        }
        composeTestRule.mainClock.advanceTimeByFrame()

        // The ceremony must be marked shown immediately, not only after the dwell —
        // otherwise a session ending mid-ceremony would replay it next time.
        assertTrue(finished, "onCeremonyFinished must fire immediately, before the dwell elapses")
        composeTestRule.onNodeWithText(context.getString(R.string.scan_recording_ceremony_title)).assertIsDisplayed()
        composeTestRule.onNodeWithTag(EventJoinScreenTestTags.PEERS_VERIFIED_ROW).assertDoesNotExist()

        composeTestRule.mainClock.advanceTimeBy(1500)
        composeTestRule.waitForIdle()

        composeTestRule.onNodeWithText(context.getString(R.string.scan_recording_ceremony_title)).assertDoesNotExist()
        composeTestRule.onNodeWithTag(EventJoinScreenTestTags.PEERS_VERIFIED_ROW).assertIsDisplayed()
        composeTestRule.onNodeWithText("2").assertIsDisplayed()
    }

    @Test
    fun recordingScreenSkipsTheCeremonyEntirelyWhenAlreadyShown() {
        var finished = false
        composeTestRule.setContent {
            BeidAppTheme {
                RecordingScreen(
                    session = session,
                    peersVerified = 9,
                    showEntranceCeremony = false,
                    onCeremonyFinished = { finished = true },
                    onSimulateSignalLost = {},
                )
            }
        }
        composeTestRule.waitForIdle()

        assertTrue(finished)
        composeTestRule.onNodeWithText(context.getString(R.string.scan_recording_ceremony_title)).assertDoesNotExist()
        composeTestRule.onNodeWithTag(EventJoinScreenTestTags.PEERS_VERIFIED_ROW).assertIsDisplayed()
        composeTestRule.onNodeWithText("9").assertIsDisplayed()
    }

    @Test
    fun recordingScreenSimulateSignalLostButtonInvokesCallback() {
        var simulated = false
        composeTestRule.setContent {
            BeidAppTheme {
                RecordingScreen(
                    session = session,
                    peersVerified = 1,
                    showEntranceCeremony = false,
                    onCeremonyFinished = {},
                    onSimulateSignalLost = { simulated = true },
                )
            }
        }

        composeTestRule.onNodeWithTag(EventJoinScreenTestTags.SIMULATE_SIGNAL_LOST_BUTTON).performClick()
        assertTrue(simulated)
    }

    @Test
    fun scanFlowScreenRoutesIdleAndSensingToTheSameSensingScreen() {
        composeTestRule.setContent {
            BeidAppTheme {
                ScanFlowScreen(
                    phase = org.levarac.beid.sensing.ScanPhase.Sensing,
                    showEntranceCeremony = false,
                    onCeremonyFinished = {},
                    onSimulateSignalLost = {},
                    onResumeSensing = {},
                )
            }
        }

        composeTestRule.onNodeWithText(context.getString(R.string.scan_sensing_message)).assertIsDisplayed()
    }
}
