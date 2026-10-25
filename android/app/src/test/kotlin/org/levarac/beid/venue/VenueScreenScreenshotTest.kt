package org.levarac.beid.venue

import android.graphics.Bitmap
import android.graphics.Canvas
import android.view.View
import android.view.ViewGroup
import androidx.activity.ComponentActivity
import androidx.compose.ui.platform.ComposeView
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import kotlinx.coroutines.awaitCancellation
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import org.junit.After
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.levarac.beid.ui.theme.BeidAppTheme
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/** Opt-in PNG output; always draws the real Compose screen without devices or network. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], qualifiers = "w412dp-h1000dp-mdpi")
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class VenueScreenScreenshotTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    @After fun close() { scope.cancel() }

    @Test fun empty() = capture("empty")
    @Test fun ready() = capture("ready", VenueImportOutcome.Ready(venueTestPack()))
    @Test fun broadcasting() = capture("broadcast-requested", VenueImportOutcome.Ready(venueTestPack()), start = true)
    @Test fun mismatch() = capture("link-pack-mismatch", VenueImportOutcome.LinkPackMismatch)
    @Test fun blocked() = capture("not-started", VenueImportOutcome.NotReady("notStarted"))
    @Test fun stopped() = capture("stopped", VenueImportOutcome.Ready(venueTestPack()), start = true, stop = true)
    @Test fun unreadable() = capture("invalid-link", VenueImportOutcome.LinkUnreadable)

    @Test fun getting() = capture("getting", waitStage = VenueImportStage.GETTING)
    @Test fun checking() = capture("checking", waitStage = VenueImportStage.CHECKING)
    @Test fun qrUnavailable() = capture("qr-unavailable", scan = true)
    @Test fun addressMissing() = capture("missing-pack-address", VenueImportOutcome.BundleAddressMissing)
    @Test fun addressUnsupported() = capture("insecure-pack-address", VenueImportOutcome.BundleAddressUnsupported)
    @Test fun pendingPack() = capture("pending-pack", VenueImportOutcome.Ready(venueTestPack()), start = true, replace = true)
    @Test fun permissionPending() = capture("bluetooth-permission-pending", VenueImportOutcome.Ready(venueTestPack()), start = true, waitPermission = true)

    private fun capture(
        name: String, outcome: VenueImportOutcome? = null, start: Boolean = false, stop: Boolean = false,
        waitStage: VenueImportStage? = null, scan: Boolean = false, replace: Boolean = false, waitPermission: Boolean = false,
    ) {
        var result = outcome
        val importer = object : VenuePackImporter {
            override suspend fun import(link: String): VenueImportOutcome = requireNotNull(result)
            override suspend fun import(link: String, onProgress: (VenueImportProgress) -> Unit): VenueImportOutcome {
                if (waitStage != null) {
                    onProgress(VenueImportProgress(venueTestPack().eventIdHex, waitStage))
                    awaitCancellation()
                }
                return import(link)
            }
        }
        val controller = VenueController(importer, VenueTestRadio().apply { deferPermission = waitPermission }, scope)
        compose.setContent { BeidAppTheme { VenueScreen(controller) } }
        compose.runOnIdle { if (outcome != null || waitStage != null) controller.useLink("https://venue.example/#test") }
        compose.waitForIdle()
        compose.runOnIdle { if (start) controller.start() }
        compose.waitForIdle()
        compose.runOnIdle { if (stop) controller.stop() }
        compose.waitForIdle()
        if (scan) compose.onNodeWithTag("venue-scan").performClick()
        compose.runOnIdle {
            if (replace) {
                result = VenueImportOutcome.Ready(venueTestPack().copy(displayName = "Next Event", eventIdHex = "04".repeat(32)))
                controller.useLink("https://venue.example/#next")
            }
        }
        compose.waitForIdle()
        compose.runOnIdle {
            val view = requireNotNull(findComposeView(compose.activity.window.decorView))
            kotlin.test.assertTrue(view.width > 0 && view.height > 0)
            val bitmap = Bitmap.createBitmap(view.width, view.height, Bitmap.Config.ARGB_8888)
            view.draw(Canvas(bitmap))
            kotlin.test.assertTrue(bitmap.getPixel(0, 0) != 0, "The screen must be painted")
            System.getProperty("beid.venue.screenshotDir")?.let { directory ->
                val file = File(directory, "venue-$name.png")
                file.parentFile?.mkdirs()
                file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
            }
            bitmap.recycle()
        }
    }

    private fun findComposeView(view: View): ComposeView? {
        if (view is ComposeView) return view
        if (view is ViewGroup) for (index in 0 until view.childCount) {
            findComposeView(view.getChildAt(index))?.let { return it }
        }
        return null
    }
}
