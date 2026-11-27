package org.levarac.beid.ui.screens

import androidx.compose.foundation.clickable
import androidx.compose.foundation.background
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.tooling.preview.Preview
import androidx.lifecycle.viewmodel.compose.viewModel
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.util.UUID
import org.levarac.beid.R
import org.levarac.beid.persistence.ProofRecord
import org.levarac.beid.persistence.ProofRecordStore
import org.levarac.beid.persistence.SigilPresenceStore
import org.levarac.beid.shared.sigil.SigilInput
import org.levarac.beid.ui.designsystem.BeidMetricRow
import org.levarac.beid.ui.designsystem.BeidPanel
import org.levarac.beid.ui.designsystem.RecordSigilPlacement
import org.levarac.beid.ui.designsystem.RecordSigilSlot
import org.levarac.beid.ui.designsystem.BeidSecondaryButton
import org.levarac.beid.ui.designsystem.BeidStatusPill
import org.levarac.beid.ui.theme.BeidAppTheme
import org.levarac.beid.ui.theme.BeidSpacing
import org.levarac.beid.ui.theme.BeidTheme

/**
 * Compose test tags for [RecordsScreen] — not user-facing copy, same
 * convention as [EventJoinScreenTestTags]/[AccountScreenTestTags].
 */
object RecordsScreenTestTags {
    const val EMPTY_STATE = "records_empty_state"
    const val TODAY_BUTTON = "records_today_button"
    fun recordRow(id: UUID): String = "records_row_$id"
    fun recordSigil(id: UUID): String = "records_row_sigil_$id"
}

/** Read-only row model shared by the production mapper and UI fixtures. */
data class RecordListItem(
    val id: UUID,
    val eventLabel: String,
    val createdAt: Instant,
    val peersVerified: Int,
    val signatureStatus: RecordSignatureStatus,
    /** Keep a real name intact even when its text happens to look like a hex ID. */
    val eventName: String? = null,
)

enum class RecordSignatureStatus { NotSigned, SelfProof, Bound }

private val EventCodeHexPattern = Regex("^[0-9a-fA-F]{64}$")

private fun String.toRecordDisplayLabel(): String = if (matches(EventCodeHexPattern)) {
    "Event ${take(8)}…${takeLast(6)}"
} else {
    this
}

internal val RecordListItem.displayLabel: String
    get() = eventName ?: eventLabel.toRecordDisplayLabel()

fun ProofRecord.toRecordListItem(): RecordListItem = RecordListItem(
    id = id,
    eventLabel = eventName ?: eventCode,
    eventName = eventName,
    createdAt = createdAt,
    peersVerified = peersVerified,
    signatureStatus = when {
        hasBinding -> RecordSignatureStatus.Bound
        hasSelfProof -> RecordSignatureStatus.SelfProof
        else -> RecordSignatureStatus.NotSigned
    },
)

