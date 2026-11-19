package org.levarac.beid.ui.designsystem

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.view.View
import androidx.activity.ComponentActivity
import androidx.compose.runtime.Composable
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.core.graphics.Insets
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import org.junit.After
import org.junit.Assume.assumeTrue
import org.junit.BeforeClass
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.levarac.beid.ui.screens.BluetoothOffScreen
import org.levarac.beid.ui.theme.BeidAppTheme
import org.levarac.beid.venue.VenueController
import org.levarac.beid.venue.VenueImportOutcome
import org.levarac.beid.venue.VenueScreen
import org.levarac.beid.venue.VenueTestRadio
import org.levarac.beid.venue.venueTestPack
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * Opt-in review renders of [BeidScreen] callers on an edge-to-edge window with
 * simulated system-bar insets. Pass -Dbeid.insets.screenshotDir=<absolute-directory>
 * to the TEST JVM (e.g. through JAVA_TOOL_OPTIONS; Gradle does not forward -D flags
 * to test workers). Skipped when the property is absent.
 *
 * The inset strips are drawn over the render in translucent red after capture —
 * Robolectric draws no system bars — so anything under red would be hidden on a
 * device. The geometry approximates a Pixel 7a in portrait at 1 px = 1 dp.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], qualifiers = "w412dp-h915dp-mdpi")
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class BeidScreenInsetsScreenshotTest {
    @get:Rule
    val compose = createAndroidComposeRule<ComponentActivity>()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private lateinit var hostView: View

    @After fun close() { scope.cancel() }

    companion object {
        private const val STATUS_BAR_PX = 48
        private const val NAV_BAR_PX = 24

        @JvmStatic @BeforeClass fun requireOptIn() {
            assumeTrue("Inset renders are opt-in", !System.getProperty("beid.insets.screenshotDir").isNullOrBlank())
        }
    }

    @Test fun venueReady() {
        val controller = VenueController(
            object : org.levarac.beid.venue.VenuePackImporter {
                override suspend fun import(link: String): VenueImportOutcome = VenueImportOutcome.Ready(venueTestPack())
            },
            VenueTestRadio(), scope)
        render { VenueScreen(controller) }
        compose.runOnIdle { controller.useLink("https://venue.example/#test") }
        capture("venue-ready")
    }

    @Test fun bluetoothOff() {
        render { BluetoothOffScreen(onOpenSettings = {}, onTurnedOn = {}) }
        capture("bluetooth-off")
    }

    private fun render(screen: @Composable () -> Unit) {
        compose.setContent {
            hostView = LocalView.current
            BeidAppTheme { screen() }
        }
        compose.runOnIdle {
            ViewCompat.dispatchApplyWindowInsets(
                hostView,
                WindowInsetsCompat.Builder()
                    .setInsets(WindowInsetsCompat.Type.statusBars(), Insets.of(0, STATUS_BAR_PX, 0, 0))
                    .setInsets(WindowInsetsCompat.Type.navigationBars(), Insets.of(0, 0, 0, NAV_BAR_PX))
                    .build(),
            )
        }
        compose.waitForIdle()
    }

    private fun capture(name: String) {
        compose.waitForIdle()
        compose.runOnIdle {
            val bitmap = Bitmap.createBitmap(hostView.width, hostView.height, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(bitmap)
            hostView.draw(canvas)
            val bar = Paint().apply { color = 0x66FF0000 }
            canvas.drawRect(0f, 0f, hostView.width.toFloat(), STATUS_BAR_PX.toFloat(), bar)
            canvas.drawRect(0f, (hostView.height - NAV_BAR_PX).toFloat(), hostView.width.toFloat(), hostView.height.toFloat(), bar)
            val file = File(requireNotNull(System.getProperty("beid.insets.screenshotDir")), "$name.png")
            file.parentFile?.mkdirs()
            file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
            bitmap.recycle()
        }
    }
}
