package org.levarac.beid.ui.screens

import android.content.Context
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.assertHasClickAction
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.assertIsNotSelected
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
import org.levarac.beid.scenario.AndroidDemoScenario
import org.levarac.beid.scenario.snapshot
import org.levarac.beid.sensing.EventJoinUiState
import org.levarac.beid.sensing.NearbyEventCard
import org.levarac.beid.sensing.ScanEventSession
import org.levarac.beid.sensing.ScanPhase
import org.levarac.beid.shared.event.EventJoinFailureReason
import org.levarac.beid.shared.event.NearbyEventSearchOutcome
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
    fun ownerKeyFailureExplainsPreservationAndKeepsExistingCardRetryEnabled() {
        val hash = "1111111111111111"
        var joinedHash: String? = null
        composeTestRule.setContent {
            BeidAppTheme {
                EventJoinContent(
                    state = EventJoinScreenState(
                        sessionState = EventJoinUiState.OwnerKeyUnavailable(org.levarac.beid.sensing.OwnerKeyStorageFailure.TEMPORARILY_UNAVAILABLE),
                        nearbyEventCards = listOf(NearbyEventCard("Verified beacon", "0x0123456789abcdef", 100L, 200L, hash)),
                    ),
                    onOpenAccount = {},
                    onJoinNearbyEvent = { joinedHash = it },
                    onOpenSettings = {},
                    onSimulateSignalLost = {},
                    onResumeSensing = {},
                )
            }
        }
        val context = ApplicationProvider.getApplicationContext<Context>()
        composeTestRule.onNodeWithText(context.getString(R.string.event_join_owner_key_unavailable)).assertIsDisplayed()
        composeTestRule.onNodeWithTag(EventJoinScreenTestTags.nearbyEventCard(hash)).assertIsEnabled().performClick()
        assertEquals(hash, joinedHash)
    }

    @Test
    fun directScenarioInjectionRendersWithoutAnEventJoinCoordinator() {
        val snapshot = AndroidDemoScenario.CrowdSurge.snapshot()

        composeTestRule.setContent {
            BeidAppTheme {
                EventJoinContent(
                    state = snapshot.eventJoinScreenState,
                    onOpenAccount = {},
                    onJoinNearbyEvent = {},
                    onOpenSettings = {},
                    onSimulateSignalLost = {},
                    onResumeSensing = {},
                )
            }
        }

        composeTestRule.onNodeWithText("40").assertIsDisplayed()
    }

    /**
     * beid#363: the scenario/preview path renders the same nearby-event card
     * list production does, including leaving an unverified candidate
     * disabled. Drives [EventJoinContent] with a hand-built state rather
     * than an [EventJoinViewModel], which is exactly what a DEBUG
     * launch-argument scenario and a Compose preview do.
     */
    @Test
    fun scenarioPathRendersNearbyEventCardsAndLeavesTheUnverifiedCardDisabled() {
        val verifiedHash = "1111111111111111"
        val unverifiedHash = "2222222222222222"
        var joinedHash: String? = null
        val state = EventJoinScreenState(
            sessionState = EventJoinUiState.Idle,
            nearbyEventCards = listOf(
                NearbyEventCard("Verified beacon", "0x0123456789abcdef", 100L, 200L, verifiedHash),
                NearbyEventCard("Unverified beacon", null, null, null, unverifiedHash),
            ),
            selectedNearbyEventHashHex = verifiedHash,
        )

        composeTestRule.setContent {
            BeidAppTheme {
                EventJoinContent(
                    state = state,
                    onOpenAccount = {},
                    onJoinNearbyEvent = { joinedHash = it },
                    onOpenSettings = {},
                    onSimulateSignalLost = {},
                    onResumeSensing = {},
                )
            }
        }

        val context = ApplicationProvider.getApplicationContext<Context>()
        composeTestRule.onNodeWithTag(EventJoinScreenTestTags.NEARBY_EVENT_LIST).assertIsDisplayed()
        composeTestRule.onNodeWithText("Verified beacon").assertIsDisplayed()
        composeTestRule.onNodeWithText("Unverified beacon").assertIsDisplayed()
        composeTestRule.onNodeWithText(context.getString(R.string.event_join_not_joinable_yet)).assertIsDisplayed()

        composeTestRule.onNodeWithTag(EventJoinScreenTestTags.nearbyEventCard(verifiedHash))
            .assertIsEnabled()
            .assertIsSelected()

        composeTestRule.onNodeWithTag(EventJoinScreenTestTags.nearbyEventCard(unverifiedHash))
            .assertIsDisplayed()
            .assertIsNotEnabled()
            .assertIsNotSelected()
            .performClick()
        composeTestRule.runOnIdle { assertNull(joinedHash) }
    }

    /**
     * beid#363: the legacy event-code text input is gone from the
     * scenario/preview path — an empty candidate list now shows production's
     * searching + rescue copy, not a second manual-entry surface.
     */
    @Test
    fun scenarioPathWithNoNearbyCandidatesShowsSearchingCopyAndNoEventCodeEntry() {
        composeTestRule.setContent {
            BeidAppTheme {
                EventJoinContent(
                    state = EventJoinScreenState(sessionState = EventJoinUiState.Idle),
                    onOpenAccount = {},
                    onJoinNearbyEvent = {},
                    onOpenSettings = {},
                    onSimulateSignalLost = {},
                    onResumeSensing = {},
                )
            }
        }

        val context = ApplicationProvider.getApplicationContext<Context>()
        composeTestRule.onNodeWithText(context.getString(R.string.event_join_searching_nearby)).assertIsDisplayed()
        composeTestRule.onNodeWithText(context.getString(R.string.event_join_rescue_guidance)).assertIsDisplayed()
        composeTestRule.onNodeWithText(context.getString(R.string.event_join_code_label)).assertDoesNotExist()
        composeTestRule.onNodeWithTag(EventJoinScreenTestTags.SUBMIT_BUTTON).assertDoesNotExist()
    }

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

    /**
     * Both strings are read from the catalog rather than written here as
     * literals (changed in beid#463). The assertion is the same one this test
     * has always made — that the searching state and its guidance are both on
     * screen — but pinning the English wording made it fail when that wording
     * was edited, which is a copy change, not a behaviour change. The wording
     * itself is the string catalog's business.
     */
    @Test
    fun zeroCandidatesShowsSearchingAndRescueWithoutManualEntry() {
        val viewModel = EventJoinViewModel(FakeEventJoinSession())
        composeTestRule.setContent { BeidAppTheme { EventJoinScreen(viewModel, onOpenAccount = {}, onOpenManualEventCode = {}) } }

        val context = ApplicationProvider.getApplicationContext<Context>()
        composeTestRule.onNodeWithText(context.getString(R.string.event_join_searching_nearby)).assertIsDisplayed()
        composeTestRule.onNodeWithText(context.getString(R.string.event_join_rescue_guidance)).assertIsDisplayed()
        composeTestRule.onNodeWithTag(EventJoinScreenTestTags.SUBMIT_BUTTON).assertDoesNotExist()
    }

    @Test
    fun sensingPhaseRendersItsOwnStatusTextAndNoPhaseDetailControls() {
        val session = FakeEventJoinSession(EventJoinUiState.Sensing(ScanPhase.Sensing))
        val viewModel = EventJoinViewModel(session)

        composeTestRule.setContent {
            BeidAppTheme {
                EventJoinScreen(viewModel, onOpenAccount = {}, onOpenManualEventCode = {})
            }
        }

        val context = ApplicationProvider.getApplicationContext<Context>()
        composeTestRule.onNodeWithText(context.getString(R.string.scan_sensing_message)).assertIsDisplayed()
        composeTestRule.onNodeWithTag(EventJoinScreenTestTags.PEERS_VERIFIED_ROW).assertDoesNotExist()
        composeTestRule.onNodeWithTag(EventJoinScreenTestTags.RESUME_BUTTON).assertDoesNotExist()
    }

    @Test
    fun eventFoundPhaseRendersItsOwnTitleAndMessage() {
        val session = FakeEventJoinSession(EventJoinUiState.Sensing(ScanPhase.EventFound(session1)))
        val viewModel = EventJoinViewModel(session)

        composeTestRule.setContent {
            BeidAppTheme {
                EventJoinScreen(viewModel, onOpenAccount = {}, onOpenManualEventCode = {})
            }
        }

        val context = ApplicationProvider.getApplicationContext<Context>()
        composeTestRule.onNodeWithText(context.getString(R.string.scan_event_found_title)).assertIsDisplayed()
        composeTestRule.onNodeWithText(context.getString(R.string.scan_event_found_message)).assertIsDisplayed()
    }

    @Test
    fun recordingPhaseRendersPeersVerifiedAndASimulateSignalLostControl() {
        val session = FakeEventJoinSession(EventJoinUiState.Sensing(ScanPhase.Recording(session1, peersVerified = 2)))
        // This test covers the Recording steady state; the entrance ceremony itself
        // (shown/skipped, dwell timing) is covered by ScanFlowScreensTest.
        session.markRecordingCeremonyShown()
        val viewModel = EventJoinViewModel(session)

        composeTestRule.setContent {
            BeidAppTheme {
                EventJoinScreen(viewModel, onOpenAccount = {}, onOpenManualEventCode = {})
            }
        }

        val context = ApplicationProvider.getApplicationContext<Context>()
        composeTestRule.onNodeWithText(context.getString(R.string.scan_recording_ceremony_title)).assertDoesNotExist()
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
                EventJoinScreen(viewModel, onOpenAccount = { accountOpened = true }, onOpenManualEventCode = {})
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
                EventJoinScreen(viewModel, onOpenAccount = {}, onOpenManualEventCode = {})
            }
        }

        val context = ApplicationProvider.getApplicationContext<Context>()
        composeTestRule.onNodeWithText(context.getString(R.string.scan_signal_lost_title)).assertIsDisplayed()
        composeTestRule.onNodeWithTag(EventJoinScreenTestTags.PEERS_VERIFIED_ROW).assertIsDisplayed()

        composeTestRule.onNodeWithTag(EventJoinScreenTestTags.RESUME_BUTTON)
            .performScrollTo()
            .assertIsDisplayed()
            .performClick()
        assertTrue(session.sensingResumed)
    }

    @Test
    fun oneVerifiedNearbyCandidateIsSelectedAndJoinsWithItsStableHash() {
        val eventId = "0x0123456789abcdef"
        val session = FakeEventJoinSession(
            nearbyEventCards = listOf(
                NearbyEventCard("Beacon name", eventId, 100L, 200L, "1111111111111111"),
            ),
        )
        val viewModel = EventJoinViewModel(session)

        composeTestRule.setContent {
            BeidAppTheme { EventJoinScreen(viewModel, onOpenAccount = {}, onOpenManualEventCode = {}) }
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
            // The card reports its stable hash; the Event ID it rendered is a
            // projection with no authority over the join (beid#374).
            assertEquals("1111111111111111", session.joinedNearbyEventCodeHashHex)
        }
    }

    @Test
    fun unverifiedNearbyCandidateIsDisplayOnlyAndCannotBecomeSelectedOrJoin() {
        val eventCodeHash = "1111111111111111"
        val session = FakeEventJoinSession(
            nearbyEventCards = listOf(
                NearbyEventCard("Unverified beacon", null, null, null, eventCodeHash),
            ),
        )
        val viewModel = EventJoinViewModel(session)

        composeTestRule.setContent { BeidAppTheme { EventJoinScreen(viewModel, onOpenAccount = {}, onOpenManualEventCode = {}) } }

        composeTestRule.onNodeWithTag(EventJoinScreenTestTags.nearbyEventCard(eventCodeHash))
            .assertIsDisplayed()
            .assertIsNotEnabled()
            .assertIsNotSelected()
            .performClick()
        composeTestRule.runOnIdle {
            assertNull(session.joinedNearbyEventCodeHashHex)
            assertNull(viewModel.uiState.value.selectedNearbyEventHashHex)
        }
    }

    /**
     * Before beid#336, a nearby card stayed visible-but-disabled during an
     * active Recording session, and this test tapped it to prove the tap
     * was a no-op. Since #336, [ScanFlowScreen] replaces the title +
     * [NearbyEventCards] entirely once a session reaches
     * [EventJoinUiState.Sensing], so a nearby card can no longer be shown
     * or tapped while a proof is active — there is nothing left to
     * (attempt to) retap. The underlying guarantee this test protected
     * (a stale nearby-card join cannot replace an active proof) is
     * covered independently, and more directly, by
     * `EventJoinCoordinatorHooksTest.staleJoinActionCannotReplaceAnActiveProofOrResetItsAccountingAndBinding`,
     * which exercises the coordinator without any UI involved.
     */
    @Test
    fun activeProofHidesNearbyEventCardsAndKeepsTheFirstJoin() {
        val firstEventId = "0x01"
        val secondEventId = "0x02"
        val session = FakeEventJoinSession(
            initial = EventJoinUiState.Sensing(ScanPhase.Recording(session1, peersVerified = 2)),
            nearbyEventCards = listOf(
                NearbyEventCard("Other beacon", secondEventId, 100L, 200L, "2222222222222222"),
            ),
        )
        session.joinNearbyEvent(firstEventId)
        session.markRecordingCeremonyShown()
        val viewModel = EventJoinViewModel(session)

        composeTestRule.setContent { BeidAppTheme { EventJoinScreen(viewModel, onOpenAccount = {}, onOpenManualEventCode = {}) } }

        composeTestRule.onNodeWithTag(EventJoinScreenTestTags.NEARBY_EVENT_LIST).assertDoesNotExist()
        composeTestRule.onNodeWithTag(EventJoinScreenTestTags.nearbyEventCard("2222222222222222")).assertDoesNotExist()
        composeTestRule.runOnIdle {
            assertEquals(firstEventId, session.joinedNearbyEventCodeHashHex)
        }
    }

    /**
     * beid#463 acceptance condition 1, at the surface: once the search has run
     * its course without finding anything joinable, the rescue route is on the
     * screen the participant is already looking at — not filed under Account,
     * which is where it was and where nobody stuck in a doorway would look.
     */
    @Test
    fun theRescueRouteAppearsOnceTheSearchFoundNothingJoinable() {
        var openedManualEventCode = 0
        composeTestRule.setContent {
            BeidAppTheme {
                EventJoinContent(
                    state = EventJoinScreenState(
                        sessionState = EventJoinUiState.Idle,
                        searchOutcome = NearbyEventSearchOutcome.RESCUE_ENTRY_OFFERED,
                    ),
                    onOpenAccount = {},
                    onOpenManualEventCode = { openedManualEventCode += 1 },
                    onJoinNearbyEvent = {},
                    onOpenSettings = {},
                    onSimulateSignalLost = {},
                    onResumeSensing = {},
                )
            }
        }

        composeTestRule.onNodeWithTag(EventJoinScreenTestTags.RESCUE_ENTRY_BUTTON)
            .performScrollTo()
            .assertIsDisplayed()
            .assertHasClickAction()
            .performClick()

        assertEquals(1, openedManualEventCode, "the rescue button must reach the event-code destination")
    }

    /**
     * The other side of the same condition, and the one that makes it a claim
     * rather than a decoration: while the search is still running the route is
     * not offered, so its appearance actually means something happened.
     */
    @Test
    fun theRescueRouteIsAbsentWhileTheSearchIsStillRunning() {
        composeTestRule.setContent {
            BeidAppTheme {
                EventJoinContent(
                    state = EventJoinScreenState(
                        sessionState = EventJoinUiState.Idle,
                        searchOutcome = NearbyEventSearchOutcome.SEARCHING,
                    ),
                    onOpenAccount = {},
                    onJoinNearbyEvent = {},
                    onOpenSettings = {},
                    onSimulateSignalLost = {},
                    onResumeSensing = {},
                )
            }
        }

        composeTestRule.onNodeWithTag(EventJoinScreenTestTags.RESCUE_ENTRY_BUTTON).assertDoesNotExist()
    }

    /**
     * A screen of candidates that cannot be joined is the same dead end as an
     * empty one, and it is the case an implementation keyed on "is the card
     * list empty" gets wrong — silently, because the screen looks busy.
     */
    @Test
    fun unjoinableCardsOnScreenDoNotHideTheRescueRoute() {
        composeTestRule.setContent {
            BeidAppTheme {
                EventJoinContent(
                    state = EventJoinScreenState(
                        sessionState = EventJoinUiState.Idle,
                        nearbyEventCards = listOf(
                            NearbyEventCard("Unnamed beacon nearby", null, null, null, "2222222222222222"),
                        ),
                        searchOutcome = NearbyEventSearchOutcome.RESCUE_ENTRY_OFFERED,
                    ),
                    onOpenAccount = {},
                    onJoinNearbyEvent = {},
                    onOpenSettings = {},
                    onSimulateSignalLost = {},
                    onResumeSensing = {},
                )
            }
        }

        composeTestRule.onNodeWithTag(EventJoinScreenTestTags.RESCUE_ENTRY_BUTTON)
            .performScrollTo()
            .assertIsDisplayed()
    }

    /**
     * beid#463 acceptance condition 3 at the surface. The expected copy is
     * read from the resource rather than written into the test: a test holding
     * its own copy of the sentence passes when production and the catalog have
     * drifted apart, which is the one thing it exists to catch.
     */
    @Test
    fun aNetworkRefusalSaysTheNetworkIsWhatFailed() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        composeTestRule.setContent {
            BeidAppTheme {
                ManualEventCodeContent(
                    state = EventJoinScreenState(
                        fieldError = EventJoinFieldError.JoinFailed(EventJoinFailureReason.NETWORK_REQUIRED),
                    ),
                    onEventCodeChanged = {},
                    onSubmit = {},
                )
            }
        }

        composeTestRule.onNodeWithTag(EventJoinScreenTestTags.FIELD_ERROR).assertIsDisplayed()
        composeTestRule
            .onNodeWithText(context.getString(R.string.event_join_error_network_required))
            .assertIsDisplayed()
    }

    /**
     * And the distinction that message exists to draw. A code that resolved to
     * a different event is not a network problem, and telling the participant
     * it is would send them to fix the wrong thing. Asserted as two different
     * strings rather than as one specific string, so it fails if the copy is
     * ever collapsed back into a single generic refusal.
     */
    @Test
    fun aCodeMismatchDoesNotReuseTheNetworkMessage() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val networkCopy = context.getString(R.string.event_join_error_network_required)
        val mismatchCopy = context.getString(R.string.event_join_error_code_mismatch)
        assertTrue(networkCopy != mismatchCopy, "a code mismatch and a dead network must not read alike")

        composeTestRule.setContent {
            BeidAppTheme {
                ManualEventCodeContent(
                    state = EventJoinScreenState(
                        fieldError = EventJoinFieldError.JoinFailed(EventJoinFailureReason.CODE_MISMATCH),
                    ),
                    onEventCodeChanged = {},
                    onSubmit = {},
                )
            }
        }

        composeTestRule.onNodeWithText(mismatchCopy).assertIsDisplayed()
        composeTestRule.onNodeWithText(networkCopy).assertDoesNotExist()
    }

    /**
     * beid#463 acceptance condition 2 at the surface: the affordance that makes
     * a 64-character code enterable exists and is wired. What it does with the
     * clipboard is asserted in `EventJoinViewModelTest`, where no Android
     * clipboard is needed to say it.
     */
    @Test
    fun theEventCodeScreenOffersPaste() {
        var pasteRequests = 0
        composeTestRule.setContent {
            BeidAppTheme {
                ManualEventCodeContent(
                    state = EventJoinScreenState(),
                    onEventCodeChanged = {},
                    onPasteEventCode = { pasteRequests += 1 },
                    onSubmit = {},
                )
            }
        }

        composeTestRule.onNodeWithTag(EventJoinScreenTestTags.PASTE_BUTTON)
            .assertIsDisplayed()
            .performClick()

        assertEquals(1, pasteRequests)
    }
}
