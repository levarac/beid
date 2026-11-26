package org.levarac.beid.ui.screens

import android.content.Context
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.width
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.assertHasClickAction
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import androidx.test.core.app.ApplicationProvider
import kotlin.test.assertNull
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import java.io.File
import org.junit.Rule
import org.junit.rules.TemporaryFolder
import org.junit.Test
import org.junit.runner.RunWith
import org.levarac.beid.R
import org.levarac.beid.scenario.AndroidDemoScenario
import org.levarac.beid.scenario.snapshot
import org.levarac.beid.persistence.ProofRecordStore
import org.levarac.beid.sensing.ClockPreflightController
import org.levarac.beid.sensing.EventJoinUiState
import org.levarac.beid.sensing.NearbyEventCard
import org.levarac.beid.sensing.NearbyEventCardVerification
import org.levarac.beid.sensing.ScanEventSession
import org.levarac.beid.sensing.ScanPhase
import org.levarac.beid.sensing.TrustedDateSource
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

    @get:Rule
    val tempFolder = TemporaryFolder()

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
        composeTestRule.onNodeWithText(context.getString(R.string.event_join_owner_key_unavailable))
            .performScrollTo().assertIsDisplayed()
        composeTestRule.onNodeWithTag(EventJoinScreenTestTags.nearbyEventJoin(hash))
            .performScrollTo().assertIsEnabled().performClick()
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
     * beid#363 + iOS #795: the scenario/preview path renders the same Now
     * candidates production does — the first under FOUND NEARBY, the rest
     * under ALSO NEARBY — and leaves an unverified candidate's JOIN disabled. Drives [EventJoinContent] with a hand-built state rather
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
        composeTestRule.onNodeWithTag(EventJoinScreenTestTags.NEARBY_EVENT_LIST).assertExists()
        composeTestRule.onNodeWithText(context.getString(R.string.now_found_nearby)).performScrollTo().assertIsDisplayed()
        composeTestRule.onNodeWithText("Verified beacon").performScrollTo().assertIsDisplayed()
        composeTestRule.onNodeWithText(context.getString(R.string.now_registration_checked)).performScrollTo().assertIsDisplayed()
        composeTestRule.onNodeWithTag(NowScreenTestTags.ALSO_NEARBY).performScrollTo().assertIsDisplayed()
        composeTestRule.onNodeWithText("Unverified beacon").performScrollTo().assertIsDisplayed()
        composeTestRule.onNodeWithText(context.getString(R.string.now_registration_checking).uppercase())
            .performScrollTo().assertIsDisplayed()

        // No card selects or joins on its own: the candidate itself is not a
        // control, and only its JOIN reports the stable hash.
        composeTestRule.onNodeWithTag(EventJoinScreenTestTags.nearbyEventCard(verifiedHash)).performClick()
        composeTestRule.runOnIdle { assertNull(joinedHash) }
        composeTestRule.onNodeWithTag(EventJoinScreenTestTags.nearbyEventJoin(unverifiedHash))
            .performScrollTo()
            .assertIsNotEnabled()
            .performClick()
        composeTestRule.runOnIdle { assertNull(joinedHash) }
        composeTestRule.onNodeWithTag(EventJoinScreenTestTags.nearbyEventJoin(verifiedHash))
            .performScrollTo()
            .assertIsEnabled()
            .assert(SemanticsMatcher.expectValue(SemanticsProperties.Role, Role.Button))
            .performClick()
        composeTestRule.runOnIdle { assertEquals(verifiedHash, joinedHash) }
    }

    /**
     * beid#584: a card that failed verification and a card whose read has not
     * returned yet must not read the same. Now uses iOS #795's "Checking event
     * registration…" for the pending case; the two failure states keep the
     * existing sentences, which iOS has no counterpart for. The Pixel held "Checking" and
     * "Waiting for event verification" for over an hour on a candidate whose
     * every registry read had failed, which is how a settled failure passed
     * for a slow success.
     */
    @Test
    fun eachNonJoinableVerificationStateGetsItsOwnCopy() {
        val checkingHash = "1111111111111111"
        val retryingHash = "2222222222222222"
        val unregisteredHash = "3333333333333333"
        val state = EventJoinScreenState(
            sessionState = EventJoinUiState.Idle,
            nearbyEventCards = listOf(
                NearbyEventCard(
                    beaconDisplayName = "Checking beacon",
                    eventCodeHashHex = checkingHash,
                    verification = NearbyEventCardVerification.CHECKING,
                ),
                NearbyEventCard(
                    beaconDisplayName = "Retrying beacon",
                    eventCodeHashHex = retryingHash,
                    verification = NearbyEventCardVerification.RETRYING,
                ),
                NearbyEventCard(
                    beaconDisplayName = "Unregistered beacon",
                    eventCodeHashHex = unregisteredHash,
                    verification = NearbyEventCardVerification.NOT_REGISTERED,
                ),
            ),
        )

        composeTestRule.setContent {
            BeidAppTheme {
                EventJoinContent(
                    state = state,
                    onOpenAccount = {},
                    onJoinNearbyEvent = {},
                    onOpenSettings = {},
                    onSimulateSignalLost = {},
                    onResumeSensing = {},
                )
            }
        }

        val context = ApplicationProvider.getApplicationContext<Context>()
        listOf(
            R.string.now_registration_checking,
            R.string.event_join_verification_retrying,
            R.string.event_join_verification_not_registered,
        ).forEach { copy ->
            // Label/Mono 10 is an uppercase Library style.
            composeTestRule.onNodeWithText(context.getString(copy).uppercase())
                .performScrollTo()
                .assertIsDisplayed()
        }

        // None of the three is joinable, so the failure copy never arrives
        // with an affordance that implies it is.
        listOf(checkingHash, retryingHash, unregisteredHash).forEach { hash ->
            composeTestRule.onNodeWithTag(EventJoinScreenTestTags.nearbyEventJoin(hash)).assertIsNotEnabled()
        }
    }

    @Test
    fun foundNearbyJoinStaysReachableAtNarrowWidthWithLargeText() {
        val hash = "1111111111111111"
        var joinedHash: String? = null
        composeTestRule.setContent {
            CompositionLocalProvider(LocalDensity provides Density(density = 1f, fontScale = 1.5f)) {
                BeidAppTheme {
                    Box(Modifier.width(320.dp)) {
                        EventJoinContent(
                            state = EventJoinScreenState(
                                nearbyEventCards = listOf(
                                    NearbyEventCard(
                                        beaconDisplayName = "A long nearby event name",
                                        eventIdHex = "0x01",
                                        eventCodeHashHex = hash,
                                    ),
                                ),
                            ),
                            onOpenAccount = {},
                            onJoinNearbyEvent = { joinedHash = it },
                            onOpenSettings = {},
                            onSimulateSignalLost = {},
                            onResumeSensing = {},
                        )
                    }
                }
            }
        }

        // Robolectric's default graphics mode does not measure glyph widths,
        // so a plain Text's width says nothing here; the status line is
        // asserted present and the JOIN target is asserted by its height.
        val context = ApplicationProvider.getApplicationContext<Context>()
        composeTestRule.onNodeWithText(context.getString(R.string.now_registration_checked))
            .performScrollTo()
            .assertIsDisplayed()
        val join = composeTestRule.onNodeWithTag(EventJoinScreenTestTags.nearbyEventJoin(hash))
            .performScrollTo()
            .assertIsDisplayed()
        assertTrue(join.fetchSemanticsNode().boundsInRoot.height >= 48f, "JOIN keeps a 48dp touch target")
        join.performClick()
        composeTestRule.runOnIdle { assertEquals(hash, joinedHash) }
    }

    /**
     * beid#363: the legacy event-code text input is gone from the
     * scenario/preview path — an empty candidate list shows Now's listening
     * strip and DO THIS NOW tile, not a manual-entry surface. The scenario
     * path has no standby gate, so it never offers ENTER EVENT CODE.
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
        composeTestRule.onNodeWithText(context.getString(R.string.home_now_title)).assertIsDisplayed()
        composeTestRule.onNodeWithText(context.getString(R.string.now_listening)).performScrollTo().assertIsDisplayed()
        composeTestRule.onNodeWithText(context.getString(R.string.now_standby_tile_title)).performScrollTo().assertIsDisplayed()
        composeTestRule.onNodeWithTag(NowScreenTestTags.ENTER_CODE).assertDoesNotExist()
        composeTestRule.onNodeWithText(context.getString(R.string.event_join_code_label)).assertDoesNotExist()
        composeTestRule.onNodeWithTag(EventJoinScreenTestTags.SUBMIT_BUTTON).assertDoesNotExist()
    }

    /** beid#464: if Home does not hand its controller to the ViewModel, opening Now never measures the clock. */
    @Test
    fun theRouteHandsTheClockPreflightToTheScreenSoOpeningItMeasures() {
        var fetches = 0
        val source = object : TrustedDateSource {
            override suspend fun fetchDateHeader(): String? {
                fetches += 1
                return "Wed, 16 Sep 2026 11:58:53 GMT"
            }
        }
        val controller = ClockPreflightController(
            source = source,
            wallMillis = { 1_789_559_933_000L },
            monotonicMillis = { 1_000L },
        )

        composeTestRule.setContent {
            BeidAppTheme {
                HomeRoute(
                    session = FakeEventJoinSession(),
                    proofRecordStore = ProofRecordStore(File(tempFolder.root, "records.json")),
                    onOpenAccount = {},
                    onOpenEventCodeEntry = {},
                    onOpenRecord = {},
                    onOpenToday = {},
                    onOpenByEvent = {},
                    clockPreflight = controller,
                )
            }
        }
        composeTestRule.waitForIdle()

        assertEquals(1, fetches)
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

    @Test
    fun manualEntryBackActionInvokesTheProvidedCallback() {
        var backCount = 0
        composeTestRule.setContent {
            BeidAppTheme {
                ManualEventCodeContent(
                    state = EventJoinScreenState(),
                    onEventCodeChanged = {},
                    onSubmit = {},
                    onBack = { backCount++ },
                )
            }
        }

        composeTestRule.onNodeWithTag(EventJoinScreenTestTags.MANUAL_BACK_BUTTON).performClick()
        assertEquals(1, backCount)
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
        composeTestRule.onNodeWithText(context.getString(R.string.now_listening)).performScrollTo().assertIsDisplayed()
        composeTestRule.onNodeWithText(context.getString(R.string.now_found_nearby)).assertDoesNotExist()
        composeTestRule.onNodeWithTag(EventJoinScreenTestTags.SUBMIT_BUTTON).assertDoesNotExist()
    }

    @Test
    fun accountActionUsesTheTopBarAndNearbyJoinableCandidateShowsActionCopy() {
        var accountOpened = 0
        val hash = "3333333333333333"
        composeTestRule.setContent {
            BeidAppTheme {
                EventJoinContent(
                    state = EventJoinScreenState(
                        nearbyEventCards = listOf(
                            NearbyEventCard("Verified beacon", "0x0123456789abcdef", 100L, 200L, hash),
                        ),
                    ),
                    onOpenAccount = { accountOpened++ },
                    onJoinNearbyEvent = {},
                    onOpenSettings = {},
                    onSimulateSignalLost = {},
                    onResumeSensing = {},
                )
            }
        }

        val context = ApplicationProvider.getApplicationContext<Context>()
        composeTestRule.onNodeWithTag(EventJoinScreenTestTags.ACCOUNT_ENTRY).performClick()
        assertEquals(1, accountOpened)
        composeTestRule.onNodeWithText(context.getString(R.string.now_registration_checked)).performScrollTo().assertIsDisplayed()
        composeTestRule.onNodeWithText(context.getString(R.string.now_join_action)).performScrollTo().assertIsDisplayed()
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
        composeTestRule.onNodeWithTag(EventJoinScreenTestTags.ACCOUNT_ENTRY).assertIsDisplayed()

        composeTestRule.onNodeWithTag(EventJoinScreenTestTags.SIMULATE_SIGNAL_LOST_BUTTON)
            .performScrollTo()
            .assertIsDisplayed()
            .performClick()
        assertTrue(session.signalLostSimulated)
    }

    // Pins only that the flag threads EventJoinScreen -> EventJoinContent ->
    // ScanFlowScreen -> RecordingScreen; unit tests run the debug variant, so
    // release behavior (BuildConfig.DEBUG = false) is not proven here (beid#651).
    @Test
    fun recordingPhaseOmitsSimulateSignalLostControlWhenDisabled() {
        val session = FakeEventJoinSession(EventJoinUiState.Sensing(ScanPhase.Recording(session1, peersVerified = 2)))
        session.markRecordingCeremonyShown()
        val viewModel = EventJoinViewModel(session)

        composeTestRule.setContent {
            BeidAppTheme {
                EventJoinScreen(
                    viewModel,
                    onOpenAccount = {},
                    onOpenManualEventCode = {},
                    showSimulateSignalLost = false,
                )
            }
        }

        composeTestRule.onNodeWithTag(EventJoinScreenTestTags.PEERS_VERIFIED_ROW).assertIsDisplayed()
        composeTestRule.onNodeWithTag(EventJoinScreenTestTags.SIMULATE_SIGNAL_LOST_BUTTON).assertDoesNotExist()
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

        // iOS #795: appearing is not joining. Nothing is joined until JOIN is tapped.
        composeTestRule.runOnIdle { assertNull(session.joinedNearbyEventCodeHashHex) }
        composeTestRule.onNodeWithTag(EventJoinScreenTestTags.nearbyEventJoin("1111111111111111"))
            .performScrollTo()
            .assertHasClickAction()
            .assert(SemanticsMatcher.expectValue(SemanticsProperties.Role, Role.Button))
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
            .performScrollTo()
            .assertIsDisplayed()
        composeTestRule.onNodeWithTag(EventJoinScreenTestTags.nearbyEventJoin(eventCodeHash))
            .performScrollTo()
            .assertIsNotEnabled()
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
     * iOS #795 replaces beid#463's in-list rescue offer on Now with the
     * standby gate's ENTER EVENT CODE (30 s with no candidate, see
     * `HomeStandbyViewModelTest`). The shared search outcome alone no longer
     * puts a code entry on Now.
     */
    @Test
    fun theSearchOutcomeAloneNoLongerPutsACodeEntryOnNow() {
        composeTestRule.setContent {
            BeidAppTheme {
                EventJoinContent(
                    state = EventJoinScreenState(
                        sessionState = EventJoinUiState.Idle,
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

        composeTestRule.onNodeWithTag(NowScreenTestTags.ENTER_CODE).assertDoesNotExist()
    }

    /**
     * While the search is still running, Now offers no event-code entry either:
     * only the standby gate's 30-second wait can put one there.
     */
    @Test
    fun noCodeEntryWhileTheSearchIsStillRunning() {
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

        composeTestRule.onNodeWithTag(NowScreenTestTags.ENTER_CODE).assertDoesNotExist()
    }

    /**
     * The screen alone never puts event-code entry on Now, even beside a card
     * whose JOIN is disabled and with the shared rescue outcome reached:
     * [EventJoinContent] renders no standby presentation, so the entry stays
     * the standby gate's decision. That gate ([org.levarac.beid.navigation.HomeStandbyViewModel])
     * counts joinable cards only, as iOS release/1.1.0 does, so on Home an
     * unjoinable card does not hold back the 30-second entry; that is covered
     * in `HomeStandbyViewModelTest`. Renamed from
     * `anUnjoinableCandidateOnNowOffersNoCodeEntry`, which read as if an
     * unjoinable card withheld Now's entry.
     */
    @Test
    fun theScreenAloneOffersNoCodeEntryBesideAnUnjoinableCandidate() {
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

        composeTestRule.onNodeWithTag(NowScreenTestTags.ENTER_CODE).assertDoesNotExist()
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

    /// beid#450 — Barnard dropped nearby events and the screen must say so.
    @Test
    fun omittedNearbyEventsAreAnnouncedAlongsideTheCards() {
        val state = EventJoinScreenState(
            sessionState = EventJoinUiState.Idle,
            nearbyEventCards = listOf(
                NearbyEventCard("Verified beacon", "0x0123456789abcdef", 100L, 200L, "1111111111111111"),
            ),
            nearbyEventsOmitted = true,
        )

        composeTestRule.setContent {
            BeidAppTheme {
                EventJoinContent(
                    state = state,
                    onOpenAccount = {},
                    onJoinNearbyEvent = {},
                    onOpenSettings = {},
                    onSimulateSignalLost = {},
                    onResumeSensing = {},
                )
            }
        }

        composeTestRule.onNodeWithTag(EventJoinScreenTestTags.NEARBY_EVENTS_OMITTED)
            .performScrollTo()
            .assertIsDisplayed()
    }

    /// The most misleading combination: nothing shown, and something dropped.
    @Test
    fun omittedNearbyEventsAreAnnouncedEvenWhenNoCardIsShown() {
        val state = EventJoinScreenState(
            sessionState = EventJoinUiState.Idle,
            nearbyEventCards = emptyList(),
            nearbyEventsOmitted = true,
        )

        composeTestRule.setContent {
            BeidAppTheme {
                EventJoinContent(
                    state = state,
                    onOpenAccount = {},
                    onJoinNearbyEvent = {},
                    onOpenSettings = {},
                    onSimulateSignalLost = {},
                    onResumeSensing = {},
                )
            }
        }

        composeTestRule.onNodeWithTag(EventJoinScreenTestTags.NEARBY_EVENTS_OMITTED)
            .performScrollTo()
            .assertIsDisplayed()
    }

    /// And stays absent when nothing was dropped, so the row means something.
    @Test
    fun noOmissionNoticeWhenNothingWasDropped() {
        val state = EventJoinScreenState(
            sessionState = EventJoinUiState.Idle,
            nearbyEventCards = listOf(
                NearbyEventCard("Verified beacon", "0x0123456789abcdef", 100L, 200L, "1111111111111111"),
            ),
            nearbyEventsOmitted = false,
        )

        composeTestRule.setContent {
            BeidAppTheme {
                EventJoinContent(
                    state = state,
                    onOpenAccount = {},
                    onJoinNearbyEvent = {},
                    onOpenSettings = {},
                    onSimulateSignalLost = {},
                    onResumeSensing = {},
                )
            }
        }

        composeTestRule.onNodeWithTag(EventJoinScreenTestTags.NEARBY_EVENTS_OMITTED)
            .assertDoesNotExist()
    }
}
