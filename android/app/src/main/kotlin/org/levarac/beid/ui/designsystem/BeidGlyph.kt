package org.levarac.beid.ui.designsystem

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.unit.Dp
import org.levarac.beid.ui.theme.BeidRadius
import org.levarac.beid.ui.theme.BeidSize

/**
 * Icon roundel — ports iOS's `BeidGlyph` (`ios/Beid/DesignSystem.swift`).
 * Decorative: the icon carries no content description, matching iOS's
 * `.accessibilityHidden(true)` — the surrounding title/subtitle text already
 * carries the meaning.
 *
 * `contentSlot`, when non-null, takes precedence over `icon` — the Compose
 * equivalent of iOS's `assetImage` precedence over `systemImage`, ported as
 * a slot rather than a wired asset since Android has no illustration assets
 * yet (see android/README.md).
 *
 * `icon` is nullable (beid#338 illustration correction): a caller that
 * supplies `contentSlot` (e.g. [WelcomeMarkGlyph] and its siblings in
 * `Illustrations.kt`) never needs a fallback icon at all — unlike iOS's
 * `BeidGlyph`, whose `systemImage` stays a required, always-present
 * parameter even when `assetImage` wins (see `ios/Beid/DesignSystem.swift`),
 * Kotlin's nullable-default-parameter idiom lets Android express "no icon"
 * directly instead of threading through an unused placeholder value.
 */
@Composable
fun BeidGlyph(
    icon: ImageVector? = null,
    tint: Color,
    modifier: Modifier = Modifier,
    size: Dp = BeidSize.glyph,
    contentSlot: (@Composable () -> Unit)? = null,
) {
    Box(
        modifier = modifier
            .size(size)
            .beidSurface(cornerRadius = BeidRadius.glyph),
        contentAlignment = Alignment.Center,
    ) {
        if (contentSlot != null) {
            contentSlot()
        } else if (icon != null) {
            Icon(
                imageVector = icon,
                contentDescription = null,
                tint = tint,
                modifier = Modifier.size(size * 0.38f),
            )
        }
    }
}