/**
 * Records screen (beid#121) — Android's counterpart of iOS's
 * `Proof`/`ProofStore` + (a reduced) `CollectionHomeView`/`PastEventsView`.
 * Flat, reverse-chronological list of collected proofs; not a new design,
 * composed only from existing design-system vocabulary
 * ([BeidPanel]/[BeidMetricRow]/[BeidStatusPill]).
 *
 * **Stated scope reductions** (mirrors the precedent iOS's own
 * `PastEventsView.swift` doc comment sets for its own reduced slice):
 * - No grouping by event. The separate Today entry added by #342 remains
 *   available without changing these read-only rows.
 * - Artwork only for a selected event's records (beid#722): there each row
 *   leads with its session's Sigil, as iOS `EventDetailView` draws
 *   `.eventDetailRow` with `isDeviceRecord` (integration/ios-1.1.1). The full
 *   list under Account is iOS `PastEventsView`, which draws none, so
 *   [sigilInput] is `null` there.
 * - Production rows use the optional name retained at verified join. Older
 *   records and joins without a name keep their event-code presentation.
 * - Production signature status is mapped from [ProofRecord.hasSelfProof]/
 *   [ProofRecord.hasBinding] record *presence*, never a ported
 *   `ProofSignatureState`/wallet-`personal_sign` mirror — that mechanism is
 *   iOS-only and explicitly provisional (`ios/Beid/Models/ProofSignature.swift`,
 *   beid#33).
 *
 * Home presents event groups; this screen remains the secondary full list
 * under Account (the iOS `PastEventsView` equivalent), and also renders a
 * selected event's records with the same rows and detail navigation.
 *
 * **Empty-state note**: [org.levarac.beid.ui.designsystem.BeidStateScreen]
 * (icon + title + message) is this codebase's usual "whole-screen state"
 * component, but as of this slice it has no other caller and its `icon`
 * parameter requires an `ImageVector` from a `material-icons` artifact not
 * currently on `:app`'s classpath — adding that dependency was out of this
 * slice's authorized file list. The empty state below instead uses plain
 * `Text` with no icon, leading-aligned like its title, as iOS's
 * `PastEventsView` and `DailySummaryView` empty states are, rather than
 * inventing new UI or an unauthorized dependency change.
 *
 * **Tap-to-detail** (beid#122): each row is clickable and navigates to
 * [RecordDetailScreen] carrying the tapped [ProofRecord.id], via
 * [onOpenDetail] — the same callback-threading shape [AccountRoute]'s
 * `onOpenRecords` already established.
 */
@Composable
fun RecordsScreen(
    records: List<RecordListItem>,
    onOpenToday: () -> Unit = {},
    onOpenDetail: (UUID) -> Unit = {},
    /** beid#722: non-null only for a selected event's records; returns `null` for the neutral ring. */
    sigilInput: ((UUID) -> SigilInput?)? = null,
) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(BeidTheme.colors.surfaceCanvas)
            // A pushed route with no Scaffold: clear the system bars edge-to-edge
            // windows draw under, keeping the canvas behind them.
            .windowInsetsPadding(WindowInsets.safeDrawing)
            .padding(horizontal = BeidSpacing.pageMargin)
            .padding(vertical = BeidSpacing.l),
        verticalArrangement = Arrangement.spacedBy(BeidSpacing.l),
    ) {
        Text(
            text = stringResource(R.string.records_title),
            style = MaterialTheme.typography.headlineLarge,
            color = BeidTheme.colors.textPrimary,
            modifier = Modifier.semantics { heading() },
        )

        BeidSecondaryButton(
            text = stringResource(R.string.records_today_button),
            contentColor = BeidTheme.colors.textPrimary,
            borderColor = BeidTheme.colors.strokeHairline,
            onClick = onOpenToday,
            modifier = Modifier.testTag(RecordsScreenTestTags.TODAY_BUTTON),
        )

        if (records.isEmpty()) {
            BeidPanel(modifier = Modifier.testTag(RecordsScreenTestTags.EMPTY_STATE)) {
                Text(
                    text = stringResource(R.string.records_empty_title),
                    style = MaterialTheme.typography.titleMedium,
                    color = BeidTheme.colors.textPrimary,
                    modifier = Modifier.semantics { heading() },
                )
                Text(
                    text = stringResource(R.string.records_empty_message),
                    style = MaterialTheme.typography.bodyLarge,
                    color = BeidTheme.colors.textSecondary,
                )
            }
        } else {
            LazyColumn(
                modifier = Modifier
                    .fillMaxWidth()
                    .weight(1f),
                verticalArrangement = Arrangement.spacedBy(BeidSpacing.s),
                contentPadding = PaddingValues(bottom = BeidSpacing.l),
            ) {
                items(records, key = { it.id.toString() }) { record ->
                    RecordRow(record, onClick = { onOpenDetail(record.id) }, sigilInput = sigilInput)
                }
            }
        }
    }
}

