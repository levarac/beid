package org.levarac.beid.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import java.util.UUID
import org.levarac.beid.R
import org.levarac.beid.persistence.ProofRecord
import org.levarac.beid.persistence.ProofRecordStore
import org.levarac.beid.persistence.SessionAggregateSnapshotStore
import org.levarac.beid.ui.designsystem.BeidMetricRow
import org.levarac.beid.ui.designsystem.BeidPanel
import org.levarac.beid.ui.designsystem.BeidScreen
import org.levarac.beid.ui.theme.BeidSize
import org.levarac.beid.ui.theme.BeidSpacing
import org.levarac.beid.ui.theme.BeidTheme

/**
 * Compose test tags for [RecordDetailScreen] — not user-facing copy, same
 * convention as [RecordsScreenTestTags]. Only the rows whose trailing value
 * text can legitimately collide (more than one row can simultaneously show
 * the shared "Not yet available" string) are tagged; event code/date/devices
 * sensed carry test-controlled, non-colliding values, same convention
 * [RecordsScreenTest] already uses for those.
 */
object RecordDetailScreenTestTags {
    const val SELF_PROOF_VALUE = "record_detail_self_proof_value"
    const val BINDING_VALUE = "record_detail_binding_value"
    const val MUTUAL_CONFIRMATION_VALUE = "record_detail_mutual_confirmation_value"
    const val TIME_BAND_BUILDUP_VALUE = "record_detail_time_band_buildup_value"
}

/**
 * Record detail screen (beid#122), reached by tapping a [RecordsScreen] row.
 * Android's single-screen counterpart of iOS's `ItemDetailView` +
 * `TransparencyView`'s Participation-record tier + the headline/band rows of
 * `ParticipationSummaryView` — one Compose screen rather than three, the same
 * multi-screen-to-one-screen collapse this codebase already applies for
 * `EventJoinScreen` (see AGENTS.md's current-state paragraph).
 *
 * Renders five **independent** rows/sections — never merged into one derived
 * badge or score (iOS's own `TransparencyView` sets this precedent: five
 * independent rows with no composite, because a composite would imply a
 * confidence its missing parts don't justify):
 * 1. Devices sensed — real data, [ProofRecord.peersVerified].
 * 2. Self-proof — real data, [ProofRecord.hasSelfProof] presence.
 * 3. Owner-key binding — real data, [ProofRecord.hasBinding] presence.
 * 4. Mutual confirmation — unconditionally "Not yet available": parity with
 *    iOS's `ParticipationSummaryView.mutualCountUnavailableText`, which is
 *    also unconditional (verified against `ParticipationSummaryView.swift`'s
 *    `headlineRow` — on-device mutual/reciprocal confirmation is
 *    structurally unmeasurable, not merely uncaptured; beid#222 rejected a
 *    measured-looking zero here as misinformation).
 * 5. Time-band buildup — unconditionally "Not yet available" today: Android
 *    has no aggregation producer (see the render call site below for why,
 *    and beid#327, its tracked owner).
 *
 * Never displays "Verified" anywhere (beid#144 is unowned; beid#240 already
 * had to remove an unbacked "Verified" claim from this product twice) — rows
 * 2-5 use only "Recorded"/"Not yet available", presence-based, matching
 * #121's `RecordsScreen` vocabulary decision (never a ported
 * `ProofSignatureState`).
 */
