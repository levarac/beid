package org.levarac.beid.ui.theme

import androidx.annotation.FontRes
import androidx.compose.material3.Typography
import androidx.compose.runtime.Immutable
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.LineHeightStyle
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.em
import androidx.compose.ui.unit.sp
import org.levarac.beid.R

/**
 * One Flat 2b Library text style — the Android counterpart of iOS
 * `DS.Font.Style` (ios/Beid/DesignSystem/Tokens.swift, DESIGN.md §6).
 *
 * Compose [TextStyle] already carries face, size, tracking, line height and
 * tabular digits, so [textStyle] holds all of those. It has no text-case
 * property, which is why this is a value type rather than a bare
 * [TextStyle]: [isUppercase] travels alongside it and reaches a string
 * only through [cased].
 *
 * **Dynamic Type → plain `sp` (DECISIONS.md 2026-11-18).** iOS scales each
 * style on a chosen Apple text-style curve (every Display style on
 * `.largeTitle`). Android does not emulate those curves: [sizeSp] is plain
 * `sp`, scaled by the system font-scale setting (nonlinear on API 34+).
 * Tracking and line height are in `em`, so they stay proportional to the
 * scaled size the same way iOS computes them at the scaled point size.
 *
 * **Line height → the spec value exactly, on every API level
 * (DECISIONS.md 2026-11-18).** iOS reaches Display's 100% exactly only on
 * iOS 26+ and cannot tighten below the face's own 1.2 em on iOS 17–25
 * (#661); Android does not copy that split. A non-null [lineHeight] is
 * applied as `em` with [SpecLineHeightStyle]:
 * - [LineHeightStyle.Alignment.Center] splits the difference between the
 *   face's own line height and the spec value evenly above and below the
 *   glyphs — half-leading, the model Figma (where the Library's values
 *   come from) and CSS use. For Display's 100% that is −0.1 em on each side.
 * - [LineHeightStyle.Trim.None] keeps that half-leading on the first and
 *   last line, so an n-line text box measures exactly `n × lineHeight`,
 *   the same box height the Library's frames are measured with.
 * - [LineHeightStyle.Mode.Fixed] (Compose's default, stated so it is not
 *   mistaken for an omission) lets the box go below the face's own line
 *   height. `Mode.Minimum` would be "never tighten" — the iOS 17–25
 *   behaviour, which was not chosen.
 * Text is not clipped to its line box, so Display glyphs that rise above a
 * 100% box still draw.
 */
@Immutable
internal class BeidTextStyle(
    /** The bundled face, the counterpart of iOS `postScriptName`. */
    @param:FontRes val fontRes: Int,
    /** Base size in `sp` at the default font scale. */
    val sizeSp: Float,
    /** Letter spacing as a fraction of the size (iOS's tracking value == `em`). */
    val tracking: Float = 0f,
    /** Line height as a multiple of the size; null is the Library's "auto". */
    val lineHeight: Float? = null,
    /** Whether the style renders uppercase. Apply with [cased]. */
    val isUppercase: Boolean = false,
    /** Whether digits are forced to equal width (OpenType `tnum`). */
    val usesTabularDigits: Boolean = false,
) {
    private val face: BundledFace = BundledFace.forResource(fontRes)

    val textStyle: TextStyle = TextStyle(
        fontFamily = face.family,
        fontWeight = face.weight,
        fontSize = sizeSp.sp,
        letterSpacing = tracking.em,
        lineHeight = lineHeight?.em ?: TextUnit.Unspecified,
        lineHeightStyle = if (lineHeight != null) SpecLineHeightStyle else null,
        fontFeatureSettings = if (usesTabularDigits) "tnum" else null,
    )

    /**
     * [text] as this style renders it. Only the three Mono *label* styles
     * uppercase; the value styles never do, because an EIP-55 address
     * carries its checksum in letter case (DESIGN.md §6).
     */
    fun cased(text: String): String = if (isUppercase) text.uppercase() else text

    companion object {
        // Kept here, not as a file-level val: a file-level val lives in
        // TypeKt, whose initializer also builds BeidTypography from
        // BeidFont.Library — a class-initialization cycle in which this
        // would read as null while the Library styles are being built.
        val SpecLineHeightStyle = LineHeightStyle(
            alignment = LineHeightStyle.Alignment.Center,
            trim = LineHeightStyle.Trim.None,
            mode = LineHeightStyle.Mode.Fixed,
        )
    }
}

