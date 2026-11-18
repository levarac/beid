package org.levarac.beid.ui.designsystem

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import org.levarac.beid.ui.theme.BeidRadius
import org.levarac.beid.ui.theme.BeidSize
import org.levarac.beid.ui.theme.BeidSpacing
import org.levarac.beid.ui.theme.BeidTheme

/**
 * Dot + label status indicator — ports iOS's `BeidStatusPill`
 * (`ios/Beid/DesignSystem.swift`).
 *
 * Diverges from iOS's shape deliberately: the iOS `State` enum bakes the
 * label string and dot color together as `LocalizedStringKey` literals.
 * DESIGN.md §15's sentence-case rule is still unratified (issue #24), so
 * baking English strings into a Kotlin enum would bake a casing/wording
 * decision into the component. Instead this takes `label` as a
 * caller-supplied [String] (resolved via `stringResource`, like every other
 * string in this codebase) and [Tone] selects only the dot color — it holds
 * no text.
 *
 * The dot is decorative (no semantics node — the label text already names
 * the state, so color is never the only signal, DESIGN.md §2.9); the label
 * is a plain, independently queryable `Text`, never merged into a combined
 * accessibility element.
 */
object BeidStatusPill {
    /**
     * [Neutral]/[Sealed] added for [org.levarac.beid.ui.screens.RecordsScreen]'s
     * three-state signature-status pill (beid#121: not-yet-signed / self-proof
     * recorded / bound). [Active] doubles as "self-proof recorded".
     *
     * Dot colors follow DESIGN.md §5's #628 mapping: [Active] (iOS
     * `.sensingAutomatically`) takes `statusOn`; [Paused] (iOS `.sensingPaused`,
     * waiting for the signal to return) takes `statusPending`; [Sealed] takes
     * `textPrimary`, because a sealed proof is none of on / pending / off and
     * `textPrimary` is the role for neutral marks. [Neutral] ("not signed",
     * "queued", "unavailable", "recovery", …) also takes `textPrimary` and
     * leaves the meaning to its label, not the red `statusOff`
     * (DECISIONS.md 2026-11-18, Android Flat 2b foundation).
     */
    enum class Tone { Active, Paused, Neutral, Sealed }

    @Composable
    operator fun invoke(
        label: String,
        tone: Tone,
        modifier: Modifier = Modifier,
    ) {
        val dotColor = when (tone) {
            Tone.Active -> BeidTheme.colors.statusOn
            Tone.Paused -> BeidTheme.colors.statusPending
            Tone.Neutral -> BeidTheme.colors.textPrimary
            Tone.Sealed -> BeidTheme.colors.textPrimary
        }

        Row(
            modifier = modifier
                .beidSurface(cornerRadius = BeidRadius.pill)
                .padding(horizontal = BeidSpacing.m, vertical = BeidSpacing.s),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(BeidSpacing.s),
        ) {
            Box(
                modifier = Modifier
                    .size(BeidSize.statusDot)
                    .background(color = dotColor, shape = CircleShape),
            )

            Text(
                text = label,
                style = MaterialTheme.typography.bodyMedium,
                color = BeidTheme.colors.textSecondary,
            )
        }
    }
}
