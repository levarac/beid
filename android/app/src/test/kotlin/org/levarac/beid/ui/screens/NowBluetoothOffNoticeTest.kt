package org.levarac.beid.ui.screens

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.view.ViewGroup
import androidx.activity.ComponentActivity
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.assertHeightIsEqualTo
import androidx.compose.ui.test.assertWidthIsEqualTo
import androidx.compose.ui.test.hasAnyAncestor
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.text.TextLayoutResult
import androidx.test.core.app.ApplicationProvider
import kotlin.math.abs
import kotlin.test.assertEquals
import kotlin.test.assertNotEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.levarac.beid.R
import org.levarac.beid.navigation.NowStandbyPresentation
import org.levarac.beid.sensing.EventJoinUiState
import org.levarac.beid.ui.theme.BeidAppTheme
import org.levarac.beid.ui.theme.BeidColorScheme
import org.levarac.beid.ui.theme.BeidSize
import org.levarac.beid.ui.theme.BeidSpacing
import org.levarac.beid.ui.theme.BeidTheme
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * Now's "BLUETOOTH OFF · SENSING PAUSED" notice follows DESIGN.md §5's
 * "dots carry color, words carry meaning": on the page ground `statusOff`
 * (3.41:1 on white, under AA for text) colors only a status dot, and the
 * words beside it are `textPrimary`.
 *
 * The text's color is read from what Compose actually laid out (the
 * `GetTextLayoutResult` semantics action's `layoutInput.style`), not from a
 * parameter, so it is the color the text is drawn with. The dot has no
 * semantics to carry a color, so its center pixel is sampled from a native
 * render; the center of an 8dp circle is never an antialiased edge pixel.
 * The composition is drawn onto a Canvas, as `CollectionHomeScreenshotTest`
 * does, because `captureToImage`'s redraw waits for a frame Robolectric
 * never supplies.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class NowBluetoothOffNoticeTest {
    @get:Rule
    val composeTestRule = createAndroidComposeRule<ComponentActivity>()

    private val context: Context get() = ApplicationProvider.getApplicationContext()

    private fun showBluetoothOff(): BeidColorScheme {
        lateinit var colors: BeidColorScheme
        composeTestRule.setContent {
            BeidAppTheme {
                colors = BeidTheme.colors
                NowContent(
                    state = EventJoinScreenState(sessionState = EventJoinUiState.Idle),
                    standby = NowStandbyPresentation(),
                    bluetoothOff = true,
                    onJoinNearbyEvent = {},
                    onOpenCodeEntry = {},
                    onFixBluetooth = {},
                    onOpenBluetoothSettings = {},
                    onOpenSettings = {},
                    onSimulateSignalLost = {},
                    onResumeSensing = {},
                )
            }
        }
        composeTestRule.waitForIdle()
        return colors
    }

    private fun notice() = composeTestRule.onNode(
        hasText(context.getString(R.string.now_bluetooth_off_label), ignoreCase = true) and
            hasAnyAncestor(hasTestTag(NowScreenTestTags.BLUETOOTH_OFF)),
    )

    @Test
    fun theNoticeWordsAreTextPrimaryNotStatusOff() {
        val colors = showBluetoothOff()
        val layouts = mutableListOf<TextLayoutResult>()
        notice().fetchSemanticsNode().config[SemanticsActions.GetTextLayoutResult].action!!.invoke(layouts)
        assertEquals(colors.textPrimary, layouts.single().layoutInput.style.color)
    }

    @Test
    fun aDecorativeStatusOffDotPrecedesTheNotice() {
        val colors = showBluetoothOff()
        val dot = composeTestRule.onNodeWithTag(NowScreenTestTags.BLUETOOTH_OFF_DOT)
        dot.assertWidthIsEqualTo(BeidSize.statusDot).assertHeightIsEqualTo(BeidSize.statusDot)

        val dotNode = dot.fetchSemanticsNode()
        assertNull(dotNode.config.getOrNull(SemanticsProperties.ContentDescription), "The dot is decorative")
        assertNull(dotNode.config.getOrNull(SemanticsProperties.Text), "The dot is decorative")

        // Before the words, on their line, at the status pill's dot-to-label spacing.
        val dotBounds = dotNode.boundsInRoot
        val textBounds = notice().fetchSemanticsNode().boundsInRoot
        val density = composeTestRule.density.density
        assertEquals(BeidSpacing.s.value, (textBounds.left - dotBounds.right) / density, absoluteTolerance = 0.5f)
        val dotCenterY = dotBounds.center.y
        assertTrue(dotCenterY > textBounds.top && dotCenterY < textBounds.bottom, "The dot sits on the notice's line")
        assertTrue(abs(dotCenterY - textBounds.center.y) <= density, "The dot is centered on the notice")

        val composition = composeTestRule.activity.findViewById<ViewGroup>(android.R.id.content).getChildAt(0)
        val render = composeTestRule.runOnIdle {
            Bitmap.createBitmap(composition.width, composition.height, Bitmap.Config.ARGB_8888).also {
                composition.draw(Canvas(it))
            }
        }
        val center = dotBounds.center
        assertEquals(colors.statusOff.toArgb(), render.getPixel(center.x.toInt(), center.y.toInt()))
        // The render is not one flat color: the gap after the dot is not the dot's red.
        val gapX = ((dotBounds.right + textBounds.left) / 2).toInt()
        assertNotEquals(colors.statusOff.toArgb(), render.getPixel(gapX, center.y.toInt()))
    }
}
