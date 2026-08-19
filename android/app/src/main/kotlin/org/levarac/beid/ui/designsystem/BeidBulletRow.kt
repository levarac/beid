package org.levarac.beid.ui.designsystem

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import org.levarac.beid.ui.theme.BeidRadius
import org.levarac.beid.ui.theme.BeidSize
import org.levarac.beid.ui.theme.BeidSpacing
import org.levarac.beid.ui.theme.BeidTheme

/**
 * One benefit/permission bullet — icon roundel + title + optional supporting
 * sentence. Ports iOS's `BeidBulletRow` (`ios/Beid/DesignSystem.swift`).
 * Omit `subtitle` for a title-only row.
 */
@Composable
fun BeidBulletRow(
    icon: ImageVector,
    title: String,
    tint: Color,
    modifier: Modifier = Modifier,
    subtitle: String? = null,
) {
    Row(
        modifier = modifier.fillMaxWidth(),
        verticalAlignment = if (subtitle == null) Alignment.CenterVertically else Alignment.Top,
        horizontalArrangement = Arrangement.spacedBy(BeidSpacing.s),
    ) {
        Box(
            modifier = Modifier
                .size(BeidSize.bulletIcon)
                .beidSurface(cornerRadius = BeidRadius.control),
            contentAlignment = Alignment.Center,
        ) {
            Icon(imageVector = icon, contentDescription = null, tint = tint)
        }

        Column(verticalArrangement = Arrangement.spacedBy(BeidSpacing.xs)) {
            Text(
                text = title,
                style = MaterialTheme.typography.titleMedium,
                color = BeidTheme.colors.textPrimary,
            )

            if (subtitle != null) {
                Text(
                    text = subtitle,
                    style = MaterialTheme.typography.labelSmall,
                    color = BeidTheme.colors.textSecondary,
                )
            }
        }
    }
}
