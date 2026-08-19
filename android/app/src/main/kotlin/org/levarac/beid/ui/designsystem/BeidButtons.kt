package org.levarac.beid.ui.designsystem

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.unit.dp
import org.levarac.beid.ui.theme.BeidRadius
import org.levarac.beid.ui.theme.BeidSpacing

/**
 * Filled primary CTA — ports iOS's `BeidPrimaryButton`
 * (`ios/Beid/DesignSystem.swift`). Full width, [BeidRadius.control] corners,
 * min height 52dp.
 *
 * `containerColor`/`contentColor` are required, not defaulted: DESIGN.md §10
 * is explicit that "there is no default tint — an unspecified tint is a §5
 * violation," and §5's CTA-label rule requires the caller to pick the
 * correct on-fill label color for whatever tint it passes (e.g.
 * `actionPrimary` → `surfaceCanvas`, `proofSeal` → `labelOnSeal`,
 * `signalWarning` → `labelOnWarning`).
 */
@Composable
fun BeidPrimaryButton(
    text: String,
    containerColor: Color,
    contentColor: Color,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    icon: ImageVector? = null,
    enabled: Boolean = true,
) {
    Button(
        onClick = onClick,
        enabled = enabled,
        shape = RoundedCornerShape(BeidRadius.control),
        colors = ButtonDefaults.buttonColors(
            containerColor = containerColor,
            contentColor = contentColor,
        ),
        modifier = modifier
            .fillMaxWidth()
            .heightIn(min = 52.dp),
    ) {
        Row(
            horizontalArrangement = Arrangement.spacedBy(BeidSpacing.s),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            if (icon != null) {
                Icon(imageVector = icon, contentDescription = null)
            }
            Text(text = text, style = MaterialTheme.typography.labelLarge)
        }
    }
}

/**
 * Outlined, lower-emphasis CTA — ports iOS's `BeidSecondaryButton`
 * (`ios/Beid/DesignSystem.swift`). Full width, [BeidRadius.control] corners,
 * min height 44dp.
 *
 * `contentColor`/`borderColor` are required, not defaulted — same "no
 * default tint" rule as [BeidPrimaryButton] (DESIGN.md §10).
 */
@Composable
fun BeidSecondaryButton(
    text: String,
    contentColor: Color,
    borderColor: Color,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
) {
    OutlinedButton(
        onClick = onClick,
        enabled = enabled,
        shape = RoundedCornerShape(BeidRadius.control),
        colors = ButtonDefaults.outlinedButtonColors(contentColor = contentColor),
        border = BorderStroke(1.dp, borderColor),
        modifier = modifier
            .fillMaxWidth()
            .heightIn(min = 44.dp),
    ) {
        Text(text = text, style = MaterialTheme.typography.titleMedium)
    }
}