/** Shared with [RecordDetailScreen] (same package) so both screens format a date identically. */
internal val recordDateFormatter: DateTimeFormatter =
    DateTimeFormatter.ofLocalizedDateTime(FormatStyle.MEDIUM).withZone(ZoneId.systemDefault())

@Composable
private fun RecordRow(record: RecordListItem, onClick: () -> Unit, sigilInput: ((UUID) -> SigilInput?)? = null) {
    BeidPanel(
        modifier = Modifier
            .clickable(onClick = onClick)
            .testTag(RecordsScreenTestTags.recordRow(record.id)),
    ) {
        if (sigilInput == null) {
            RecordRowContent(record)
        } else {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(BeidSpacing.m),
            ) {
                RecordSigilSlot(
                    input = sigilInput(record.id),
                    placement = RecordSigilPlacement.EventDetailRow,
                    modifier = Modifier.testTag(RecordsScreenTestTags.recordSigil(record.id)),
                    isDeviceRecord = true,
                )
                Column(Modifier.weight(1f)) { RecordRowContent(record) }
            }
        }
    }
}

/** The row's text, metric and pill; shared by the plain and the Sigil-led row. */
@Composable
private fun RecordRowContent(record: RecordListItem) {
    val displayLabel = record.displayLabel
    Text(
        text = displayLabel,
        style = MaterialTheme.typography.titleMedium,
        color = BeidTheme.colors.textPrimary,
        modifier = Modifier.semantics {
            contentDescription = if (displayLabel == record.eventLabel) {
                displayLabel
            } else {
                "$displayLabel. ${record.eventLabel}"
            }
        },
    )
    Text(
        text = recordDateFormatter.format(record.createdAt),
        style = MaterialTheme.typography.bodyMedium,
        color = BeidTheme.colors.textSecondary,
    )
    BeidMetricRow(
        label = stringResource(R.string.event_join_peers_verified_label),
        value = record.peersVerified.toString(),
    )
    signatureStatusPill(record)
}

@Composable
private fun signatureStatusPill(record: RecordListItem) {
    val (labelRes, tone) = when (record.signatureStatus) {
        RecordSignatureStatus.Bound -> R.string.records_signature_status_bound to BeidStatusPill.Tone.Sealed
        RecordSignatureStatus.SelfProof -> R.string.records_signature_status_self_proof to BeidStatusPill.Tone.Active
        RecordSignatureStatus.NotSigned -> R.string.records_signature_status_not_signed to BeidStatusPill.Tone.Neutral
    }
    BeidStatusPill(label = stringResource(labelRes), tone = tone)
}

/**
 * Constructs (via [RecordsViewModel.Factory]) and remembers the screen's
 * [RecordsViewModel], scoped to the current
 * [androidx.lifecycle.ViewModelStoreOwner] (`MainActivity`) — same split as
 * [HomeRoute]/[AccountRoute].
 */
@Composable
fun RecordsRoute(
    proofRecordStore: ProofRecordStore,
    onOpenToday: () -> Unit,
    onOpenDetail: (UUID) -> Unit,
    eventGroupAnchorId: UUID? = null,
    sigilPresenceStore: SigilPresenceStore? = null,
) {
    val viewModel: RecordsViewModel = viewModel(factory = RecordsViewModel.Factory(proofRecordStore))
    val records by viewModel.records.collectAsState()
    RecordsScreen(
        records = (eventGroupAnchorId?.let { proofRecordsForGroup(records, it) } ?: records)
            .map(ProofRecord::toRecordListItem),
        onOpenToday = onOpenToday,
        onOpenDetail = onOpenDetail,
        sigilInput = if (eventGroupAnchorId != null) sigilPresenceStore.sigilLookup() else null,
    )
}

@Preview(name = "Empty", showBackground = true)
@Composable
private fun RecordsScreenEmptyPreview() {
    BeidAppTheme {
        RecordsScreen(records = emptyList(), onOpenDetail = {})
    }
}
