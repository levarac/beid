package org.levarac.beid.ui.theme

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Pins the Flat 2b tokens to iOS's values (`ios/Beid/DesignSystem/Tokens.swift`
 * and `Colors.xcassets`). Every expected value is a literal, never a reference
 * to a production constant, so changing a token's value turns this test red.
 */
class Flat2bTokensTest {

    @Test
    fun libraryPrimitivesEqualTheIosColorsets() {
        assertEquals(Color(0xFF0B0B0F), BeidPalette.Ink)
        assertEquals(Color(0xFFFFFFFF), BeidPalette.Bg)
        assertEquals(Color(0xFF6E6E78), BeidPalette.Sub)
        assertEquals(Color(0xFFECECF1), BeidPalette.Line)
        assertEquals(Color(0xFFC9C9CF), BeidPalette.LineDashed)
        assertEquals(Color(0xFFF2F2F4), BeidPalette.Tile)
        assertEquals(Color(0xFFD9D9DE), BeidPalette.ChartMuted)
        assertEquals(Color(0xFF8E8E96), BeidPalette.OnInkSub)
        assertEquals(Color(0xFF2A2A31), BeidPalette.OnInkLine)
        assertEquals(Color(0xFF5C5C66), BeidPalette.OnInkIdle)
        assertEquals(Color(0xFFFF453A), BeidPalette.SemanticRed)
        assertEquals(Color(0xFFFF9F0A), BeidPalette.SemanticAmber)
        assertEquals(Color(0xFF30D158), BeidPalette.SemanticGreen)
    }

    @Test
    fun roleTokensMapToTheSamePrimitivesAsIosDsColor() {
        // ink 0B0B0F
        assertEquals(Color(0xFF0B0B0F), BeidColors.textPrimary)
        assertEquals(Color(0xFF0B0B0F), BeidColors.actionPrimary)
        assertEquals(Color(0xFF0B0B0F), BeidColors.labelOnActionInverse)
        // bg FFFFFF
        assertEquals(Color(0xFFFFFFFF), BeidColors.surfaceCanvas)
        assertEquals(Color(0xFFFFFFFF), BeidColors.labelOnActionPrimary)
        assertEquals(Color(0xFFFFFFFF), BeidColors.actionInverse)
        // sub, line, line-dashed, tile, chart-muted
        assertEquals(Color(0xFF6E6E78), BeidColors.textSecondary)
        assertEquals(Color(0xFFECECF1), BeidColors.strokeHairline)
        assertEquals(Color(0xFFC9C9CF), BeidColors.strokeEmptyState)
        assertEquals(Color(0xFFF2F2F4), BeidColors.surfaceTile)
        assertEquals(Color(0xFFD9D9DE), BeidColors.chartDetected)
        // on-ink/*
        assertEquals(Color(0xFF8E8E96), BeidColors.textSecondaryOnInk)
        assertEquals(Color(0xFF2A2A31), BeidColors.strokeHairlineOnInk)
        assertEquals(Color(0xFF5C5C66), BeidColors.graphNodeIdle)
        // semantic/*
        assertEquals(Color(0xFF30D158), BeidColors.statusOn)
        assertEquals(Color(0xFFFF9F0A), BeidColors.statusPending)
        assertEquals(Color(0xFFFF453A), BeidColors.statusOff)
    }

    @Test
    fun materialSlotsReadTheRoleTokens() {
        val scheme = beidMaterialColorScheme(BeidColors)
        assertEquals(Color(0xFFFFFFFF), scheme.background)
        assertEquals(Color(0xFF0B0B0F), scheme.onBackground)
        assertEquals(Color(0xFFFFFFFF), scheme.surface)
        assertEquals(Color(0xFF0B0B0F), scheme.onSurface)
        assertEquals(Color(0xFF6E6E78), scheme.onSurfaceVariant)
        assertEquals(Color(0xFF0B0B0F), scheme.primary)
        assertEquals(Color(0xFFFFFFFF), scheme.onPrimary)
        assertEquals(Color(0xFFECECF1), scheme.outline)
        assertEquals(Color(0xFFECECF1), scheme.outlineVariant)
    }

    @Test
    fun spacingEqualsIosDsSpace() {
        assertEquals(4.dp, BeidSpacing.xs)
        assertEquals(8.dp, BeidSpacing.s)
        assertEquals(16.dp, BeidSpacing.m)
        assertEquals(24.dp, BeidSpacing.l)
        assertEquals(32.dp, BeidSpacing.xl)
        assertEquals(48.dp, BeidSpacing.xxl)
        assertEquals(24.dp, BeidSpacing.pageMargin)
        assertEquals(40.dp, BeidSpacing.emptyBlockVertical)
    }

    @Test
    fun radiusEqualsIosDsRadius() {
        assertEquals(12.dp, BeidRadius.control)
        assertEquals(16.dp, BeidRadius.card)
        assertEquals(28.dp, BeidRadius.seal)
        assertEquals(999.dp, BeidRadius.pill)
        assertEquals(16.dp, BeidRadius.emptyBlock)
        assertEquals(20.dp, BeidRadius.nowCard)
    }

    @Test
    fun androidOnlyAndSharedSizesKeepTheirValues() {
        assertEquals(24.dp, BeidRadius.glyph)
        assertEquals(72.dp, BeidSize.glyph)
        assertEquals(8.dp, BeidSize.statusDot)
        assertEquals(32.dp, BeidSize.bulletIcon)
        assertEquals(28.dp, BeidSize.stepBadge)
    }
}
