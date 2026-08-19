package org.levarac.beid.ui.designsystem

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import org.levarac.beid.ui.theme.BeidSpacing
import org.levarac.beid.ui.theme.BeidTheme

/**
 * Glyph + title + optional subtitle, centered — ports iOS's `BeidHeroHeader`
 * (`ios/Beid/DesignSystem.swift`), the header used by every state screen
 * (Welcome, BluetoothPermission, BluetoothOff, SignalLost).
 */
@Composable
fun BeidHeroHeader(
    icon: ImageVector,
    title: String,
    tint: Color,
    modifier: Modifier = Modifier,
    subtitle: String? = null,
    contentSlot: (@Composable () -> Unit)? = null,
) {
    Column(
        modifier = modifier.fillMaxWidth(),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(BeidSpacing.m),
    ) {
        BeidGlyph(icon = icon, tint = tint, contentSlot = contentSlot)

        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(BeidSpacing.xs),
        ) {
            Text(
                text = title,
                style = MaterialTheme.typography.headlineLarge,
                color = BeidTheme.colors.textPrimary,
                textAlign = TextAlign.Center,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )

            if (subtitle != null) {
                Text(
                    text = subtitle,
                    style = MaterialTheme.typography.bodyLarge,
                    color = BeidTheme.colors.textSecondary,
                    textAlign = TextAlign.Center,
                )
            }
        }
    }
}
