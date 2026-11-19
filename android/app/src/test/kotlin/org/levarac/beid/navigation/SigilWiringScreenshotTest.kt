package org.levarac.beid.navigation

import android.bluetooth.BluetoothAdapter
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import androidx.activity.ComponentActivity
import androidx.compose.ui.platform.ComposeView
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.test.core.app.ApplicationProvider
import java.io.File
import java.time.Instant
import java.util.UUID
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.BeforeClass
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
import org.levarac.beid.ui.screens.FakeEventJoinSession
import org.levarac.beid.ui.screens.HomeScreenTestTags
import org.levarac.beid.ui.screens.NowScreenTestTags
import org.levarac.beid.ui.screens.RecordsHomeScreenTestTags
import org.levarac.beid.ui.screens.RecordsScreenTestTags
import org.levarac.beid.ui.theme.BeidAppTheme
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * Opt-in BEFORE/AFTER review renders of every screen the Sigil and radar
 * wiring (beid#722) touches, through the production [AppNavHost]: the
 * Records tab, By event, an event's records, record detail, and Now's
 * EventFound / Recording content.
 *
 * Records 1, 2, 3 and 5 have a stored Sigil row; record 4 has none, so its
 * slot keeps the neutral ring. Pass -Dbeid.screenshots.dir=<absolute dir> to
 * the test JVM (JAVA_TOOL_OPTIONS) and -Pbeid.eventCodeLookupUrlTemplate= to
 * Gradle, as for [CollectionHomeScreenshotTest].
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], qualifiers = "en-rUS-w411dp-h891dp-xxhdpi")
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class SigilWiringScreenshotTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()
    private val context: Context get() = ApplicationProvider.getApplicationContext()
    private lateinit var store: ProofRecordStore
    private lateinit var sigilStore: SigilPresenceStore
    private lateinit var view: ComposeView
    private val event = ScanEventSession("community-meetup", eventName = "Community meetup")

    companion object {
        @JvmStatic @BeforeClass fun requireOptIn() {
            assumeTrue("Review screenshots are opt-in", !System.getProperty("beid.screenshots.dir").isNullOrBlank())
        }
    }

    @Before fun prepare() {
        OnboardingPreferences(context).hasCompletedOnboarding = true
        shadowOf(BluetoothAdapter.getDefaultAdapter()).setEnabled(true)
        val file = File(context.cacheDir, "sigil-wiring-records.json")
        check(!file.exists() || file.delete())
        store = ProofRecordStore(file)
        val sigilFile = SigilPresenceStore.defaultFile(File(context.cacheDir, "sigil-wiring"))
        check(!sigilFile.exists() || sigilFile.delete())
        sigilStore = SigilPresenceStore(sigilFile)
    }

    private fun record(index: Int, code: String, date: String, name: String, peers: Int) = ProofRecord(
        id = UUID.fromString("00000000-0000-0000-0000-%012d".format(index)),
        eventCode = code,
        createdAt = Instant.parse(date),
        peersVerified = peers,
        eventName = name,
    ).also(store::add)

    private fun seed(): List<ProofRecord> {
        val records = listOf(
            record(1, "morning-meetup", "2026-10-24T09:30:00Z", "Morning meetup", 8),
            record(2, "design-review", "2026-10-23T15:45:00Z", "Design review", 6),
            record(3, "design-review", "2026-10-23T14:30:00Z", "Design review", 4),
            record(4, "design-review", "2026-10-23T13:00:00Z", "Design review", 3),
            record(5, "community-workshop", "2026-10-21T11:00:00Z", "Community workshop", 12),
        )
        sigilStore.seedDetectedSigil(records[0].id, peers = 8, windows = 10, tokenSeed = 1)
        sigilStore.seedDetectedSigil(records[1].id, peers = 6, windows = 6, tokenSeed = 2)
        sigilStore.seedDetectedSigil(records[2].id, peers = 4, windows = 4, tokenSeed = 3)
        sigilStore.seedDetectedSigil(records[4].id, peers = 12, windows = 12, tokenSeed = 5)
        return records
    }

    private val radarPeers = listOf(
        SensingRadarPeerSignal("d0000a01", null),
        SensingRadarPeerSignal("d0000a02", -48.0),
        SensingRadarPeerSignal("d0000a03", -62.0),
        SensingRadarPeerSignal("d0000a04", -77.0),
        SensingRadarPeerSignal("d0000a05", -91.0),
    )

    private fun launch(session: FakeEventJoinSession = FakeEventJoinSession()) {
        compose.runOnUiThread {
            view = ComposeView(compose.activity)
            compose.activity.setContentView(view)
            view.setContent {
                BeidAppTheme { AppNavHost(session, store, sigilPresenceStore = sigilStore) }
            }
        }
        compose.onNodeWithTag(HomeScreenTestTags.ROOT).assertIsDisplayed()
    }

    private fun capture(name: String) {
        compose.waitForIdle()
        val bitmap = compose.runOnIdle {
            check(view.isAttachedToWindow && view.width > 0 && view.height > 0)
            Bitmap.createBitmap(view.width, view.height, Bitmap.Config.ARGB_8888).also { view.draw(Canvas(it)) }
        }
        val directory = File(requireNotNull(System.getProperty("beid.screenshots.dir")))
        check(directory.isAbsolute) { "Screenshot directory must be absolute" }
        check(directory.isDirectory || directory.mkdirs())
        File(directory, "$name.png").outputStream().use { check(bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)) }
        println("Screenshot: $name.png ${bitmap.width}x${bitmap.height}")
    }

    private fun openRecordsTab() {
        compose.onNodeWithTag(HomeScreenTestTags.RECORDS_TAB).performClick()
        compose.onNodeWithTag(RecordsHomeScreenTestTags.ROOT).assertIsDisplayed()
    }

    @Test fun recordsTab() {
        seed()
        launch()
        openRecordsTab()
        capture("sigil-records-tab")
    }

    @Test fun recordsByEvent() {
        seed()
        launch()
        openRecordsTab()
        compose.onNodeWithTag(RecordsHomeScreenTestTags.BY_EVENT_CONTROL).performScrollTo().performClick()
        compose.onNodeWithTag(RecordsHomeScreenTestTags.BY_EVENT_ROOT).assertIsDisplayed()
        capture("sigil-records-by-event")
    }

    @Test fun eventRecordsList() {
        val records = seed()
        launch()
        openRecordsTab()
        compose.onNodeWithTag(RecordsHomeScreenTestTags.BY_EVENT_CONTROL).performScrollTo().performClick()
        compose.onNodeWithTag(RecordsHomeScreenTestTags.byEventRow(records[1].id)).performScrollTo().performClick()
        compose.onNodeWithTag(RecordsScreenTestTags.recordRow(records[1].id)).assertIsDisplayed()
        capture("sigil-event-records-list")
    }

    @Test fun recordDetail() {
        val records = seed()
        launch()
        openRecordsTab()
        compose.onNodeWithTag(RecordsHomeScreenTestTags.attendanceTile(records[0].id)).performScrollTo().performClick()
        compose.onNodeWithTag(RecordsHomeScreenTestTags.ROOT).assertDoesNotExist()
        capture("sigil-record-detail")
    }

    @Test fun recordDetailWithoutStoredSigil() {
        val records = seed()
        launch()
        openRecordsTab()
        compose.onNodeWithTag(RecordsHomeScreenTestTags.BY_EVENT_CONTROL).performScrollTo().performClick()
        compose.onNodeWithTag(RecordsHomeScreenTestTags.byEventRow(records[1].id)).performScrollTo().performClick()
        compose.onNodeWithTag(RecordsScreenTestTags.recordRow(records[3].id)).performScrollTo().performClick()
        compose.onNodeWithTag(RecordsScreenTestTags.recordRow(records[3].id)).assertDoesNotExist()
        capture("sigil-record-detail-no-stored-sigil")
    }

    @Test fun nowEventFound() {
        val session = FakeEventJoinSession(EventJoinUiState.Sensing(ScanPhase.EventFound(event)))
        session.emitRadarPeers(radarPeers)
        launch(session)
        compose.onNodeWithTag(NowScreenTestTags.ROOT).assertIsDisplayed()
        capture("sigil-now-event-found")
    }

    @Test fun nowRecording() {
        val session = FakeEventJoinSession(EventJoinUiState.Sensing(ScanPhase.Recording(event, peersVerified = 5)))
        session.markRecordingCeremonyShown()
        session.emitRadarPeers(radarPeers)
        launch(session)
        compose.onNodeWithTag(NowScreenTestTags.ROOT).assertIsDisplayed()
        capture("sigil-now-recording")
    }
}
