package org.levarac.beid.navigation

import android.bluetooth.BluetoothAdapter
import android.content.Context
import android.content.Intent
import android.os.Looper
import androidx.activity.ComponentActivity
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsSelected
import androidx.compose.ui.test.SemanticsNodeInteraction
import androidx.compose.ui.test.hasScrollToKeyAction
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.performScrollToKey
import androidx.compose.ui.test.isHeading
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.unit.Density
import androidx.test.core.app.ApplicationProvider
import java.io.File
import java.time.Duration
import java.time.Instant
import java.util.UUID
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith
import org.levarac.beid.R
import org.levarac.beid.onboarding.OnboardingPreferences
import org.levarac.beid.persistence.ProofRecord
import org.levarac.beid.persistence.ProofRecordStore
import org.levarac.beid.sensing.EventJoinUiState
import org.levarac.beid.sensing.NearbyEventCard
import org.levarac.beid.sensing.ScanPhase
import org.levarac.beid.ui.screens.AccountScreenTestTags
import org.levarac.beid.ui.screens.EventJoinScreenTestTags
import org.levarac.beid.ui.screens.FakeEventJoinSession
import org.levarac.beid.ui.screens.HomeScreenTestTags
import org.levarac.beid.ui.screens.NowScreenTestTags
import org.levarac.beid.ui.screens.RecordDetailScreenTestTags
import org.levarac.beid.ui.screens.RecordsHomeScreenTestTags
import org.levarac.beid.ui.screens.TodaySummaryScreenTestTags
import org.levarac.beid.ui.screens.recordDateFormatter
import org.levarac.beid.ui.screens.RecordsScreenTestTags
import org.levarac.beid.ui.theme.BeidAppTheme
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowLooper

