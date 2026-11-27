package org.levarac.beid.ui.designsystem

import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.width
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.style.TextAlign
import org.levarac.beid.ui.theme.BeidSpacing
import org.levarac.beid.ui.theme.BeidTheme

/**
 * Label (start) + value (end, trailing-aligned) metadata row — ports iOS's
 * `BeidMetricRow` (`ios/Beid/DesignSystem.swift`), whose `Spacer(minLength:
 * DS.Space.m)` keeps at least [BeidSpacing.m] between the two. Used by
 * `RecordDetailScreen`, `RecordsScreen`'s record rows and the
 * `ScanFlowScreens` recording / signal-lost states.
 *
 * The value is measured first and the label takes the remaining width,
 * wrapping when it has to. Measured the other way round, a narrow row at a
 * large font scale let the label fill the whole row and left the value no
 * width at all (PR #928 review). Values here are short (a count), so giving
 * them first claim on the width cannot crowd out the label in practice.
 */
@Composable
fun BeidMetricRow(
    label: String,
    value: String,
    modifier: Modifier = Modifier,
    valueColor: Color = BeidTheme.colors.textPrimary,
) {
    Row(modifier = modifier.fillMaxWidth()) {
        Text(
            text = label,
            modifier = Modifier.weight(1f),
            style = MaterialTheme.typography.bodyMedium,
            color = BeidTheme.colors.textSecondary,
        )
        Spacer(Modifier.width(BeidSpacing.m))
        Text(
            text = value,
            style = MaterialTheme.typography.titleMedium,
            color = valueColor,
            textAlign = TextAlign.End,
        )
    }
}
