package org.levarac.beid.navigation

import android.bluetooth.BluetoothAdapter
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
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
import org.levarac.beid.sensing.NearbyEventCard
import org.levarac.beid.sensing.NearbyEventCardVerification
import org.levarac.beid.ui.screens.EventJoinScreenTestTags
import org.levarac.beid.ui.screens.FakeEventJoinSession
import org.levarac.beid.ui.screens.RecordsScreenTestTags
import org.levarac.beid.ui.theme.BeidAppTheme
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * Opt-in review artifacts from the production navigation graph and composables.
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

    private fun launch(dark: Boolean = false, fontScale: Float = 1f) {
        val session = FakeEventJoinSession(nearbyEventCards = listOf(nearby))
        composeTestRule.runOnUiThread {
            screenshotView = ComposeView(composeTestRule.activity)
            composeTestRule.activity.setContentView(screenshotView)
            screenshotView.setContent {
                CompositionLocalProvider(LocalDensity provides Density(LocalDensity.current.density, fontScale)) {
                    BeidAppTheme(darkTheme = dark) { AppNavHost(session, store) }
                }
            }
        }
        composeTestRule.onNodeWithTag("collection_home").assertIsDisplayed()
        composeTestRule.onNodeWithTag(EventJoinScreenTestTags.ACCOUNT_ENTRY).assertIsDisplayed()
        composeTestRule.onNodeWithTag(EventJoinScreenTestTags.nearbyEventCard(nearby.eventCodeHashHex))
            .assertIsDisplayed()
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

    @Test fun emptyLight() {
        launch()
        composeTestRule.onNodeWithTag("home_empty_collection").assertIsDisplayed()
        capture("home-empty-light")
    }

    @Test fun collectionLight() {
        seedCollection()
        launch()
        composeTestRule.onAllNodesWithTag("home_event_group").assertCountEquals(3)
        capture("home-collection-light") // Account action is included in this frame.
    }

    @Test @Config(qualifiers = "+night") fun collectionDark() {
        seedCollection()
        launch(dark = true)
        capture("home-collection-dark")
    }

    @Test fun collectionLargeFont() {
        seedCollection()
        launch(fontScale = 1.5f)
        capture("home-collection-large-font")
    }

    @Test fun eventRecordsList() {
        val records = seedCollection()
        launch()
        composeTestRule.onNodeWithTag("home_group_${records[1].id}").performScrollTo().performClick()
        records.subList(1, 4).forEach {
            composeTestRule.onNodeWithTag(RecordsScreenTestTags.recordRow(it.id)).assertIsDisplayed()
        }
        composeTestRule.onNodeWithTag(RecordsScreenTestTags.recordRow(records[0].id)).assertDoesNotExist()
        composeTestRule.onNodeWithTag(RecordsScreenTestTags.recordRow(records[4].id)).assertDoesNotExist()
        capture("event-records-list")
    }
}
