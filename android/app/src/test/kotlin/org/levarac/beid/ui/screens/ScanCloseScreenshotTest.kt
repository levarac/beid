package org.levarac.beid.ui.screens

import android.graphics.Bitmap
import android.graphics.Canvas
import android.view.View
import androidx.activity.ComponentActivity
import androidx.compose.ui.platform.ComposeView
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import java.io.File
import java.time.Instant
import java.util.UUID
import kotlinx.coroutines.flow.MutableStateFlow
import org.levarac.beid.sensing.EventJoinSession
import org.levarac.beid.sensing.ScanEventSession
import org.levarac.beid.sensing.ScanSessionMetrics
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

    @Test fun captureScanWithClose() = capture("scan-sensing-close.png", confirmation = false)

    @Test fun captureStopConfirmation() = capture("scan-stop-confirm.png", confirmation = true)

    private fun capture(filename: String, confirmation: Boolean) {
        val directory = System.getProperty("beid.scanScreenshotDir").orEmpty()
        assumeTrue("Screenshot output is opt-in", directory.isNotBlank())
        val event = ScanEventSession(eventCode = "ABC123", eventName = "beid gathering")
        val fake = FakeEventJoinSession(EventJoinUiState.Sensing(
            if (confirmation) ScanPhase.Recording(event, 12) else ScanPhase.Sensing,
        ))
        val session = object : EventJoinSession by fake {
            override val currentProofId = UUID.fromString("00112233-4455-6677-8899-aabbccddeeff")
            override fun hasStoredProof(proofId: UUID) = proofId == currentProofId
            override val scanSessionMetrics = MutableStateFlow<() -> ScanSessionMetrics>({ ScanSessionMetrics(
                firstSightingAt = Instant.parse("2026-10-25T09:30:00Z"),
                mutualDeviceCount = 4, detectedDeviceCount = 12, windowCount = 3,
            ) })
        }
        val model = EventJoinViewModel(session)
        lateinit var view: ComposeView
        compose.runOnUiThread {
            view = ComposeView(compose.activity)
            compose.activity.setContentView(view)
            view.setContent {
                BeidAppTheme {
                    EventJoinScreen(
                        viewModel = model,
                        onOpenAccount = {},
                        onOpenManualEventCode = {},
                    )
                }
            }
        }
        compose.onNodeWithText("Close").assertIsDisplayed()
        if (confirmation) {
            compose.onNodeWithText("Close").performClick()
            compose.onNodeWithText("Stop sensing?").assertIsDisplayed()
            compose.onNodeWithText("Stop and keep record").assertIsDisplayed()
            compose.onNodeWithText("Keep sensing").assertIsDisplayed()
        }
        compose.runOnIdle {
            view.measure(
                View.MeasureSpec.makeMeasureSpec(412, View.MeasureSpec.EXACTLY),
                View.MeasureSpec.makeMeasureSpec(892, View.MeasureSpec.EXACTLY),
            )
            view.layout(0, 0, 412, 892)
            val bitmap = Bitmap.createBitmap(412, 892, Bitmap.Config.ARGB_8888)
            view.draw(Canvas(bitmap))
            val output = File(directory, filename)
            output.parentFile.mkdirs()
            output.outputStream().use { check(bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)) }
            bitmap.recycle()
        }
    }
}
