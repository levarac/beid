package org.levarac.beid.ui.screens

import android.graphics.Bitmap
import android.graphics.Canvas
import android.view.View
import androidx.activity.ComponentActivity
import androidx.compose.ui.platform.ComposeView
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithText
import java.io.File
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.levarac.beid.sensing.EventJoinUiState
import org.levarac.beid.sensing.ScanPhase
import org.levarac.beid.ui.theme.BeidAppTheme
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/** Opt in with -Dbeid.scanScreenshotDir; PNGs are evidence, never repository assets. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], qualifiers = "w412dp-h892dp-mdpi")
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class ScanCloseScreenshotTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

    @Test fun captureScanWithClose() {
        val directory = System.getProperty("beid.scanScreenshotDir").orEmpty()
        assumeTrue("Screenshot output is opt-in", directory.isNotBlank())
        lateinit var view: ComposeView
        compose.runOnUiThread {
            view = ComposeView(compose.activity)
            compose.activity.setContentView(view)
            view.setContent {
                BeidAppTheme {
                    EventJoinContent(
                        state = EventJoinScreenState(sessionState = EventJoinUiState.Sensing(ScanPhase.Sensing)),
                        onOpenAccount = {},
                        onJoinNearbyEvent = {},
                        onOpenSettings = {},
                        onSimulateSignalLost = {},
                        onResumeSensing = {},
                    )
                }
            }
        }
        compose.onNodeWithText("Close").assertIsDisplayed()
        compose.runOnIdle {
            view.measure(
                View.MeasureSpec.makeMeasureSpec(412, View.MeasureSpec.EXACTLY),
                View.MeasureSpec.makeMeasureSpec(892, View.MeasureSpec.EXACTLY),
            )
            view.layout(0, 0, 412, 892)
            val bitmap = Bitmap.createBitmap(412, 892, Bitmap.Config.ARGB_8888)
            view.draw(Canvas(bitmap))
            val output = File(directory, "scan-sensing-close.png")
            output.parentFile.mkdirs()
            output.outputStream().use { check(bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)) }
            bitmap.recycle()
        }
    }
}
