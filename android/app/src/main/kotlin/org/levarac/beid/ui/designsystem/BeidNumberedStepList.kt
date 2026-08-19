package org.levarac.beid.ui.designsystem

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import org.levarac.beid.ui.theme.BeidRadius
import org.levarac.beid.ui.theme.BeidSize
import org.levarac.beid.ui.theme.BeidSpacing
import org.levarac.beid.ui.theme.BeidTheme

/**
 * Sequential numbered instructions in a bordered card — one filled index
 * badge + one line per step. Ports iOS's `BeidNumberedStepList`
 * (`ios/Beid/DesignSystem.swift`).
 *
 * `badgeColor`/`labelColor` are required, not defaulted: on iOS the badge
 * fill follows the hosting screen's ambient `.tint()` (its single motif
 * accent per DESIGN.md §5), and `labelColor` must be that tint's on-fill
 * pairing token (e.g. `signalWarning` fill → `labelOnWarning` label — the
 * same rule `BeidPrimaryButton` follows). Compose has no ambient tint to
 * read implicitly, so both are caller-supplied instead of hardcoded here.
 *
 * Each row is one merged accessibility element (badge number + step text
 * read together), matching iOS's `.accessibilityElement(children: .combine)`.
 */
@Composable
fun BeidNumberedStepList(
    steps: List<String>,
    badgeColor: Color,
    labelColor: Color,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier = modifier
            .beidSurface(cornerRadius = BeidRadius.card)
            .padding(vertical = BeidSpacing.xs),
    ) {
        steps.forEachIndexed { index, step ->
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = BeidSpacing.m, vertical = BeidSpacing.s)
                    .semantics(mergeDescendants = true) {},
                horizontalArrangement = Arrangement.spacedBy(BeidSpacing.m),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Box(
                    modifier = Modifier
                        .size(BeidSize.stepBadge)
                        .background(color = badgeColor, shape = CircleShape),
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        text = "${index + 1}",
                        style = MaterialTheme.typography.labelSmall,
                        fontWeight = FontWeight.SemiBold,
                        color = labelColor,
                    )
                }

                Text(
                    text = step,
                    style = MaterialTheme.typography.bodyLarge,
                    color = BeidTheme.colors.textPrimary,
                )
            }

            if (index < steps.lastIndex) {
                HorizontalDivider(
                    modifier = Modifier.padding(
                        start = BeidSpacing.m + BeidSize.stepBadge + BeidSpacing.m,
                    ),
                    color = BeidTheme.colors.strokeHairline,
                )
            }
        }
    }
}
