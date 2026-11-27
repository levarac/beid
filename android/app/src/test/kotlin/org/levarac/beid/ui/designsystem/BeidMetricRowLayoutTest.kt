package org.levarac.beid.ui.designsystem

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.width
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import kotlin.math.abs
import kotlin.test.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.levarac.beid.ui.theme.BeidAppTheme
import org.levarac.beid.ui.theme.BeidSpacing
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * Where [BeidMetricRow] puts its label and value. These run in native
 * graphics mode because Robolectric's legacy mode measures every character
 * as 1 px wide, so "Peers verified" fits in 14 px and no width is ever
 * narrow enough to show the defect below.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class BeidMetricRowLayoutTest {
    @get:Rule
    val composeTestRule = createComposeRule()

    /**
     * PR #928 review finding: at fontScale 2 a Records event row leaves about
     * 136 dp for its text column (280 dp window − 2 × 24 dp page margin −
     * 2 × 16 dp panel padding − 48 dp Sigil slot − 16 dp gap). The label was
     * measured first with all of that width, wrapped to fill it, and the peer
     * count got next to no width. iOS's `BeidMetricRow` wraps both texts and
     * never drops the value; Android must not either.
     */
    @Test
    fun keepsValueVisibleAtLargeFontInNarrowRow() {
        setRow(width = 136.dp, fontScale = 2f, label = "Peers verified", value = "12")

        composeTestRule.onNodeWithText("Peers verified").assertIsDisplayed()
        composeTestRule.onNodeWithText("12").assertIsDisplayed()
        val row = bounds(ROW_TAG)
        val label = textBounds("Peers verified")
        val value = textBounds("12")
        assertTrue(
            value.width >= valueSingleLineWidth - EPSILON,
            "value keeps its whole single-line width ($valueSingleLineWidth px): $value",
        )
        assertTrue(abs(value.right - row.right) <= EPSILON, "value is end-aligned: $value vs row $row")
        assertTrue(
            value.left - label.right >= BeidSpacing.m.toPx() - EPSILON,
            "at least BeidSpacing.m between label $label and value $value",
        )
    }

    @Test
    fun keepsLabelAtStartAndValueAtEndAtNormalWidth() {
        setRow(width = 320.dp, fontScale = 1f, label = "Peers verified", value = "12")

        val row = bounds(ROW_TAG)
        val label = textBounds("Peers verified")
        val value = textBounds("12")
        assertTrue(abs(label.left - row.left) <= EPSILON, "label starts at the row's start: $label vs $row")
        assertTrue(abs(value.right - row.right) <= EPSILON, "value ends at the row's end: $value vs $row")
        assertTrue(abs(label.top - value.top) <= EPSILON, "label and value share the row's top: $label vs $value")
    }

    /** The value's unconstrained width in its own style, measured in the row's composition. */
    private var valueSingleLineWidth = 0f

    private fun setRow(width: Dp, fontScale: Float, label: String, value: String) {
        composeTestRule.setContent {
            val density = LocalDensity.current
            CompositionLocalProvider(
                LocalDensity provides Density(density = density.density, fontScale = fontScale),
            ) {
                BeidAppTheme {
                    val measurer = rememberTextMeasurer()
                    valueSingleLineWidth =
                        measurer.measure(value, MaterialTheme.typography.titleMedium).size.width.toFloat()
                    Box(Modifier.width(width)) {
                        BeidMetricRow(label = label, value = value, modifier = Modifier.testTag(ROW_TAG))
                    }
                }
            }
        }
    }

    private fun bounds(tag: String): Rect =
        composeTestRule.onNodeWithTag(tag, useUnmergedTree = true).fetchSemanticsNode().boundsInRoot

    private fun textBounds(text: String): Rect =
        composeTestRule.onNodeWithText(text, useUnmergedTree = true).fetchSemanticsNode().boundsInRoot

    private fun Dp.toPx(): Float = value * composeTestRule.density.density

    private companion object {
        const val ROW_TAG = "metric-row"
        const val EPSILON = 0.5f
    }
}