/**
 * The eight bundled static faces (byte-identical to
 * ios/Beid/DesignSystem/Fonts/; licences in assets/licenses/). Each
 * Bricolage Grotesque Display cut is a separate static instance whose
 * `opsz` equals its base size (DESIGN.md §6, #643) — never the variable
 * font — so each is its own family. DM Sans is one family of its two
 * weights, so a caller asking for a heavier weight on a DM Sans style
 * resolves to the real Bold instead of a synthesized one.
 */
private enum class BundledFace(
    @param:FontRes val resId: Int,
    val weight: FontWeight,
    private val familyKey: String,
) {
    Display60(R.font.bricolage_grotesque_display60_extrabold, FontWeight.ExtraBold, "display60"),
    Display52(R.font.bricolage_grotesque_display52_extrabold, FontWeight.ExtraBold, "display52"),
    Display46(R.font.bricolage_grotesque_display46_extrabold, FontWeight.ExtraBold, "display46"),
    Display40(R.font.bricolage_grotesque_display40_extrabold, FontWeight.ExtraBold, "display40"),
    Display34(R.font.bricolage_grotesque_display34_extrabold, FontWeight.ExtraBold, "display34"),
    DmSansBold(R.font.dm_sans_bold, FontWeight.Bold, "dmSans"),
    DmSansRegular(R.font.dm_sans_regular, FontWeight.Normal, "dmSans"),
    DmMonoMedium(R.font.dm_mono_medium, FontWeight.Medium, "dmMono"),
    ;

    val family: FontFamily get() = families.getValue(familyKey)

    companion object {
        private val families: Map<String, FontFamily> by lazy {
            entries.groupBy({ it.familyKey }, { Font(it.resId, it.weight) })
                .mapValues { (_, fonts) -> FontFamily(fonts) }
        }

        fun forResource(@FontRes resId: Int): BundledFace = entries.single { it.resId == resId }
    }
}

/** Flat 2b typography: Library styles (tier 1) and role tokens (tier 2). */
internal object BeidFont {

    /**
     * Tier 1: the 17 Flat 2b Library text styles, named and valued exactly as
     * iOS `DS.Font.Library` and DESIGN.md §6's ramp table.
     */
    object Library {
        /** `Display/60` — Home title "Events". */
        val display60 = BeidTextStyle(
            R.font.bricolage_grotesque_display60_extrabold, 60f, tracking = -0.02f, lineHeight = 1.0f,
        )

        /** `Display/52` — onboarding titles. */
        val display52 = BeidTextStyle(
            R.font.bricolage_grotesque_display52_extrabold, 52f, tracking = -0.02f, lineHeight = 1.0f,
        )

        /** `Display/46` — screen titles (event name, Session 1, Report #2). */
        val display46 = BeidTextStyle(
            R.font.bricolage_grotesque_display46_extrabold, 46f, tracking = -0.015f, lineHeight = 1.0f,
        )

        /** `Display/Number 40` — sensing figures; the only style with tabular digits. */
        val displayNumber40 = BeidTextStyle(
            R.font.bricolage_grotesque_display40_extrabold, 40f, tracking = -0.01f, usesTabularDigits = true,
        )

        /** `Display/Address 34` — the Account address (typeface still open: #642). */
        val displayAddress34 = BeidTextStyle(
            R.font.bricolage_grotesque_display34_extrabold, 34f, tracking = -0.01f,
        )

        /** `Title/19` — section and state titles. */
        val title19 = BeidTextStyle(R.font.dm_sans_bold, 19f)

        /** `Title/17` — `Row/List` titles. */
        val title17 = BeidTextStyle(R.font.dm_sans_bold, 17f)

        /** `Title/16` — `Button/Primary` label. */
        val title16 = BeidTextStyle(R.font.dm_sans_bold, 16f)

        /** `Title/15` — `Row/KeyValue` values. */
        val title15 = BeidTextStyle(R.font.dm_sans_bold, 15f)

        /** `Body/15` — body copy. */
        val body15 = BeidTextStyle(R.font.dm_sans_regular, 15f, lineHeight = 1.4f)

        /** `Body/13` — supporting copy, metadata. */
        val body13 = BeidTextStyle(R.font.dm_sans_regular, 13f, lineHeight = 1.4f)

        /** `Label/Mono 11` — section labels, nav, status. */
        val labelMono11 = BeidTextStyle(R.font.dm_mono_medium, 11f, tracking = 0.08f, isUppercase = true)

        /** `Label/Mono 10` — meta labels. */
        val labelMono10 = BeidTextStyle(R.font.dm_mono_medium, 10f, tracking = 0.08f, isUppercase = true)

        /** `Label/Mono 9` — the smallest labels. */
        val labelMono9 = BeidTextStyle(R.font.dm_mono_medium, 9f, tracking = 0.06f, isUppercase = true)

