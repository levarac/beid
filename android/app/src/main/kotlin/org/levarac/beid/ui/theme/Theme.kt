package org.levarac.beid.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.staticCompositionLocalOf

/**
 * Exposes [BeidColorScheme] (the `DS.Color.*` equivalent) to composables.
 * Prefer `BeidTheme.colors` over reading this local directly.
 */
private val LocalBeidColors = staticCompositionLocalOf { LightBeidColors }

/** Screen-facing accessor mirroring iOS's `DS` namespace usage pattern. */
object BeidTheme {
    val colors: BeidColorScheme
        @Composable get() = LocalBeidColors.current
}

/**
 * Root theme composable — the Compose equivalent of applying `DS` tokens at
 * the app root on iOS. Wrap the app's content in this once, in
 * `MainActivity`.
 *
 * DESIGN.md §5 defines colors as semantic roles, not a single Material3
 * palette, so this maps [BeidColorScheme] onto Material3's [ColorScheme]
 * only for the handful of slots Material3 components need (buttons, fields);
 * screens should still prefer `BeidTheme.colors.*` over MaterialTheme's
 * `colorScheme.*` so the mapping stays in one place.
 */
@Composable
fun BeidAppTheme(
    darkTheme: Boolean = isSystemInDarkTheme(),
    content: @Composable () -> Unit,
) {
    val beidColors = if (darkTheme) DarkBeidColors else LightBeidColors
    val materialColorScheme = if (darkTheme) {
        darkColorScheme(
            background = beidColors.surfaceCanvas,
            surface = beidColors.surfaceRaised,
            primary = beidColors.actionPrimary,
            onPrimary = beidColors.surfaceCanvas,
            onBackground = beidColors.textPrimary,
            onSurface = beidColors.textPrimary,
            outline = beidColors.strokeHairline,
        )
    } else {
        lightColorScheme(
            background = beidColors.surfaceCanvas,
            surface = beidColors.surfaceRaised,
            primary = beidColors.actionPrimary,
            onPrimary = beidColors.surfaceCanvas,
            onBackground = beidColors.textPrimary,
            onSurface = beidColors.textPrimary,
            outline = beidColors.strokeHairline,
        )
    }

    CompositionLocalProvider(LocalBeidColors provides beidColors) {
        MaterialTheme(
            colorScheme = materialColorScheme,
            typography = BeidTypography,
            content = content,
        )
    }
}