/**
 * Drives the production graph for Home's Now / Records shell (iOS #795): no
 * radio, registry or alternate Home renderer. Robolectric's paused main
 * looper shadows `SystemClock.uptimeMillis()`, so [idleFor] moves both the
 * standby wait's clock and its ticker — virtual time, at the screen level.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class CollectionHomeTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()
    @get:Rule val folder = TemporaryFolder()
    private val context: Context get() = ApplicationProvider.getApplicationContext()
    private lateinit var store: ProofRecordStore
    private val card = NearbyEventCard("Nearby gathering", eventIdHex = "ab".repeat(16),
        eventCodeHashHex = "cd".repeat(8))
    private val second = NearbyEventCard("Second gathering", eventIdHex = "ef".repeat(16),
        eventCodeHashHex = "12".repeat(8))

    @Before fun prepare() {
        OnboardingPreferences(context).hasCompletedOnboarding = true
        shadowOf(BluetoothAdapter.getDefaultAdapter()).setEnabled(true)
        store = ProofRecordStore(File(folder.root, "records.json"))
    }

    private fun launch(session: FakeEventJoinSession = FakeEventJoinSession(nearbyEventCards = listOf(card)),
        fontScale: Float = 1f) {
        compose.setContent {
            CompositionLocalProvider(LocalDensity provides Density(LocalDensity.current.density, fontScale)) {
                BeidAppTheme { AppNavHost(session, store) }
            }
        }
    }

    /** The radio broadcast `AppNavHost`'s `BluetoothStateMonitor` follows. */
    private fun radioOff() {
        shadowOf(BluetoothAdapter.getDefaultAdapter()).setEnabled(false)
        context.sendBroadcast(
            Intent(BluetoothAdapter.ACTION_STATE_CHANGED).putExtra(BluetoothAdapter.EXTRA_STATE, BluetoothAdapter.STATE_OFF),
        )
        ShadowLooper.idleMainLooper()
        compose.waitForIdle()
    }

    private fun back() = compose.runOnUiThread { compose.activity.onBackPressedDispatcher.onBackPressed() }
    private fun home() = compose.onNodeWithTag(HomeScreenTestTags.ROOT).assertIsDisplayed()
    /** Settles the last interaction first, so its effects start the wait before the clock jumps. */
    private fun idleFor(seconds: Long) {
        compose.waitForIdle()
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofSeconds(seconds))
        compose.waitForIdle()
    }
    private fun codeEntry() = compose.onNodeWithTag(NowScreenTestTags.ENTER_CODE)

    @Test fun launchLandsOnNowAndStartsOnlyDiscovery() {
        val session = FakeEventJoinSession(nearbyEventCards = listOf(card))
        launch(session)
        home()
        compose.onNodeWithTag(HomeScreenTestTags.NOW_TAB).assertIsSelected()
        compose.onNodeWithTag(NowScreenTestTags.TITLE).assertIsDisplayed()
        compose.onNodeWithTag(EventJoinScreenTestTags.nearbyEventCard(card.eventCodeHashHex))
            .performScrollTo().assertIsDisplayed()
        assertEquals(1, session.nearbyEventDiscoveryStartCalls)
        assertNull(session.joinedNearbyEventCodeHashHex, "Appearing never joins")
    }

    @Test fun aCandidateJoinsOnlyThroughItsJoinTap() {
        val session = FakeEventJoinSession(nearbyEventCards = listOf(card, second))
        launch(session)
        compose.onNodeWithTag(EventJoinScreenTestTags.nearbyEventCard(card.eventCodeHashHex))
            .performScrollTo().performClick()
        assertNull(session.joinedNearbyEventCodeHashHex)
        compose.onNodeWithTag(NowScreenTestTags.ALSO_NEARBY).performScrollTo().assertIsDisplayed()
        compose.onNodeWithTag(EventJoinScreenTestTags.nearbyEventJoin(second.eventCodeHashHex))
            .performScrollTo().performClick()
        assertEquals(second.eventCodeHashHex, session.joinedNearbyEventCodeHashHex)
        session.clearJoinedNearbyEvent()
        compose.onNodeWithTag(EventJoinScreenTestTags.nearbyEventJoin(card.eventCodeHashHex))
            .performScrollTo().performClick()
        assertEquals(card.eventCodeHashHex, session.joinedNearbyEventCodeHashHex)
        assertNull(session.joinedCode)
    }

    @Test fun recordsTabStopsDiscoveryAndNowRestartsIt() {
        val session = FakeEventJoinSession()
        launch(session)
        compose.onNodeWithTag(HomeScreenTestTags.RECORDS_TAB).performClick()
        compose.onNodeWithTag(RecordsHomeScreenTestTags.ROOT).assertIsDisplayed()
        compose.onNodeWithTag(NowScreenTestTags.ROOT).assertDoesNotExist()
        compose.onNodeWithTag(EventJoinScreenTestTags.ACCOUNT_ENTRY).assertIsDisplayed()
        assertEquals(1, session.nearbyEventDiscoveryStopCalls)
        compose.onNodeWithTag(HomeScreenTestTags.NOW_TAB).performClick()
        compose.onNodeWithTag(NowScreenTestTags.ROOT).assertIsDisplayed()
        assertEquals(2, session.nearbyEventDiscoveryStartCalls)
    }

    @Test fun accountFromTheTopBarPausesDiscoveryAndStillReachesRecordsAndCodeEntry() {
        val first = ProofRecord(UUID.randomUUID(), "first", Instant.ofEpochSecond(10), 3).also(store::add)
        val session = FakeEventJoinSession()
        launch(session)
        compose.onNodeWithContentDescription(context.getString(R.string.home_account_title))
            .assertIsDisplayed().performClick()
        compose.onNodeWithTag(AccountScreenTestTags.RECORDS_BUTTON).assertIsDisplayed()
        assertEquals(1, session.nearbyEventDiscoveryStopCalls)
        compose.onNodeWithTag(AccountScreenTestTags.RECORDS_BUTTON).performScrollTo().performClick()
        compose.onNodeWithTag(RecordsScreenTestTags.recordRow(first.id)).assertIsDisplayed()
        back()
        compose.onNodeWithTag(AccountScreenTestTags.MANUAL_EVENT_CODE_BUTTON).performScrollTo().performClick()
        compose.onNodeWithTag(EventJoinScreenTestTags.SUBMIT_BUTTON).assertIsDisplayed()
        back()
        back()
        home()
        assertEquals(2, session.nearbyEventDiscoveryStartCalls)
    }

    @Test fun codeEntryAppearsAtThirtySecondsNotTwentyNine() {
        launch(FakeEventJoinSession())
        home()
        codeEntry().assertDoesNotExist()
        idleFor(29)
        codeEntry().assertDoesNotExist()
        compose.onNodeWithTag(NowScreenTestTags.LISTENING_ELAPSED).assertIsDisplayed()
        compose.onNodeWithText("0:29").assertIsDisplayed()
        idleFor(1)
        codeEntry().performScrollTo().assertIsDisplayed()
        compose.onNodeWithText("0:30").assertIsDisplayed()
    }

    @Test fun switchingTabsResetsTheWait() {
        launch(FakeEventJoinSession())
        idleFor(29)
        compose.onNodeWithTag(HomeScreenTestTags.RECORDS_TAB).performClick()
        idleFor(5)
        compose.onNodeWithTag(HomeScreenTestTags.NOW_TAB).performClick()
        idleFor(29)
        // 29 + 5 + 29 s on Home: without the reset the entry would be here.
        codeEntry().assertDoesNotExist()
        idleFor(1)
        codeEntry().performScrollTo().assertIsDisplayed()
    }

    @Test fun aCandidateAppearingWithdrawsTheEntryAndResetsTheWait() {
        val session = FakeEventJoinSession()
        launch(session)
        idleFor(30)
        codeEntry().performScrollTo().assertIsDisplayed()
        compose.runOnIdle { session.emitNearbyEventCards(listOf(card)) }
        codeEntry().assertDoesNotExist()
        compose.runOnIdle { session.emitNearbyEventCards(emptyList()) }
        idleFor(29)
        codeEntry().assertDoesNotExist()
        idleFor(1)
        codeEntry().performScrollTo().assertIsDisplayed()
    }

    /** iOS `joinEventFromHomeResolvingCanonicalId`: a code that starts sensing returns to Now. */
    @Test fun nowCodeEntrySubmitsThroughTheExistingFlowAndReturnsToNowOnceSensing() {
        val session = FakeEventJoinSession()
        launch(session)
        idleFor(30)
        codeEntry().performScrollTo().performClick()
        compose.onNodeWithTag(EventJoinScreenTestTags.PASTE_BUTTON).assertIsDisplayed()
        compose.runOnIdle {
            context.getSystemService(android.content.ClipboardManager::class.java)
                .setPrimaryClip(android.content.ClipData.newPlainText("code", "sample-event"))
        }
        compose.onNodeWithTag(EventJoinScreenTestTags.PASTE_BUTTON).performClick()
        compose.onNodeWithTag(EventJoinScreenTestTags.SUBMIT_BUTTON).performClick()
        assertEquals("sample-event", session.joinedCode)
        compose.runOnIdle { session.emit(EventJoinUiState.Sensing(ScanPhase.Sensing)) }
        home()
        compose.onNodeWithTag(EventJoinScreenTestTags.PHASE_STATUS_PILL).assertIsDisplayed()
        compose.onNodeWithText(context.getString(R.string.scan_close)).assertIsDisplayed()
    }

    @Test fun anActiveSessionKeepsItsScreensOnNowAndCloseReturnsToDiscovery() {
        val session = FakeEventJoinSession(EventJoinUiState.Sensing(ScanPhase.Sensing))
        launch(session)
        compose.onNodeWithTag(EventJoinScreenTestTags.PHASE_STATUS_PILL).assertIsDisplayed()
        compose.onNodeWithTag(NowScreenTestTags.LISTENING).assertDoesNotExist()
        assertEquals(0, session.nearbyEventDiscoveryStartCalls)
        compose.onNodeWithText(context.getString(R.string.scan_close)).performClick()
        assertEquals(1, session.leaveEventCallCount)
        compose.runOnIdle { session.emit(EventJoinUiState.Idle) }
        compose.onNodeWithTag(NowScreenTestTags.LISTENING).assertIsDisplayed()
        assertEquals(1, session.nearbyEventDiscoveryStartCalls)
    }

    @Test fun bluetoothOffReplacesDiscoveryAtRestAndClosesTheGate() {
        val session = FakeEventJoinSession(nearbyEventCards = listOf(card))
        launch(session)
        home()
        assertEquals(1, session.nearbyEventDiscoveryStartCalls)
        radioOff()
        compose.onNodeWithTag(NowScreenTestTags.BLUETOOTH_OFF).performScrollTo().assertIsDisplayed()
        compose.onNodeWithText(context.getString(R.string.now_bluetooth_off_label)).assertIsDisplayed()
        compose.onNodeWithText(context.getString(R.string.now_bluetooth_off_tile_title)).performScrollTo().assertIsDisplayed()
        compose.onNodeWithTag(NowScreenTestTags.LISTENING).assertDoesNotExist()
        compose.onNodeWithTag(EventJoinScreenTestTags.nearbyEventCard(card.eventCodeHashHex)).assertDoesNotExist()
        assertEquals(1, session.nearbyEventDiscoveryStopCalls)
        idleFor(60)
        codeEntry().assertDoesNotExist()
        assertEquals(1, session.nearbyEventDiscoveryStartCalls, "a closed gate starts nothing")
    }

    /** Home recomposes on return with the radio already off: the gate never opens, even briefly. */
    @Test fun radioOffWhileOnAccountReturnsToAClosedGate() {
        val session = FakeEventJoinSession()
        launch(session)
        compose.onNodeWithContentDescription(context.getString(R.string.home_account_title)).performClick()
        compose.onNodeWithTag(AccountScreenTestTags.RECORDS_BUTTON).assertIsDisplayed()
        assertEquals(1, session.nearbyEventDiscoveryStopCalls)

        radioOff()
        back()

        compose.onNodeWithTag(NowScreenTestTags.BLUETOOTH_OFF).performScrollTo().assertIsDisplayed()
        assertEquals(1, session.nearbyEventDiscoveryStartCalls, "no start for a gate that is closed by the radio")
        assertEquals(1, session.nearbyEventDiscoveryStopCalls)
    }

    @Test fun bluetoothOffSitsAboveAnActiveSession() {
        val session = FakeEventJoinSession(EventJoinUiState.Sensing(ScanPhase.Sensing))
        launch(session)
        radioOff()
        compose.onNodeWithTag(NowScreenTestTags.BLUETOOTH_OFF).assertIsDisplayed()
        compose.onNodeWithTag(EventJoinScreenTestTags.PHASE_STATUS_PILL).performScrollTo().assertIsDisplayed()
        val blockY = compose.onNodeWithTag(NowScreenTestTags.BLUETOOTH_OFF).fetchSemanticsNode().positionInRoot.y
        val pillY = compose.onNodeWithTag(EventJoinScreenTestTags.PHASE_STATUS_PILL).fetchSemanticsNode().positionInRoot.y
        assertTrue(blockY < pillY, "The block sits above the session: $blockY vs $pillY")
        assertEquals(0, session.leaveEventCallCount, "the radio never ends a joined session")
        assertEquals(0, session.nearbyEventDiscoveryStopCalls)
    }

    /** Same fixture as the render tests: three events, "Design review" with three sessions. */
    private fun seedCollection(): List<ProofRecord> = listOf(
        seeded(1, "morning-meetup", "2026-10-24T09:30:00Z", "Morning meetup", 8),
        seeded(2, "design-review", "2026-10-23T15:45:00Z", "Design review", 6),
        seeded(3, " DESIGN-REVIEW ", "2026-10-23T14:30:00Z", "Design review", 4),
        seeded(4, "design-review", "2026-10-23T13:00:00Z", "Design review", 3),
        seeded(5, "community-workshop", "2026-10-21T11:00:00Z", "Community workshop", 12),
    )

    private fun seeded(index: Int, code: String, date: String, name: String, peers: Int) = ProofRecord(
        id = UUID.fromString("00000000-0000-0000-0000-%012d".format(index)),
        eventCode = code,
        createdAt = Instant.parse(date),
        peersVerified = peers,
        eventName = name,
    ).also(store::add)

    private fun openRecordsTab() {
        compose.onNodeWithTag(HomeScreenTestTags.RECORDS_TAB).performClick()
        compose.onNodeWithTag(RecordsHomeScreenTestTags.ROOT).assertIsDisplayed()
    }

    private fun backOnRecordsTab() {
        compose.onNodeWithTag(RecordsHomeScreenTestTags.ROOT).assertIsDisplayed()
        compose.onNodeWithTag(HomeScreenTestTags.RECORDS_TAB).assertIsSelected()
        compose.onNodeWithTag(NowScreenTestTags.ROOT).assertDoesNotExist()
    }

    /** EventRecords is a LazyColumn keyed by record id: scroll the key into composition first. */
    private fun eventRecordRow(record: ProofRecord): SemanticsNodeInteraction {
        compose.onNode(hasScrollToKeyAction()).performScrollToKey(record.id.toString())
        return compose.onNodeWithTag(RecordsScreenTestTags.recordRow(record.id))
    }

    /** The detail screen shows its record's own timestamp; each seeded record has a distinct one. */
    private fun detailOf(record: ProofRecord) {
        compose.onNodeWithTag(RecordDetailScreenTestTags.SELF_PROOF_VALUE).assertIsDisplayed()
        compose.onNodeWithText(recordDateFormatter.format(record.createdAt)).assertIsDisplayed()
        compose.onNodeWithTag(HomeScreenTestTags.ROOT).assertDoesNotExist()
    }

    @Test fun recordsTabAttendanceTileOpensTheNewestSessionAndBackReturnsToRecords() {
        val records = seedCollection()
        launch(FakeEventJoinSession())
        openRecordsTab()
        // One Attendance per event, keyed by the event's newest session.
        compose.onNodeWithTag(RecordsHomeScreenTestTags.attendanceTile(records[2].id)).assertDoesNotExist()
        compose.onNodeWithTag(RecordsHomeScreenTestTags.attendanceTile(records[1].id)).performScrollTo().performClick()
        detailOf(records[1])
        back()
        backOnRecordsTab()
    }

    @Test fun recordsByEventRowOpensThatEventsSessionsAndASessionsDetailThenBackUnwindsToRecords() {
        val records = seedCollection()
        launch(FakeEventJoinSession())
        openRecordsTab()
        compose.onNodeWithTag(RecordsHomeScreenTestTags.BY_EVENT_CONTROL).performScrollTo().performClick()
        compose.onNodeWithTag(RecordsHomeScreenTestTags.BY_EVENT_ROOT).assertIsDisplayed()
        compose.onNodeWithTag(HomeScreenTestTags.ROOT).assertDoesNotExist()

        compose.onNodeWithTag(RecordsHomeScreenTestTags.byEventRow(records[1].id)).performScrollTo().performClick()
        // EventRecords: exactly the Design review sessions.
        records.subList(1, 4).forEach { eventRecordRow(it).assertIsDisplayed() }
        compose.onNodeWithTag(RecordsScreenTestTags.recordRow(records[0].id)).assertDoesNotExist()
        compose.onNodeWithTag(RecordsScreenTestTags.recordRow(records[4].id)).assertDoesNotExist()

        eventRecordRow(records[3]).performClick()
        detailOf(records[3])
        back()
        compose.onNodeWithTag(RecordsScreenTestTags.recordRow(records[3].id)).assertExists()
        back()
        compose.onNodeWithTag(RecordsHomeScreenTestTags.BY_EVENT_ROOT).assertIsDisplayed()
        back()
        backOnRecordsTab()
    }

    @Test fun recordsTodayOpensTodaySummaryAndBackReturnsToRecords() {
        seedCollection()
        launch(FakeEventJoinSession())
        openRecordsTab()
        compose.onNodeWithTag(RecordsHomeScreenTestTags.TODAY_CONTROL).performScrollTo().performClick()
        compose.onNode(hasText(context.getString(R.string.today_summary_title)) and isHeading()).assertIsDisplayed()
        // The seeded sessions are all from October 2026, never "today".
        compose.onNodeWithTag(TodaySummaryScreenTestTags.EMPTY_STATE).assertIsDisplayed()
        compose.onNodeWithTag(HomeScreenTestTags.ROOT).assertDoesNotExist()
        back()
        backOnRecordsTab()
    }

    @Test fun largeFontKeepsAccountTabsAndJoinReachable() {
        val session = FakeEventJoinSession(nearbyEventCards = listOf(card))
        launch(session, fontScale = 2f)
        compose.onNodeWithContentDescription(context.getString(R.string.home_account_title)).assertIsDisplayed()
        compose.onNodeWithTag(HomeScreenTestTags.RECORDS_TAB).assertIsDisplayed()
        compose.onNodeWithTag(EventJoinScreenTestTags.nearbyEventJoin(card.eventCodeHashHex))
            .performScrollTo().assertIsDisplayed().performClick()
        assertEquals(card.eventCodeHashHex, session.joinedNearbyEventCodeHashHex)
    }
}

