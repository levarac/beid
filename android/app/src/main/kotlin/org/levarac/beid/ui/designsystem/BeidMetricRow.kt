package org.levarac.beid.ui.designsystem

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.style.TextAlign
import org.levarac.beid.ui.theme.BeidTheme

/**
 * Label (left) + value (right, trailing-aligned) metadata row — ports iOS's
 * `BeidMetricRow` (`ios/Beid/DesignSystem.swift`), used by the Ledger Trace
 * / detail meta row pattern. No screen consumes this yet on Android — that's
 * expected; it's vocabulary, not a new screen.
 */
@Composable
fun BeidMetricRow(
    label: String,
    value: String,
    modifier: Modifier = Modifier,
    valueColor: Color = BeidTheme.colors.textPrimary,
) {
    Row(
        modifier = modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceBetween,
    ) {
        Text(
            text = label,
            style = MaterialTheme.typography.bodyMedium,
            color = BeidTheme.colors.textSecondary,
        )
        Text(
            text = value,
            style = MaterialTheme.typography.titleMedium,
            color = valueColor,
            textAlign = TextAlign.End,
        )
    }
}
