package org.levarac.beid.ui.designsystem

import android.graphics.Bitmap
import android.graphics.Canvas
import android.view.View
import androidx.activity.ComponentActivity
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.consumeWindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.systemBars
import androidx.compose.foundation.layout.union
import androidx.compose.foundation.layout.displayCutout
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.unit.dp
import androidx.core.graphics.Insets
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.levarac.beid.ui.theme.BeidAppTheme
import org.levarac.beid.ui.theme.BeidTheme
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * Pins [BeidScreen]'s window-inset contract on an edge-to-edge window
 * (targetSdk 35+ on Android 15+): content and footer stay clear of the
 * status bar, navigation bar and display cutout, the canvas still paints
 * behind the bars, and a parent that already consumed the insets does not
 * get them applied a second time.
 *
 * Robolectric delivers no real system-bar insets, so each test dispatches a
 * synthetic [WindowInsetsCompat] to the Compose host view — the same entry
 * point the platform uses, and the one Compose's inset holder listens on.
 * mdpi (1 px = 1 dp) keeps the pixel arithmetic readable.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], qualifiers = "w400dp-h800dp-mdpi")
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class BeidScreenInsetsTest {
    @get:Rule
    val compose = createAndroidComposeRule<ComponentActivity>()

    private lateinit var hostView: View

    @Test
    fun contentAndFooterClearTheStatusBarNavigationBarAndCutout() {
        compose.setContent {
            hostView = LocalView.current
            BeidAppTheme {
                BeidScreen(
                    modifier = Modifier.testTag(SCREEN),
                    footer = { Text("Footer", Modifier.testTag(FOOTER)) },
                ) {
                    // Taller than the window, so a missing inset cannot hide behind
                    // vertical centering: the content touches both window edges.
                    Box(Modifier.weight(1f).fillMaxWidth().testTag(CONTENT))
                }
            }
        }
        dispatchInsets()

        val root = compose.onRoot().bounds()
        val content = compose.onNodeWithTag(CONTENT).bounds()
        val footer = compose.onNodeWithTag(FOOTER).bounds()

        assertTrue("content top ${content.top} under the status bar", content.top >= STATUS_BAR_PX)
        assertTrue("content left ${content.left} inside the cutout", content.left >= CUTOUT_LEFT_PX)
        assertTrue(
            "footer bottom ${footer.bottom} under the navigation bar (root ${root.bottom})",
            footer.bottom <= root.bottom - NAV_BAR_PX,
        )
        // The screen itself still spans the whole window, so the canvas is behind the bars.
        assertEquals(0f, compose.onNodeWithTag(SCREEN).bounds().top)
    }

    @Test
    fun canvasPaintsBehindTheStatusAndNavigationBars() {
        var canvas = 0
        compose.setContent {
            hostView = LocalView.current
            BeidAppTheme {
                canvas = BeidTheme.colors.surfaceCanvas.toArgb()
                BeidScreen(footer = { Text("Footer") }) { Text("Content") }
            }
        }
        dispatchInsets()

        compose.runOnIdle {
            val bitmap = Bitmap.createBitmap(hostView.width, hostView.height, Bitmap.Config.ARGB_8888)
            hostView.draw(Canvas(bitmap))
            val midX = hostView.width / 2
            assertEquals("status-bar strip unpainted", canvas, bitmap.getPixel(midX, STATUS_BAR_PX / 2))
            assertEquals("nav-bar strip unpainted", canvas, bitmap.getPixel(midX, hostView.height - NAV_BAR_PX / 2))
            assertEquals("cutout strip unpainted", canvas, bitmap.getPixel(CUTOUT_LEFT_PX / 2, hostView.height / 2))
            bitmap.recycle()
        }
    }

    @Test
    fun parentThatConsumedTheInsetsIsNotPaddedTwice() {
        compose.setContent {
            hostView = LocalView.current
            BeidAppTheme {
                Box(Modifier.fillMaxSize().windowInsetsPadding(WindowInsets.systemBars.union(WindowInsets.displayCutout))) {
                    BeidScreen(footer = { Text("Footer", Modifier.testTag(FOOTER)) }) {
                        Box(Modifier.weight(1f).fillMaxWidth().testTag(CONTENT))
                    }
                }
            }
        }
        dispatchInsets()

        val root = compose.onRoot().bounds()
        val content = compose.onNodeWithTag(CONTENT).bounds()
        val footer = compose.onNodeWithTag(FOOTER).bounds()

        // Content's own top is the parent's inset exactly — a second application
        // would put it at 2 × STATUS_BAR_PX.
        assertEquals(STATUS_BAR_PX.toFloat(), content.top)
        assertEquals((root.bottom - NAV_BAR_PX), footer.bottom)
    }

    @Test
    fun scaffoldThatConsumesItsInnerPaddingIsNotPaddedTwice() {
        compose.setContent {
            hostView = LocalView.current
            BeidAppTheme {
                Scaffold(
                    topBar = {
                        // Like TopAppBar, the bar pads itself by the status bar.
                        Box(Modifier.fillMaxWidth().windowInsetsPadding(WindowInsets.statusBars).height(TOP_BAR_DP.dp))
                    },
                ) { innerPadding ->
                    BeidScreen(
                        modifier = Modifier.padding(innerPadding).consumeWindowInsets(innerPadding),
                        footer = { Text("Footer", Modifier.testTag(FOOTER)) },
                    ) {
                        Box(Modifier.weight(1f).fillMaxWidth().testTag(CONTENT))
                    }
                }
            }
        }
        dispatchInsets()

        val root = compose.onRoot().bounds()
        val content = compose.onNodeWithTag(CONTENT).bounds()
        val footer = compose.onNodeWithTag(FOOTER).bounds()

        // innerPadding.top is the top bar (status bar + bar), and Scaffold's content
        // insets supply the nav bar; consuming innerPadding leaves BeidScreen nothing to add.
        assertEquals((STATUS_BAR_PX + TOP_BAR_DP).toFloat(), content.top)
        assertEquals((root.bottom - NAV_BAR_PX), footer.bottom)
    }

    private fun dispatchInsets() {
        compose.runOnIdle {
            val insets = WindowInsetsCompat.Builder()
                .setInsets(WindowInsetsCompat.Type.statusBars(), Insets.of(0, STATUS_BAR_PX, 0, 0))
                .setInsets(WindowInsetsCompat.Type.navigationBars(), Insets.of(0, 0, 0, NAV_BAR_PX))
                .setInsets(WindowInsetsCompat.Type.displayCutout(), Insets.of(CUTOUT_LEFT_PX, 0, 0, 0))
                .build()
            ViewCompat.dispatchApplyWindowInsets(hostView, insets)
        }
        compose.waitForIdle()
    }

    private fun androidx.compose.ui.test.SemanticsNodeInteraction.bounds(): Rect =
        fetchSemanticsNode().boundsInRoot

    private companion object {
        const val SCREEN = "screen"
        const val CONTENT = "content"
        const val FOOTER = "footer"
        const val STATUS_BAR_PX = 40
        const val NAV_BAR_PX = 48
        const val CUTOUT_LEFT_PX = 30
        const val TOP_BAR_DP = 64
    }
}
