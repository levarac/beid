package org.levarac.beid.navigation

import android.bluetooth.BluetoothAdapter
import android.content.Context
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.SemanticsNodeInteraction
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertWidthIsEqualTo
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithContentDescription
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.unit.dp
import androidx.test.core.app.ApplicationProvider
import java.io.File
import java.time.Instant
import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.levarac.beid.onboarding.OnboardingPreferences
import org.levarac.beid.persistence.ProofRecord
import org.levarac.beid.persistence.ProofRecordStore
import org.levarac.beid.persistence.SigilPresenceStore
import org.levarac.beid.persistence.seedDetectedSigil
import org.levarac.beid.sensing.EventJoinUiState
import org.levarac.beid.sensing.ScanEventSession
import org.levarac.beid.sensing.ScanPhase
import org.levarac.beid.sensing.SensingRadarPeerSignal
import org.levarac.beid.ui.designsystem.SensingRadar
import org.levarac.beid.ui.screens.AccountScreenTestTags
import org.levarac.beid.ui.screens.EventJoinScreenTestTags
import org.levarac.beid.ui.screens.FakeEventJoinSession
import org.levarac.beid.ui.screens.HomeScreenTestTags
import org.levarac.beid.ui.screens.RecordDetailScreenTestTags
import org.levarac.beid.ui.screens.RecordsHomeScreenTestTags
import org.levarac.beid.ui.screens.RecordsScreenTestTags
import org.levarac.beid.ui.theme.BeidAppTheme
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/**
 * beid#722 wiring, end to end through the production [AppNavHost]: a stored
 * Sigil row reaches every Android record site whose iOS counterpart draws
 * one (release/1.1.0),
 * a record without one keeps the hidden neutral ring, and Now's EventFound /
 * Recording content draws the session's radar peers and redraws on a new
 * detection. No live Sigil is drawn anywhere (the iOS drafts read
 * `liveSigilInput` nowhere).
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], qualifiers = "w320dp-h900dp")
class SigilWiringTest {
    @get:Rule val compose = createComposeRule()
    private val context: Context get() = ApplicationProvider.getApplicationContext()
    private lateinit var store: ProofRecordStore
    private lateinit var sigilStore: SigilPresenceStore
    private val event = ScanEventSession("community-meetup", eventName = "Community meetup")

    /** Has a stored row: 8 detected peers over 10 windows. */
    private lateinit var withSigil: ProofRecord

    /** Same event, older session, no row: keeps the ring. */
    private lateinit var sameEventWithout: ProofRecord

    /** Another event with no row. */
    private lateinit var otherWithout: ProofRecord

    @Before fun prepare() {
        OnboardingPreferences(context).hasCompletedOnboarding = true
        shadowOf(BluetoothAdapter.getDefaultAdapter()).setEnabled(true)
        val file = File(context.cacheDir, "sigil-wiring-test-records.json")
        check(!file.exists() || file.delete())
        store = ProofRecordStore(file)
        val sigilFile = SigilPresenceStore.defaultFile(File(context.cacheDir, "sigil-wiring-test"))
        check(!sigilFile.exists() || sigilFile.delete())
        sigilStore = SigilPresenceStore(sigilFile)
        withSigil = record(1, "design-review", "2026-10-23T15:45:00Z", "Design review")
        sameEventWithout = record(2, "design-review", "2026-10-23T13:00:00Z", "Design review")
        otherWithout = record(3, "morning-meetup", "2026-10-22T09:30:00Z", "Morning meetup")
        sigilStore.seedDetectedSigil(withSigil.id, peers = 8, windows = 10)
    }

    private fun record(index: Int, code: String, date: String, name: String) = ProofRecord(
        id = UUID.fromString("00000000-0000-0000-0000-%012d".format(index)),
        eventCode = code,
        createdAt = Instant.parse(date),
        peersVerified = 3,
        eventName = name,
    ).also(store::add)

    private fun launch(session: FakeEventJoinSession = FakeEventJoinSession()) {
        compose.setContent { BeidAppTheme { AppNavHost(session, store, sigilPresenceStore = sigilStore) } }
        compose.onNodeWithTag(HomeScreenTestTags.ROOT).assertIsDisplayed()
    }

    private fun node(tag: String) = compose.onNodeWithTag(tag, useUnmergedTree = true)

    private fun SemanticsNodeInteraction.description(): String? =
        fetchSemanticsNode().config.getOrNull(SemanticsProperties.ContentDescription)?.joinToString()

    private fun SemanticsNodeInteraction.isHidden(): Boolean =
        fetchSemanticsNode().config.contains(SemanticsProperties.HideFromAccessibility)

    private fun assertSigil(tag: String, summary: String) {
        assertEquals(tag, summary, node(tag).description())
        assertFalse(tag, node(tag).isHidden())
    }

    private fun assertRing(tag: String) {
        assertTrue("$tag must be the hidden neutral ring", node(tag).isHidden())
        assertNull(tag, node(tag).description())
    }

    private fun openRecordsTab() {
        compose.onNodeWithTag(HomeScreenTestTags.RECORDS_TAB).performClick()
        compose.onNodeWithTag(RecordsHomeScreenTestTags.ROOT).assertIsDisplayed()
    }

    private fun openByEvent() {
        openRecordsTab()
        compose.onNodeWithTag(RecordsHomeScreenTestTags.BY_EVENT_CONTROL).performScrollTo().performClick()
        compose.onNodeWithTag(RecordsHomeScreenTestTags.BY_EVENT_ROOT).assertIsDisplayed()
    }

    // region Records

    @Test
    fun anAttendanceTileDrawsItsStoredSigilAndATileWithoutOneKeepsTheRing() {
        launch()
        openRecordsTab()
        // iOS release/1.1.0 CollectionHomeView: `.recordsGrid` with isDeviceRecord, so the device-record summary.
        assertSigil(
            RecordsHomeScreenTestTags.attendanceSigil(withSigil.id),
            "Devices heard: 8. Window 10. Mutual check not available yet.",
        )
        node(RecordsHomeScreenTestTags.attendanceSigil(withSigil.id)).assertWidthIsEqualTo(104.dp)
        assertRing(RecordsHomeScreenTestTags.attendanceSigil(otherWithout.id))
    }

    @Test
    fun aByEventRowDrawsTheNewestSessionsSigil() {
        launch()
        openByEvent()
        // iOS release/1.1.0 CollectionHomeView: `.homePastRow` with isDeviceRecord.
        assertSigil(
            RecordsHomeScreenTestTags.byEventSigil(withSigil.id),
            "Devices heard: 8. Window 10. Mutual check not available yet.",
        )
        node(RecordsHomeScreenTestTags.byEventSigil(withSigil.id)).assertWidthIsEqualTo(60.dp)
        assertRing(RecordsHomeScreenTestTags.byEventSigil(otherWithout.id))
    }

    @Test
    fun anEventsRecordsDrawTheDeviceRecordSigilPerSession() {
        launch()
        openByEvent()
        compose.onNodeWithTag(RecordsHomeScreenTestTags.byEventRow(withSigil.id)).performScrollTo().performClick()
        compose.onNodeWithTag(RecordsScreenTestTags.recordRow(withSigil.id)).assertIsDisplayed()
        assertSigil(
            RecordsScreenTestTags.recordSigil(withSigil.id),
            "Devices heard: 8. Window 10. Mutual check not available yet.",
        )
        node(RecordsScreenTestTags.recordSigil(withSigil.id)).assertWidthIsEqualTo(48.dp)
        assertRing(RecordsScreenTestTags.recordSigil(sameEventWithout.id))
    }

    /** The Account list is iOS PastEventsView, which draws no Sigil. */
    @Test
    fun theFullRecordsListFromAccountDrawsNoSigil() {
        launch()
        compose.onNodeWithTag(EventJoinScreenTestTags.ACCOUNT_ENTRY).performClick()
        compose.onNodeWithTag(AccountScreenTestTags.RECORDS_BUTTON).performClick()
        compose.onNodeWithTag(RecordsScreenTestTags.recordRow(withSigil.id)).assertIsDisplayed()
        node(RecordsScreenTestTags.recordSigil(withSigil.id)).assertDoesNotExist()
    }

    @Test
    fun recordDetailDrawsTheDeviceRecordSigil() {
        launch()
        openRecordsTab()
        compose.onNodeWithTag(RecordsHomeScreenTestTags.attendanceTile(withSigil.id)).performScrollTo().performClick()
        assertSigil(RecordDetailScreenTestTags.SIGIL, "Devices heard: 8. Window 10. Mutual check not available yet.")
        node(RecordDetailScreenTestTags.SIGIL).assertWidthIsEqualTo(200.dp)
    }

    @Test
    fun recordDetailWithoutAStoredRowKeepsTheRing() {
        launch()
        openRecordsTab()
        compose.onNodeWithTag(RecordsHomeScreenTestTags.attendanceTile(otherWithout.id)).performScrollTo().performClick()
        assertRing(RecordDetailScreenTestTags.SIGIL)
    }

    // endregion

    // region Radar

    private val peers = listOf(
        SensingRadarPeerSignal("d0000a01", null),
        SensingRadarPeerSignal("d0000a02", -48.0),
        SensingRadarPeerSignal("d0000a03", -77.0),
    )

    private fun assertNoPeerIdShown(ids: List<String>) {
        for (id in ids) {
            compose.onAllNodesWithText(id, substring = true, useUnmergedTree = true).assertCountEquals(0)
            compose.onAllNodesWithContentDescription(id, substring = true, useUnmergedTree = true).assertCountEquals(0)
        }
    }

    @Test
    fun eventFoundDrawsExactlyTheSessionsPeersWithoutIdentifiers() {
        val session = FakeEventJoinSession(EventJoinUiState.Sensing(ScanPhase.EventFound(event)))
        session.emitRadarPeers(peers)
        launch(session)
        compose.onNodeWithTag(SensingRadar.TEST_TAG).performScrollTo()
        assertEquals("3 devices heard in the last 5 minutes", node(SensingRadar.TEST_TAG).description())
        assertNoPeerIdShown(peers.map { it.displayId })
    }

    /**
     * iOS: min(radarField, width - pageMargin). At 320dp the Now column is
     * 272dp wide (two 24dp margins), the screen less one margin is 296dp, and
     * the radar overflows the column by half a margin each side, as on iOS.
     */
    @Test
    fun theRadarFitsTheScreenWidthLessOneMargin() {
        val session = FakeEventJoinSession(EventJoinUiState.Sensing(ScanPhase.EventFound(event)))
        launch(session)
        node(SensingRadar.TEST_TAG).assertWidthIsEqualTo(296.dp)
    }

    @Test
    fun theRecordingRadarRedrawsAfterANewDetection() {
        val session = FakeEventJoinSession(EventJoinUiState.Sensing(ScanPhase.Recording(event, peersVerified = 2)))
        session.markRecordingCeremonyShown()
        session.emitRadarPeers(peers.take(2))
        launch(session)
        compose.onNodeWithTag(SensingRadar.TEST_TAG).performScrollTo()
        assertEquals("2 devices heard in the last 5 minutes", node(SensingRadar.TEST_TAG).description())

        session.emitRadarPeers(peers)
        compose.waitForIdle()
        assertEquals("3 devices heard in the last 5 minutes", node(SensingRadar.TEST_TAG).description())
        assertNoPeerIdShown(peers.map { it.displayId })
    }

    @Test
    fun noRadarBeforeAnEventIsFoundOrOutsideASession() {
        val sensing = FakeEventJoinSession(EventJoinUiState.Sensing(ScanPhase.Sensing))
        sensing.emitRadarPeers(peers)
        launch(sensing)
        node(SensingRadar.TEST_TAG).assertDoesNotExist()
    }

    @Test
    fun noRadarOnIdleNow() {
        launch()
        node(SensingRadar.TEST_TAG).assertDoesNotExist()
    }

    // endregion
}
