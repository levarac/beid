package org.levarac.beid.ui.theme

import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontListFontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.font.ResourceFont
import androidx.compose.ui.text.style.LineHeightStyle
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.em
import androidx.compose.ui.unit.sp
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Test
import org.levarac.beid.R

/**
 * Pins every Flat 2b Library style, role and Material slot with literals,
 * copied from iOS `DS.Font` (ios/Beid/DesignSystem/Tokens.swift) and
 * DESIGN.md §6 — never by reference to the production constants, so a
 * regressed value turns a test red instead of moving both sides at once.
 */
class BeidTypographyTest {

    private data class Expected(
        val name: String,
        val style: BeidTextStyle,
        val fontRes: Int,
        val weight: FontWeight,
        val size: Float,
        val tracking: Float,
        val lineHeight: Float?,
        val uppercase: Boolean,
        val tabular: Boolean,
    )

    private val library = BeidFont.Library
    private val bold = FontWeight.Bold
    private val regular = FontWeight.Normal
    private val extraBold = FontWeight.ExtraBold
    private val medium = FontWeight.Medium

    private val expected = listOf(
        Expected("display60", library.display60, R.font.bricolage_grotesque_display60_extrabold, extraBold, 60f, -0.02f, 1.0f, false, false),
        Expected("display52", library.display52, R.font.bricolage_grotesque_display52_extrabold, extraBold, 52f, -0.02f, 1.0f, false, false),
        Expected("display46", library.display46, R.font.bricolage_grotesque_display46_extrabold, extraBold, 46f, -0.015f, 1.0f, false, false),
        Expected("displayNumber40", library.displayNumber40, R.font.bricolage_grotesque_display40_extrabold, extraBold, 40f, -0.01f, null, false, true),
        Expected("displayAddress34", library.displayAddress34, R.font.bricolage_grotesque_display34_extrabold, extraBold, 34f, -0.01f, null, false, false),
        Expected("title19", library.title19, R.font.dm_sans_bold, bold, 19f, 0f, null, false, false),
        Expected("title17", library.title17, R.font.dm_sans_bold, bold, 17f, 0f, null, false, false),
        Expected("title16", library.title16, R.font.dm_sans_bold, bold, 16f, 0f, null, false, false),
        Expected("title15", library.title15, R.font.dm_sans_bold, bold, 15f, 0f, null, false, false),
        Expected("body15", library.body15, R.font.dm_sans_regular, regular, 15f, 0f, 1.4f, false, false),
        Expected("body13", library.body13, R.font.dm_sans_regular, regular, 13f, 0f, 1.4f, false, false),
        Expected("labelMono11", library.labelMono11, R.font.dm_mono_medium, medium, 11f, 0.08f, null, true, false),
        Expected("labelMono10", library.labelMono10, R.font.dm_mono_medium, medium, 10f, 0.08f, null, true, false),
        Expected("labelMono9", library.labelMono9, R.font.dm_mono_medium, medium, 9f, 0.06f, null, true, false),
        Expected("labelMono10Tight", library.labelMono10Tight, R.font.dm_mono_medium, medium, 10f, 0.06f, null, false, false),
        Expected("labelMono11Time", library.labelMono11Time, R.font.dm_mono_medium, medium, 11f, 0f, null, false, false),
        Expected("labelMono13Value", library.labelMono13Value, R.font.dm_mono_medium, medium, 13f, 0f, null, false, false),
    )

    @Test
    fun libraryHasExactlyTheSeventeenIosStyles() {
        assertEquals(17, expected.size)
        assertEquals(17, expected.map { it.style }.toSet().size)
    }

    @Test
    fun everyLibraryStyleCarriesTheSpecValues() {
        for (e in expected) {
            val s = e.style
            assertEquals(e.name, e.fontRes, s.fontRes)
            assertEquals(e.name, e.size, s.sizeSp)
            assertEquals(e.name, e.tracking, s.tracking)
            assertEquals(e.name, e.lineHeight, s.lineHeight)
            assertEquals(e.name, e.uppercase, s.isUppercase)
            assertEquals(e.name, e.tabular, s.usesTabularDigits)
        }
    }