        /** `Label/Mono 10 tight` — in-row meta (IDs, session numbers). Not uppercased: a value style. */
        val labelMono10Tight = BeidTextStyle(R.font.dm_mono_medium, 10f, tracking = 0.06f)

        /** `Label/Mono 11 time` — times. Not uppercased: a value style. */
        val labelMono11Time = BeidTextStyle(R.font.dm_mono_medium, 11f)

        /** `Label/Mono 13 value` — addresses, hashes, proof IDs. Never uppercased (EIP-55). */
        val labelMono13Value = BeidTextStyle(R.font.dm_mono_medium, 13f)
    }

    // Tier 2: roles, each pointing at the same Library style as iOS `DS.Font`.

    /** One per screen. `Display/46`. */
    val screenTitle = Library.display46

    /** Section and state titles. `Title/19`. */
    val sectionTitle = Library.title19

    /** Card and row titles; the Library's `Row/List` title, `Title/17`. */
    val cardTitle = Library.title17

    /** Body copy. `Body/15`. */
    val body = Library.body15

    /** Supporting copy under titles. `Body/13`. */
    val supporting = Library.body13

    /** Dates, counts, fine print. `Body/13`, deliberately not a (uppercase) mono label style. */
    val meta = Library.body13

    /** Wallet addresses, hashes, proof identifiers. `Label/Mono 13 value`. */
    val ledgerMono = Library.labelMono13Value

    /** Primary CTA label; the Library's `Button/Primary` label, `Title/16`. */
    val cta = Library.title16
}

/**
 * Material3 slots → Flat 2b, so screens reading `MaterialTheme.typography.*`
 * get the bundled faces without changing. A slot carries the whole Library
 * style (tracking and line height included) — unlike iOS, where a plain
 * `.font(DS.Font.role)` call site gets face and size only (DESIGN.md §6
 * TRANSITIONAL GAP). Case cannot travel through a slot; no slot maps to an
 * uppercase style.
 *
 * Settled (the role table this file already carried):
 *
 * | Material3 slot | DS.Font role  | Library style      |
 * |----------------|---------------|--------------------|
 * | headlineLarge  | screenTitle   | display46          |
 * | titleLarge     | sectionTitle  | title19            |
 * | titleMedium    | cardTitle     | title17            |
 * | bodyLarge      | body          | body15             |
 * | bodyMedium     | supporting    | body13             |
 * | labelSmall     | meta          | body13             |
 * | bodySmall      | ledgerMono    | labelMono13Value   |
 * | labelLarge     | cta           | title16            |
 *
 * The other seven slots have no DS.Font role (iOS removed `ceremonyTitle`,
 * once headlineMedium's, in #629). Each is mapped from its Android call
 * sites and their iOS counterparts, as decided in DECISIONS.md 2026-11-18
 * (Android Flat 2b foundation).
 */
internal val BeidTypography = Typography(
    // Only caller VenueScreen's title; iOS VenueSignedServingView's
    // "Venue\nbroadcast" is display52.
    headlineMedium = BeidFont.Library.display52.textStyle,
    // In-screen headings (Home "Your collection", sensing / recording /
    // discovery / event-code headings) and Material's AlertDialog title;
    // iOS's nearest counterparts are sectionTitle (title19).
    headlineSmall = BeidFont.Library.title19.textStyle,
    // Only caller VenueScreen's pending-pack line, which has no iOS
    // counterpart; title15 keeps titleSmall a bold step below titleMedium.
    titleSmall = BeidFont.Library.title15.textStyle,
    // SensingStopConfirmScreen's event name; iOS SensingStopConfirmView
    // uses display46.
    displayMedium = BeidFont.Library.display46.textStyle,
    // SensingStopConfirmScreen's figures; iOS SensingStopConfirmView uses
    // displayNumber40.
    displaySmall = BeidFont.Library.displayNumber40.textStyle,
    // No caller; the largest Library style (iOS Home "Events"), so no slot
    // falls back to Material's system face.
    displayLarge = BeidFont.Library.display60.textStyle,
    // No caller and no Material component in use reads it; body13, like
    // labelSmall, so no slot falls back to the system face.
    labelMedium = BeidFont.Library.body13.textStyle,
    headlineLarge = BeidFont.screenTitle.textStyle,
    titleLarge = BeidFont.sectionTitle.textStyle,
    titleMedium = BeidFont.cardTitle.textStyle,
    bodyLarge = BeidFont.body.textStyle,
    bodyMedium = BeidFont.supporting.textStyle,
    labelSmall = BeidFont.meta.textStyle,
    bodySmall = BeidFont.ledgerMono.textStyle,
    labelLarge = BeidFont.cta.textStyle,
)
