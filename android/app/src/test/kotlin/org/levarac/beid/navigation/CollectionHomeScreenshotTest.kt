package org.levarac.beid.navigation

import android.bluetooth.BluetoothAdapter
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.os.Looper
import androidx.activity.ComponentActivity
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.platform.ComposeView
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.unit.Density
import androidx.test.core.app.ApplicationProvider
import java.io.File
import java.time.Duration
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
import org.levarac.beid.sensing.EventJoinUiState
import org.levarac.beid.sensing.NearbyEventCard
import org.levarac.beid.sensing.NearbyEventCardVerification
import org.levarac.beid.sensing.ScanEventSession
import org.levarac.beid.sensing.ScanPhase
import org.levarac.beid.ui.screens.AccountScreenTestTags
import org.levarac.beid.ui.screens.EventJoinScreenTestTags
import org.levarac.beid.ui.screens.FakeEventJoinSession
import org.levarac.beid.ui.screens.HomeScreenTestTags
import org.levarac.beid.ui.screens.NowScreenTestTags
import org.levarac.beid.ui.screens.RecordsHomeScreenTestTags
import org.levarac.beid.ui.screens.RecordsScreenTestTags
import org.levarac.beid.ui.screens.WelcomeScreenTestTags
import org.levarac.beid.ui.theme.BeidAppTheme
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * Opt-in review artifacts from the production navigation graph and composables:
 * Home's Now / Records shell (iOS #795), Account, Records-from-Account.
 * No device, radio, screenshot library, or alternate Home renderer is involved.
 *
 * Pass -Dbeid.screenshots.dir=<absolute-directory> to the TEST JVM, e.g. through
 * JAVA_TOOL_OPTIONS (Gradle does not forward arbitrary -D flags to test workers).
 * Run :app:testDebugUnitTest --tests '*CollectionHomeScreenshotTest' with
 * -Pbeid.eventCodeLookupUrlTemplate= to disable outbound clock preflight.
 * Pin -Duser.timezone=UTC for reproducible date labels. The class is skipped
 * before activity/rule setup when the opt-in property is absent.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], qualifiers = "en-rUS-w411dp-h891dp-xxhdpi")
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class CollectionHomeScreenshotTest {
    @get:Rule val composeTestRule = createAndroidComposeRule<ComponentActivity>()
    private val context: Context get() = ApplicationProvider.getApplicationContext()
    private lateinit var store: ProofRecordStore
    private lateinit var screenshotView: ComposeView
    private val nearby = NearbyEventCard(
        "Community meetup",
        eventIdHex = "ab".repeat(16),
        eventCodeHashHex = "cd".repeat(8),
        verification = NearbyEventCardVerification.READY,
    )
    private val alsoNearby = listOf(
        NearbyEventCard(
            "Design review",
            eventIdHex = "ef".repeat(16),
            eventCodeHashHex = "12".repeat(8),
            verification = NearbyEventCardVerification.READY,
        ),
        NearbyEventCard("Hallway beacon", eventCodeHashHex = "34".repeat(8)),
    )

    companion object {
        @JvmStatic @BeforeClass fun requireOptIn() {
            assumeTrue("Review screenshots are opt-in", !System.getProperty("beid.screenshots.dir").isNullOrBlank())
        }
    }

    @Before fun prepare() {
        OnboardingPreferences(context).hasCompletedOnboarding = true
        shadowOf(BluetoothAdapter.getDefaultAdapter()).setEnabled(true)
        val file = File(context.cacheDir, "collection-review-records.json")
        check(!file.exists() || file.delete())
        store = ProofRecordStore(file)
    }

    private fun record(index: Int, code: String, date: String, name: String, peers: Int) = ProofRecord(
        id = UUID.fromString("00000000-0000-0000-0000-%012d".format(index)),
        eventCode = code,
        createdAt = Instant.parse(date),
        peersVerified = peers,
        eventName = name,
    ).also(store::add)

    private fun seedCollection(): List<ProofRecord> = listOf(
        record(1, "morning-meetup", "2026-10-24T09:30:00Z", "Morning meetup", 8),
        record(2, "design-review", "2026-10-23T15:45:00Z", "Design review", 6),
        record(3, " DESIGN-REVIEW ", "2026-10-23T14:30:00Z", "Design review", 4),
        record(4, "design-review", "2026-10-23T13:00:00Z", "Design review", 3),
        record(5, "community-workshop", "2026-10-21T11:00:00Z", "Community workshop", 12),
    )

    private fun launch(
        fontScale: Float = 1f,
        session: FakeEventJoinSession = FakeEventJoinSession(nearbyEventCards = listOf(nearby)),
        bluetoothOff: Boolean = false,
    ) {
        setAppContent(fontScale, session, bluetoothOff)
        composeTestRule.onNodeWithTag(HomeScreenTestTags.ROOT).assertIsDisplayed()
        composeTestRule.onNodeWithTag(EventJoinScreenTestTags.ACCOUNT_ENTRY).assertIsDisplayed()
    }

    /** Production [AppNavHost]; its start destination follows the onboarding preference. */
    private fun setAppContent(
        fontScale: Float = 1f,
        session: FakeEventJoinSession = FakeEventJoinSession(nearbyEventCards = listOf(nearby)),
        bluetoothOff: Boolean = false,
    ) {
        composeTestRule.runOnUiThread {
            screenshotView = ComposeView(composeTestRule.activity)
            composeTestRule.activity.setContentView(screenshotView)
            screenshotView.setContent {
                CompositionLocalProvider(LocalDensity provides Density(LocalDensity.current.density, fontScale)) {
                    BeidAppTheme { AppNavHost(session, store, homeBluetoothOff = { bluetoothOff }) }
                }
            }
        }
    }

    /** Robolectric's shadowed uptime and the standby ticker advance together. */
    private fun idleFor(seconds: Long) {
        composeTestRule.waitForIdle()
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofSeconds(seconds))
        composeTestRule.waitForIdle()
    }

    private fun openAccount() {
        composeTestRule.onNodeWithTag(EventJoinScreenTestTags.ACCOUNT_ENTRY).performClick()
        composeTestRule.onNodeWithTag(AccountScreenTestTags.RECORDS_BUTTON).assertIsDisplayed()
    }

    private fun capture(name: String) {
        composeTestRule.waitForIdle()
        // PixelCopy's forceRedraw waits for a frame Robolectric never supplies.
        // Draw the attached production composition after Compose has settled.
        val bitmap = composeTestRule.runOnIdle {
            check(screenshotView.isAttachedToWindow)
            check(screenshotView.width > 0 && screenshotView.height > 0)
            Bitmap.createBitmap(screenshotView.width, screenshotView.height, Bitmap.Config.ARGB_8888).also {
                screenshotView.draw(Canvas(it))
            }
        }
        val firstPixel = bitmap.getPixel(0, 0)
        check((0 until bitmap.height).any { y ->
            (0 until bitmap.width).any { x -> bitmap.getPixel(x, y) != firstPixel }
        }) { "Screenshot must not be blank or a single color" }
        val directory = File(requireNotNull(System.getProperty("beid.screenshots.dir")))
        check(directory.isAbsolute) { "Screenshot directory must be absolute" }
        check(directory.isDirectory || directory.mkdirs())
        File(directory, "$name.png").outputStream().use {
            check(bitmap.compress(Bitmap.CompressFormat.PNG, 100, it))
        }
        println("Screenshot: $name.png ${bitmap.width}x${bitmap.height}")
    }

    @Test fun nowListening() {
        launch(session = FakeEventJoinSession())
        idleFor(12)
        composeTestRule.onNodeWithTag(NowScreenTestTags.LISTENING).assertIsDisplayed()
        capture("now-listening")
    }

    @Test fun nowJoinAndAlsoNearby() {
        launch(session = FakeEventJoinSession(nearbyEventCards = listOf(nearby) + alsoNearby))
        composeTestRule.onNodeWithTag(EventJoinScreenTestTags.nearbyEventJoin(nearby.eventCodeHashHex))
            .performScrollTo()
        composeTestRule.onNodeWithTag(NowScreenTestTags.ALSO_NEARBY).performScrollTo().assertIsDisplayed()
        capture("now-join-also-nearby")
    }

    @Test fun nowCodeEntryOffered() {
        launch(session = FakeEventJoinSession())
        idleFor(30)
        composeTestRule.onNodeWithTag(NowScreenTestTags.ENTER_CODE).performScrollTo().assertIsDisplayed()
        capture("now-code-entry-offered")
    }

    @Test fun nowLargeFont() {
        launch(fontScale = 1.5f)
        capture("now-large-font")
    }

    @Test fun nowBluetoothOffIdle() {
        launch(session = FakeEventJoinSession(), bluetoothOff = true)
        composeTestRule.onNodeWithTag(NowScreenTestTags.BLUETOOTH_OFF).assertIsDisplayed()
        capture("now-bluetooth-off-idle")
    }

    @Test fun nowBluetoothOffSensing() {
        val session = FakeEventJoinSession(
            EventJoinUiState.Sensing(ScanPhase.Recording(ScanEventSession("community-meetup"), peersVerified = 4)),
        )
        session.markRecordingCeremonyShown()
        launch(session = session, bluetoothOff = true)
        composeTestRule.onNodeWithTag(NowScreenTestTags.BLUETOOTH_OFF).assertIsDisplayed()
        capture("now-bluetooth-off-sensing")
    }

    @Test fun recordsTab() {
        seedCollection()
        launch()
        composeTestRule.onNodeWithTag(HomeScreenTestTags.RECORDS_TAB).performClick()
        composeTestRule.onNodeWithTag(RecordsHomeScreenTestTags.ROOT).assertIsDisplayed()
        composeTestRule.onAllNodesWithTag(RecordsHomeScreenTestTags.ATTENDANCE_TILE, useUnmergedTree = true)
            .assertCountEquals(3)
        capture("records-tab")
    }

    @Test fun recordsTabEmpty() {
        launch()
        composeTestRule.onNodeWithTag(HomeScreenTestTags.RECORDS_TAB).performClick()
        composeTestRule.onNodeWithTag(RecordsHomeScreenTestTags.EMPTY_STATE).performScrollTo().assertIsDisplayed()
        capture("records-tab-empty")
    }

    /** Replaces the render once reached through the old Home group card. */
    @Test fun eventRecordsList() {
        val records = seedCollection()
        launch()
        composeTestRule.onNodeWithTag(HomeScreenTestTags.RECORDS_TAB).performClick()
        composeTestRule.onNodeWithTag(RecordsHomeScreenTestTags.BY_EVENT_CONTROL).performScrollTo().performClick()
        composeTestRule.onNodeWithTag(RecordsHomeScreenTestTags.byEventRow(records[1].id)).performScrollTo().performClick()
        records.subList(1, 4).forEach {
            composeTestRule.onNodeWithTag(RecordsScreenTestTags.recordRow(it.id)).assertIsDisplayed()
        }
        composeTestRule.onNodeWithTag(RecordsScreenTestTags.recordRow(records[0].id)).assertDoesNotExist()
        capture("event-records-list")
    }

    @Test fun accountFromToolbar() {
        seedCollection()
        launch()
        openAccount()
        capture("account-from-toolbar")
    }

    @Test fun welcome() {
        OnboardingPreferences(context).hasCompletedOnboarding = false
        setAppContent()
        composeTestRule.onNodeWithTag(WelcomeScreenTestTags.GET_STARTED_BUTTON).assertIsDisplayed()
        composeTestRule.onNodeWithTag("collection_home").assertDoesNotExist()
        capture("welcome")
    }

    @Test fun account() {
        seedCollection()
        launch()
        openAccount()
        capture("account") // Top of the scrollable Account column.
    }

    @Test fun accountLargeFont() {
        seedCollection()
        launch(fontScale = 1.5f)
        openAccount()
        capture("account-large-font")
    }

    // At 1x the whole Account column fits one frame; at 1.5x it scrolls.
    @Test fun accountLargeFontScrolledToEnd() {
        seedCollection()
        launch(fontScale = 1.5f)
        openAccount()
        composeTestRule.onNodeWithTag(AccountScreenTestTags.VERSION_TEXT).performScrollTo().assertIsDisplayed()
        capture("account-large-font-scrolled-to-end")
    }

    @Test fun recordsFromAccount() {
        val records = seedCollection()
        launch()
        openAccount()
        composeTestRule.onNodeWithTag(AccountScreenTestTags.RECORDS_BUTTON).performClick()
        composeTestRule.onNodeWithTag(RecordsScreenTestTags.recordRow(records[0].id)).assertIsDisplayed()
        capture("records-from-account")
    }
}