@Composable
fun RecordDetailScreen(record: ProofRecord, aggregate: org.levarac.beid.shared.aggregation.SessionAggregate? = null) {
    BeidScreen(modifier = Modifier.verticalScroll(rememberScrollState())) {
        Column(verticalArrangement = Arrangement.spacedBy(BeidSpacing.xs)) {
            Text(
                text = record.eventCode,
                style = MaterialTheme.typography.headlineLarge,
                color = BeidTheme.colors.textPrimary,
            )
            Text(
                text = recordDateFormatter.format(record.createdAt),
                style = MaterialTheme.typography.bodyMedium,
                color = BeidTheme.colors.textSecondary,
            )
        }

        BeidPanel {
            BeidMetricRow(
                label = stringResource(R.string.record_detail_devices_sensed_label),
                value = record.peersVerified.toString(),
            )
        }

        BeidPanel {
            Column(verticalArrangement = Arrangement.spacedBy(BeidSpacing.m)) {
                AvailabilityRow(
                    label = stringResource(R.string.record_detail_self_proof_label),
                    isAvailable = record.hasSelfProof,
                    valueModifier = Modifier.testTag(RecordDetailScreenTestTags.SELF_PROOF_VALUE),
                )
                AvailabilityRow(
                    label = stringResource(R.string.record_detail_binding_label),
                    isAvailable = record.hasBinding,
                    valueModifier = Modifier.testTag(RecordDetailScreenTestTags.BINDING_VALUE),
                )
                AvailabilityRow(
                    label = stringResource(R.string.record_detail_mutual_confirmation_label),
                    isAvailable = false,
                    valueModifier = Modifier.testTag(RecordDetailScreenTestTags.MUTUAL_CONFIRMATION_VALUE),
                )
                AvailabilityRow(
                    label = stringResource(R.string.record_detail_time_band_buildup_label),
                    isAvailable = aggregate != null,
                    valueModifier = Modifier.testTag(RecordDetailScreenTestTags.TIME_BAND_BUILDUP_VALUE),
                )
                if (aggregate != null) {
                    Column(verticalArrangement = Arrangement.spacedBy(BeidSpacing.xs)) {
                        for (index in 0 until aggregate.windowCount) {
                            val window = aggregate.windowAt(index) ?: continue
                            Text(
                                text = "${window.windowIndex}: ${window.peerCount}",
                                style = MaterialTheme.typography.bodySmall,
                                color = BeidTheme.colors.textSecondary,
                            )
                        }
                    }
                }
            }
        }
    }
}

/**
 * One independent available/unavailable row — Compose equivalent of iOS
 * `TransparencyView`'s private `TierRow` (not a literal port): a leading dot
 * whose *shape* (filled vs. outlined ring), not only its color, changes with
 * availability (DESIGN.md §2.9 — never convey state by color alone, mirrors
 * `TierRow`'s `checkmark.circle.fill` vs. outlined `circle`), a label, and a
 * trailing value that is always exactly "Recorded" or "Not yet available" —
 * this screen's own per-row vocabulary (never `records_signature_status_*`,
 * the list screen's derived-pill vocabulary, and never "Verified").
 */
@Composable
private fun AvailabilityRow(label: String, isAvailable: Boolean, valueModifier: Modifier = Modifier) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Row(
            horizontalArrangement = Arrangement.spacedBy(BeidSpacing.s),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            AvailabilityDot(isAvailable = isAvailable)
            Text(
                text = label,
                style = MaterialTheme.typography.bodyMedium,
                color = BeidTheme.colors.textSecondary,
            )
        }
        Text(
            text = stringResource(
                if (isAvailable) R.string.record_detail_recorded else R.string.record_detail_not_yet_available,
            ),
            style = if (isAvailable) MaterialTheme.typography.titleMedium else MaterialTheme.typography.bodyMedium,
            color = if (isAvailable) BeidTheme.colors.textPrimary else BeidTheme.colors.statusOff,
            modifier = valueModifier,
        )
    }
}

@Composable
private fun AvailabilityDot(isAvailable: Boolean) {
    val color: Color = if (isAvailable) BeidTheme.colors.proofSeal else BeidTheme.colors.statusOff
    val shapeModifier = if (isAvailable) {
        Modifier.background(color = color, shape = CircleShape)
    } else {
        Modifier.border(width = 1.dp, color = color, shape = CircleShape)
    }
    Box(modifier = Modifier.size(BeidSize.statusDot).then(shapeModifier))
}

/**
 * Constructs (via [RecordDetailViewModel.Factory]) and remembers the
 * screen's [RecordDetailViewModel]. When [record] is permanently `null`
 * (stale/bad [recordId] — this app never deletes records, so this should not
 * normally happen), renders nothing and calls [onRecordNotFound] once via
 * [LaunchedEffect] instead of crashing — same defensive shape as
 * [AppNavHost]'s other guarded transitions.
 */
@Composable
fun RecordDetailRoute(proofRecordStore: ProofRecordStore, sessionAggregateSnapshotStore: SessionAggregateSnapshotStore? = null, recordId: UUID, onRecordNotFound: () -> Unit) {
    val viewModel: RecordDetailViewModel = viewModel(
        factory = RecordDetailViewModel.Factory(proofRecordStore, recordId),
    )
    val record by viewModel.record.collectAsState()
    val currentRecord = record
    if (currentRecord != null) {
        RecordDetailScreen(record = currentRecord, aggregate = sessionAggregateSnapshotStore?.snapshot(recordId))
    } else {
        LaunchedEffect(recordId) { onRecordNotFound() }
    }
}
