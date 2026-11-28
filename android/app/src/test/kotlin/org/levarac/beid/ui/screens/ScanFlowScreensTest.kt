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
import org.levarac.beid.ui.designsystem.SensingRadar
import org.levarac.beid.ui.theme.BeidAppTheme
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * Robolectric-backed Compose test — see android/README.md "Testing" for why
 * this runs as a JVM `:app:testDebugUnitTest` test instead of an
 * instrumented `androidTest`.
 */
@RunWith(RobolectricTestRunner::class)
// Phone height: these render a phase screen with no scroll container, and the
// Recording / EventFound screens now carry the radar (beid#722).
@Config(sdk = [34], qualifiers = "w411dp-h1000dp")
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
    }

    /**
     * PR #928 review: the radar drops a peer after 300 s of silence, so it
     * must say so on screen, not only in the TalkBack summary. iOS
     * release/1.1.0 `SensingSessionSurface` puts "HEARD IN THE LAST 5
     * MINUTES" directly below `SensingRadarView` (DESIGN.md: "with the
     * caption \"HEARD IN THE LAST 5 MINUTES\" below the radar").
     */
    @Test
    fun eventFoundScreenCaptionsTheRadarTimeWindowBelowIt() {
        composeTestRule.setContent {
            BeidAppTheme { EventFoundScreen(session) }
        }

        assertRadarCaptionBelowRadar()
    }

    @Test
    fun recordingScreenCaptionsTheRadarTimeWindowBelowIt() {
        composeTestRule.setContent {
            BeidAppTheme {
                RecordingScreen(
                    session = session,
                    peersVerified = 3,
                    showEntranceCeremony = false,
                    onCeremonyFinished = {},
                    onSimulateSignalLost = {},
                )
            }
        }
        composeTestRule.waitForIdle()

        assertRadarCaptionBelowRadar()
    }

    private fun assertRadarCaptionBelowRadar() {
        val caption = composeTestRule.onNodeWithText(RADAR_CAPTION)
        caption.assertIsDisplayed()
        val radarBounds = composeTestRule.onNodeWithTag(SensingRadar.TEST_TAG).fetchSemanticsNode().boundsInRoot
        val captionBounds = caption.fetchSemanticsNode().boundsInRoot
        assertTrue(
            captionBounds.top >= radarBounds.bottom,
            "caption $captionBounds must sit below the radar $radarBounds",
        )
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
    fun recordingScreenOmitsSimulateSignalLostButtonByDefault() {
        composeTestRule.setContent {
            BeidAppTheme {
                RecordingScreen(
                    session = session,
                    peersVerified = 1,
                    showEntranceCeremony = false,
                    onCeremonyFinished = {},
                    onSimulateSignalLost = {},
                )
            }
        }

        composeTestRule.onNodeWithTag(EventJoinScreenTestTags.PEERS_VERIFIED_ROW).assertIsDisplayed()
        composeTestRule.onNodeWithTag(EventJoinScreenTestTags.SIMULATE_SIGNAL_LOST_BUTTON).assertDoesNotExist()
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
                    showSimulateSignalLost = true,
                    onSimulateSignalLost = { simulated = true },
                )
            }
        }

        composeTestRule.onNodeWithTag(EventJoinScreenTestTags.SIMULATE_SIGNAL_LOST_BUTTON).performClick()
        assertTrue(simulated)
    }

    @Test
    fun recordingScreenWalletButtonInvokesProductionCallerCallback() {
        var walletBindingStarted = false
        composeTestRule.setContent {
            BeidAppTheme {
                RecordingScreen(
                    session = session,
                    peersVerified = 1,
                    showEntranceCeremony = false,
                    onCeremonyFinished = {},
                    onSimulateSignalLost = {},
                    onStartWalletBinding = { walletBindingStarted = true },
                )
            }
        }

        composeTestRule.onNodeWithTag(EventJoinScreenTestTags.BIND_WALLET_BUTTON).performClick()
        assertTrue(walletBindingStarted)
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

    // beid#389: literal copy per phase, so a resource edit that brings back a
    // proof claim or an "automatically" promise fails here instead of
    // passing through getString.

    @Test
    fun sensingScreenShowsObservationScopedCopy() {
        composeTestRule.setContent {
            BeidAppTheme { SensingScreen() }
        }

        composeTestRule.onNodeWithText(SENSING_PILL).assertIsDisplayed()
        composeTestRule.onNodeWithText("Looking for a nearby event").assertIsDisplayed()
        composeTestRule.onNodeWithText(
            "Keep beid open at the venue. Your event appears here when beid hears it nearby.",
        ).assertIsDisplayed()
        composeTestRule.assertNoForbiddenObservationCopy()
    }

    @Test
    fun eventFoundScreenShowsObservationScopedCopy() {
        composeTestRule.setContent {
            BeidAppTheme { EventFoundScreen(session) }
        }

        composeTestRule.onNodeWithText("Event Found").assertIsDisplayed()
        composeTestRule.onNodeWithText("Keep beid open and stay nearby.").assertIsDisplayed()
        composeTestRule.onNodeWithText("Checking event details").assertIsDisplayed()
        composeTestRule.assertNoForbiddenObservationCopy()
    }

    @Test
    fun recordingCeremonySaysRecordingStartedWithoutClaimingARecord() {
        composeTestRule.mainClock.autoAdvance = false
        composeTestRule.setContent {
            BeidAppTheme {
                RecordingScreen(
                    session = session,
                    peersVerified = 0,
                    showEntranceCeremony = true,
                    onCeremonyFinished = {},
                    onSimulateSignalLost = {},
                    ceremonyDwellMillis = 1000,
                )
            }
        }
        composeTestRule.mainClock.advanceTimeByFrame()

        composeTestRule.onNodeWithText("Recording started").assertIsDisplayed()
        composeTestRule.onNodeWithText("Stop sensing when you are done to keep your Record.").assertIsDisplayed()
        composeTestRule.onNodeWithText("Proof Collected").assertDoesNotExist()
        composeTestRule.onNodeWithText("Added to your collection.").assertDoesNotExist()
        composeTestRule.assertNoForbiddenObservationCopy()
    }

    @Test
    fun recordingScreenShowsObservationScopedCopy() {
        composeTestRule.setContent {
            BeidAppTheme {
                RecordingScreen(
                    session = session,
                    peersVerified = 4,
                    showEntranceCeremony = false,
                    onCeremonyFinished = {},
                    onSimulateSignalLost = {},
                )
            }
        }
        composeTestRule.waitForIdle()

        composeTestRule.onNodeWithText(SENSING_PILL).assertIsDisplayed()
        composeTestRule.onNodeWithText("Recording your participation").assertIsDisplayed()
        composeTestRule.onNodeWithText(
            "Keep the app open nearby to help devices observe each other and keep signed records.",
        ).assertIsDisplayed()
        composeTestRule.assertNoForbiddenObservationCopy()
    }

    @Test
    fun signalLostScreenAsksForResumeInsteadOfPromisingAutomaticRecovery() {
        composeTestRule.setContent {
            BeidAppTheme {
                SignalLostScreen(session = session, peersVerified = 5, onResumeSensing = {})
            }
        }

        composeTestRule.onNodeWithText("Signal Lost").assertIsDisplayed()
        composeTestRule.onNodeWithText("beid lost the connection to ABC123. Move closer, then tap Resume.")
            .assertIsDisplayed()
        composeTestRule.onNodeWithText("Your progress is saved. Resume continues this session.").assertIsDisplayed()
        composeTestRule.onNodeWithText("Sensing paused").assertIsDisplayed()
        composeTestRule.onNodeWithText("Resume").assertIsDisplayed()
        composeTestRule.assertNoForbiddenObservationCopy()
    }

    private companion object {
        /** `event_join_status_pill_active`, the active status pill on Sensing and Recording. */
        const val SENSING_PILL = "Sensing nearby devices"

        /** iOS release/1.1.0 `Localizable.xcstrings` key and value, as drawn (labelMono11 is uppercase). */
        const val RADAR_CAPTION = "HEARD IN THE LAST 5 MINUTES"
    }
}
