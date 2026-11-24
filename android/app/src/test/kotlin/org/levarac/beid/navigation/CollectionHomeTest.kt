package org.levarac.beid.navigation

import android.bluetooth.BluetoothAdapter
import android.content.Context
import androidx.activity.ComponentActivity
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.unit.Density
import androidx.test.core.app.ApplicationProvider
import java.io.File
import java.time.Instant
import java.util.UUID
import kotlin.test.assertEquals
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
import org.levarac.beid.sensing.ScanEventSession
import org.levarac.beid.sensing.ScanPhase
import org.levarac.beid.ui.screens.AccountScreenTestTags
import org.levarac.beid.ui.screens.EventJoinScreenTestTags
import org.levarac.beid.ui.screens.FakeEventJoinSession
import org.levarac.beid.ui.screens.RecordDetailScreenTestTags
import org.levarac.beid.ui.screens.RecordsScreenTestTags
import org.levarac.beid.ui.theme.BeidAppTheme
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/** Drives the production graph and store; no radio, registry, or alternate Home renderer. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class CollectionHomeTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()
    @get:Rule val folder = TemporaryFolder()
    private val context: Context get() = ApplicationProvider.getApplicationContext()
    private lateinit var store: ProofRecordStore
    private val card = NearbyEventCard("Nearby gathering", eventIdHex = "ab".repeat(16),
        eventCodeHashHex = "cd".repeat(8))

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

    private fun record(code: String, second: Long, name: String? = null, nanos: Long = 0) = ProofRecord(
        UUID.randomUUID(), code, Instant.ofEpochSecond(second, nanos), 3, eventName = name,
    ).also(store::add)

    private fun group(record: ProofRecord) = compose.onNodeWithTag("home_group_${record.id}")
    private fun back() = compose.runOnUiThread { compose.activity.onBackPressedDispatcher.onBackPressed() }
    private fun home() = compose.onNodeWithTag("collection_home").assertIsDisplayed()

    @Test fun launchLandsOnHomeAndStartsDiscovery() {
        val session = FakeEventJoinSession(nearbyEventCards = listOf(card))
        launch(session)
        home()
        compose.onNodeWithTag(EventJoinScreenTestTags.nearbyEventCard(card.eventCodeHashHex)).assertIsDisplayed()
        assertEquals(1, session.nearbyEventDiscoveryStartCalls)
    }

    @Test fun nearbyCardStillJoinsInOneTapFromHome() {
        val session = FakeEventJoinSession(nearbyEventCards = listOf(card))
        launch(session)
        home()
        compose.onNodeWithTag(EventJoinScreenTestTags.nearbyEventCard(card.eventCodeHashHex)).performClick()
        assertEquals(card.eventCodeHashHex, session.joinedNearbyEventCodeHashHex)
        assertEquals(null, session.joinedCode)
    }

    @Test fun emptyCollectionKeepsDiscoveryBeforeTheExplanation() {
        launch()
        home()
        val nearby = compose.onNodeWithTag(EventJoinScreenTestTags.NEARBY_EVENT_LIST).fetchSemanticsNode().positionInRoot.y
        compose.onNodeWithTag("home_empty_collection").performScrollTo().assertIsDisplayed()
        assertTrue(nearby < compose.onNodeWithTag("home_empty_collection").fetchSemanticsNode().positionInRoot.y)
        compose.onNodeWithTag(EventJoinScreenTestTags.nearbyEventCard(card.eventCodeHashHex))
            .performScrollTo().assertIsDisplayed()
    }

    @Test fun sharedOrderExcludesTheWholeActiveEventAndKeepsVerifiedNames() {
        val older = record("older", 10, "Older event")
        record("active", 30, "Active event")
        record(" ACTIVE ", 5, "Earlier active session")
        val newer = record("newer", 20, "Newer event")
        record(" NEWER ", 15, "Newer event")
        val session = FakeEventJoinSession(EventJoinUiState.Sensing(
            ScanPhase.EventFound(ScanEventSession(" Active "))))
        launch(session)
        home()
        compose.onAllNodesWithTag("home_event_group").assertCountEquals(2)
        group(newer).performScrollTo().assertIsDisplayed()
        compose.onNodeWithText("Newer event").assertIsDisplayed()
        compose.onNodeWithText("2 records").assertIsDisplayed()
        val newerY = group(newer).fetchSemanticsNode().positionInRoot.y
        assertTrue(newerY < group(older).fetchSemanticsNode().positionInRoot.y)
        compose.onNodeWithText("Active event").assertDoesNotExist()
    }

    @Test fun singletonOpensItsExistingDetailAndBackReturnsHome() {
        val single = record("single", 10, "Single event")
        launch()
        group(single).performScrollTo().performClick()
        compose.onNodeWithTag(RecordDetailScreenTestTags.SELF_PROOF_VALUE).assertIsDisplayed()
        compose.onNodeWithText("Single event").assertIsDisplayed()
        back()
        home()
    }

    @Test fun multipleRecordsOpenOnlyThatEventsExistingListAndDetail() {
        val first = record("same", 10, "Same event")
        val latest = record(" SAME ", 20, "Same event")
        val other = record("other", 30, "Other event")
        launch()
        group(latest).performScrollTo().performClick()
        compose.onNodeWithTag(RecordsScreenTestTags.recordRow(latest.id)).assertIsDisplayed()
        compose.onNodeWithTag(RecordsScreenTestTags.recordRow(first.id)).assertIsDisplayed()
        compose.onNodeWithTag(RecordsScreenTestTags.recordRow(other.id)).assertDoesNotExist()
        compose.onNodeWithTag(RecordsScreenTestTags.recordRow(first.id)).performClick()
        compose.onNodeWithTag(RecordDetailScreenTestTags.SELF_PROOF_VALUE).assertIsDisplayed()
        back()
        compose.onNodeWithTag(RecordsScreenTestTags.recordRow(first.id)).assertIsDisplayed()
        back()
        home()
    }

    @Test fun accountIconLeadsToAccountAndTheFullSecondaryList() {
        val first = record("first", 10)
        val second = record("second", 20)
        launch()
        home()
        compose.onNodeWithContentDescription(context.getString(R.string.event_join_account_action))
            .assertIsDisplayed().performClick()
        compose.onNodeWithTag(AccountScreenTestTags.RECORDS_BUTTON).performScrollTo().performClick()
        compose.onNodeWithTag(RecordsScreenTestTags.recordRow(first.id)).assertIsDisplayed()
        compose.onNodeWithTag(RecordsScreenTestTags.recordRow(second.id)).assertIsDisplayed()
        back()
        compose.onNodeWithTag(AccountScreenTestTags.MANUAL_EVENT_CODE_BUTTON).performScrollTo().performClick()
        compose.onNodeWithTag(EventJoinScreenTestTags.SUBMIT_BUTTON).assertIsDisplayed()
        back()
        compose.onNodeWithTag(AccountScreenTestTags.RECORDS_BUTTON).assertExists()
        back()
        home()
    }

    @Test fun largeFontKeepsAccountAndFirstNearbyCardReachable() {
        val session = FakeEventJoinSession(nearbyEventCards = listOf(card))
        launch(session, fontScale = 2f)
        home()
        compose.onNodeWithContentDescription(context.getString(R.string.event_join_account_action)).assertIsDisplayed()
        compose.onNodeWithTag(EventJoinScreenTestTags.nearbyEventCard(card.eventCodeHashHex))
            .performScrollTo().assertIsDisplayed().performClick()
        assertEquals(card.eventCodeHashHex, session.joinedNearbyEventCodeHashHex)
    }

    @Test fun missingIdentityStaysSeparateAndFallbackIsTheExistingRecordLabel() {
        val first = record("", 10)
        val second = record("", 20)
        record("ab".repeat(32), 30)
        launch()
        home()
        compose.onAllNodesWithTag("home_event_group").assertCountEquals(3)
        compose.onNodeWithText("Event abababab…ababab").performScrollTo().assertIsDisplayed()
        group(first).performScrollTo().performClick()
        compose.onNodeWithTag(RecordDetailScreenTestTags.SELF_PROOF_VALUE).assertIsDisplayed()
        back()
        group(second).performScrollTo().assertIsDisplayed()
    }

    @Test fun storeAndActiveSessionChangesRefreshHomeWithoutRestartingDiscovery() {
        val earlier = record("earlier", 10, nanos = 1)
        val later = record("later", 10, nanos = 900_000_000)
        val session = FakeEventJoinSession()
        launch(session)
        home()
        assertTrue(group(later).fetchSemanticsNode().positionInRoot.y < group(earlier).fetchSemanticsNode().positionInRoot.y)
        compose.runOnIdle { session.emit(EventJoinUiState.Sensing(ScanPhase.SignalLost(ScanEventSession("later"), 3))) }
        group(later).assertDoesNotExist()
        compose.runOnIdle { session.emit(EventJoinUiState.Idle) }
        group(later).assertExists()
        val newest = compose.runOnIdle { record("fresh", 50, "Fresh event") }
        group(newest).performScrollTo().assertIsDisplayed()
        assertEquals(1, session.nearbyEventDiscoveryStartCalls)
    }
}
