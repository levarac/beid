package org.levarac.beid.ui.screens

import android.graphics.Bitmap
import android.graphics.Canvas
import androidx.activity.ComponentActivity
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.platform.ComposeView
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.unit.Density
import java.io.File
import java.time.Instant
import java.util.UUID
import org.junit.Assume.assumeTrue
import org.junit.BeforeClass
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.levarac.beid.persistence.ProofRecord
import org.levarac.beid.shared.report.UnsentWindowSubmissionSummary
import org.levarac.beid.ui.theme.BeidAppTheme
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * Opt-in review renders of the Records tab content, the Records list and
 * Today, composed directly (not through the navigation graph).
 *
 * Same opt-in contract as `navigation/CollectionHomeScreenshotTest`: pass
 * -Dbeid.screenshots.dir=<absolute-directory> to the TEST JVM through
 * JAVA_TOOL_OPTIONS and pin -Duser.timezone=UTC. Without the property the
 * class is skipped before any rule setup.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], qualifiers = "en-rUS-w411dp-h891dp-xxhdpi")
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class RecordsHomeScreenshotTest {
    @get:Rule val composeTestRule = createAndroidComposeRule<ComponentActivity>()
    private lateinit var screenshotView: ComposeView

    companion object {
        @JvmStatic @BeforeClass fun requireOptIn() {
            assumeTrue("Review screenshots are opt-in", !System.getProperty("beid.screenshots.dir").isNullOrBlank())
        }
    }

    private fun record(index: Int, code: String, date: String, name: String, peers: Int) = ProofRecord(
        id = UUID.fromString("00000000-0000-0000-0000-%012d".format(index)),
        eventCode = code,
        createdAt = Instant.parse(date),
        peersVerified = peers,
        eventName = name,
    )

    /** Same fixture as `CollectionHomeScreenshotTest`: three events, one with three sessions. */
    private val collection = listOf(
        record(1, "morning-meetup", "2026-10-24T09:30:00Z", "Morning meetup", 8),
        record(2, "design-review", "2026-10-23T15:45:00Z", "Design review", 6),
        record(3, " DESIGN-REVIEW ", "2026-10-23T14:30:00Z", "Design review", 4),
        record(4, "design-review", "2026-10-23T13:00:00Z", "Design review", 3),
        record(5, "community-workshop", "2026-10-21T11:00:00Z", "Community workshop", 12),
    )

    private val submission = UnsentWindowSubmissionSummary(queued = 2, accepted = 3)

    private fun render(name: String, fontScale: Float = 1f, content: @Composable () -> Unit) {
        composeTestRule.runOnUiThread {
            screenshotView = ComposeView(composeTestRule.activity)
            composeTestRule.activity.setContentView(screenshotView)
            screenshotView.setContent {
                CompositionLocalProvider(LocalDensity provides Density(LocalDensity.current.density, fontScale)) {
                    BeidAppTheme { content() }
                }
            }
        }
        capture(name)
    }

    private fun capture(name: String) {
        composeTestRule.waitForIdle()
        // PixelCopy's forceRedraw waits for a frame Robolectric never supplies.
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
        val file = File(directory, "$name.png")
        check(!file.exists()) { "Refusing to overwrite ${file.path}" }
        file.outputStream().use {
            check(bitmap.compress(Bitmap.CompressFormat.PNG, 100, it))
        }
        println("Screenshot: $name.png ${bitmap.width}x${bitmap.height}")
    }

    @Test fun todayLight() = render("today-light") {
        TodaySummaryScreen(recordCount = 2, submissionStatus = submission)
    }

    @Test fun todayLargeFont() = render("today-large-font", fontScale = 1.5f) {
        TodaySummaryScreen(recordCount = 2, submissionStatus = submission)
    }

    @Test fun recordsListEmpty() = render("records-list-empty") {
        RecordsScreen(records = emptyList())
    }

    @Test fun recordsListWithRecords() = render("records-list-with-records") {
        RecordsScreen(records = collection.map(ProofRecord::toRecordListItem))
    }

    private val groups get() = homeProofRecordGroups(collection, activeEventCode = null)

    @Composable private fun RecordsHome(groups: List<List<ProofRecord>>) =
        RecordsHomeScreen(groups = groups, onOpenRecord = {}, onOpenByEvent = {}, onOpenToday = {})

    @Test fun recordsHomeEmpty() = render("records-home-empty") { RecordsHome(emptyList()) }

    @Test fun recordsHomeEvents() = render("records-home-events") { RecordsHome(groups) }

    @Test fun recordsHomeLargeFont() = render("records-home-large-font", fontScale = 1.5f) { RecordsHome(groups) }

    /** At 2.0x the grid drops to one column (iOS accessibility sizes). */
    @Test fun recordsHomeLargestFont() = render("records-home-largest-font", fontScale = 2f) { RecordsHome(groups) }

    @Test fun recordsByEvent() = render("records-by-event") {
        RecordsByEventScreen(groups = groups, onOpenEventRecords = {})
    }

    @Test fun recordsByEventLargeFont() = render("records-by-event-large-font", fontScale = 1.5f) {
        RecordsByEventScreen(groups = groups, onOpenEventRecords = {})
    }
}
