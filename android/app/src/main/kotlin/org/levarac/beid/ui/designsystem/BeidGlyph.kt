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
 */
@Composable
fun BeidGlyph(
    icon: ImageVector,
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
        } else {
            Icon(
                imageVector = icon,
                contentDescription = null,
                tint = tint,
                modifier = Modifier.size(size * 0.38f),
            )
        }
    }
}
