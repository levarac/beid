package org.levarac.beid.ui.designsystem

import android.graphics.Bitmap
import android.graphics.Canvas
import androidx.activity.ComponentActivity
import androidx.compose.foundation.layout.Box
import androidx.compose.runtime.Composable
import androidx.compose.ui.platform.ComposeView
import androidx.compose.ui.test.junit4.AndroidComposeTestRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.test.ext.junit.rules.ActivityScenarioRule
import kotlin.math.roundToInt

/**
 * Draws a composition into a bitmap and crops it to one tagged node.
 *
 * `captureToImage()` goes through PixelCopy, whose forced redraw waits for a
 * frame Robolectric never supplies (see CollectionHomeScreenshotTest), so the
 * attached ComposeView is drawn directly instead. Needs NATIVE graphics.
 */
internal fun AndroidComposeTestRule<ActivityScenarioRule<ComponentActivity>, ComponentActivity>.captureNode(
    tag: String,
    content: @Composable () -> Unit,
): Bitmap {
    lateinit var view: ComposeView
    runOnUiThread {
        view = ComposeView(activity)
        activity.setContentView(view)
        // The root child is measured at the window's exact size; a Box lets the
        // component keep its own size.
        view.setContent { Box { content() } }
    }
    waitForIdle()
    val bounds = onNodeWithTag(tag, useUnmergedTree = true).fetchSemanticsNode().boundsInRoot
    val full = runOnIdle {
        check(view.width > 0 && view.height > 0)
        Bitmap.createBitmap(view.width, view.height, Bitmap.Config.ARGB_8888).also { view.draw(Canvas(it)) }
    }
    return Bitmap.createBitmap(
        full,
        bounds.left.roundToInt(),
        bounds.top.roundToInt(),
        bounds.width.roundToInt(),
        bounds.height.roundToInt(),
    )
}