    @Test
    fun everyTextStyleCarriesTheSpecValues() {
        val specLineHeightStyle = LineHeightStyle(
            alignment = LineHeightStyle.Alignment.Center,
            trim = LineHeightStyle.Trim.None,
            mode = LineHeightStyle.Mode.Fixed,
        )
        for (e in expected) {
            val t = e.style.textStyle
            assertEquals(e.name, e.size.sp, t.fontSize)
            assertEquals(e.name, e.weight, t.fontWeight)
            assertEquals(e.name, e.tracking.em, t.letterSpacing)
            if (e.lineHeight == null) {
                assertEquals(e.name, TextUnit.Unspecified, t.lineHeight)
                assertNull(e.name, t.lineHeightStyle)
            } else {
                assertEquals(e.name, e.lineHeight.em, t.lineHeight)
                assertEquals(e.name, specLineHeightStyle, t.lineHeightStyle)
            }
            assertEquals(e.name, if (e.tabular) "tnum" else null, t.fontFeatureSettings)
            assertEquals(e.name, e.fontRes to e.weight, faceOf(t, e.weight))
        }
    }

    @Test
    fun displayCutsAreSeparateFamiliesAndDmSansSharesOneFamilyOfBothWeights() {
        fun fontsOf(style: BeidTextStyle) =
            (style.textStyle.fontFamily as FontListFontFamily).fonts
                .map { (it as ResourceFont).resId to it.weight }.toSet()

        assertEquals(setOf(R.font.bricolage_grotesque_display60_extrabold to extraBold), fontsOf(library.display60))
        assertEquals(setOf(R.font.bricolage_grotesque_display52_extrabold to extraBold), fontsOf(library.display52))
        assertEquals(setOf(R.font.bricolage_grotesque_display46_extrabold to extraBold), fontsOf(library.display46))
        assertEquals(setOf(R.font.bricolage_grotesque_display40_extrabold to extraBold), fontsOf(library.displayNumber40))
        assertEquals(setOf(R.font.bricolage_grotesque_display34_extrabold to extraBold), fontsOf(library.displayAddress34))
        val dmSans = setOf(R.font.dm_sans_regular to regular, R.font.dm_sans_bold to bold)
        assertEquals(dmSans, fontsOf(library.title19))
        assertEquals(dmSans, fontsOf(library.body15))
        assertSame(library.title19.textStyle.fontFamily, library.body13.textStyle.fontFamily)
        assertEquals(setOf(R.font.dm_mono_medium to medium), fontsOf(library.labelMono11))
    }

    @Test
    fun casedUppercasesOnlyTheThreeLabelStyles() {
        val address = "0xAbC123def"
        for (e in expected) {
            val want = if (e.uppercase) "0XABC123DEF" else address
            assertEquals(e.name, want, e.style.cased(address))
        }
    }

    @Test
    fun rolesPointAtTheSameLibraryStylesAsIos() {
        assertSame(library.display46, BeidFont.screenTitle)
        assertSame(library.title19, BeidFont.sectionTitle)
        assertSame(library.title17, BeidFont.cardTitle)
        assertSame(library.body15, BeidFont.body)
        assertSame(library.body13, BeidFont.supporting)
        assertSame(library.body13, BeidFont.meta)
        assertSame(library.labelMono13Value, BeidFont.ledgerMono)
        assertSame(library.title16, BeidFont.cta)
    }

    @Test
    fun everyMaterialSlotMapsToAFlat2bLibraryStyle() {
        val t = BeidTypography
        // Settled: the role each slot already stood for.
        assertSame(library.display46.textStyle, t.headlineLarge)
        assertSame(library.title19.textStyle, t.titleLarge)
        assertSame(library.title17.textStyle, t.titleMedium)
        assertSame(library.body15.textStyle, t.bodyLarge)
        assertSame(library.body13.textStyle, t.bodyMedium)
        assertSame(library.body13.textStyle, t.labelSmall)
        assertSame(library.labelMono13Value.textStyle, t.bodySmall)
        assertSame(library.title16.textStyle, t.labelLarge)
        // Slots without a role, decided in DECISIONS.md 2026-11-18.
        assertSame(library.display52.textStyle, t.headlineMedium)
        assertSame(library.title19.textStyle, t.headlineSmall)
        assertSame(library.title15.textStyle, t.titleSmall)
        assertSame(library.display46.textStyle, t.displayMedium)
        assertSame(library.displayNumber40.textStyle, t.displaySmall)
        assertSame(library.display60.textStyle, t.displayLarge)
        assertSame(library.body13.textStyle, t.labelMedium)
    }

    /** The bundled font a [TextStyle] resolves to at [weight] within its family. */
    private fun faceOf(style: TextStyle, weight: FontWeight): Pair<Int, FontWeight> {
        val family: FontFamily? = style.fontFamily
        val font = (family as FontListFontFamily).fonts.single { it.weight == weight } as ResourceFont
        return font.resId to font.weight
    }
}
