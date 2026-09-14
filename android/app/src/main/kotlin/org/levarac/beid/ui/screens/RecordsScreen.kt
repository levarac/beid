package org.levarac.beid.ui.screens

import androidx.compose.foundation.clickable
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
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
import org.levarac.beid.ui.designsystem.BeidMetricRow
import org.levarac.beid.ui.designsystem.BeidPanel
import org.levarac.beid.ui.designsystem.BeidSecondaryButton
import org.levarac.beid.ui.designsystem.BeidScreen
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
}

/** Read-only row model shared by the production mapper and UI fixtures. */
data class RecordListItem(
    val id: UUID,
    val eventLabel: String,
    val createdAt: Instant,
    val peersVerified: Int,
    val signatureStatus: RecordSignatureStatus,
)

enum class RecordSignatureStatus { NotSigned, SelfProof, Bound }

fun ProofRecord.toRecordListItem(): RecordListItem = RecordListItem(
    id = id,
    eventLabel = eventCode,
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
 * - No grouping by event and no artwork/gradient. The separate Today entry
 *   added by #342 remains available without changing these read-only rows.
 * - Production rows have no event display name — Android has no session-type
 *   field to source one from yet, so [toRecordListItem] uses the raw
 *   [ProofRecord.eventCode]. Read-only scenarios may supply an intentionally
 *   long display label without creating a persistable [ProofRecord].
 * - Production signature status is mapped from [ProofRecord.hasSelfProof]/
 *   [ProofRecord.hasBinding] record *presence*, never a ported
 *   `ProofSignatureState`/wallet-`personal_sign` mirror — that mechanism is
 *   iOS-only and explicitly provisional (`ios/Beid/Models/ProofSignature.swift`,
 *   beid#33).
 *
 * **Account-screen placement is a stated, deliberate divergence, not an
 * oversight**: on iOS, `CollectionHomeView` is the *home* screen and
 * `PastEventsView` is the secondary list reached from the Account sheet.
 * This screen is reached the way iOS's *secondary* list is reached, not the
 * way its primary one is — Android has no collection home yet
 * (`Screen.kt`'s own comment: "`EventJoin` stands in for iOS's `.home`").
 * Promoting this list to be the actual collection home is a separate
 * navigation decision belonging to the participation-surface work (#141),
 * not to this storage slice.
 *
 * **Empty-state note**: [org.levarac.beid.ui.designsystem.BeidStateScreen]
 * (icon + title + message) is this codebase's usual "whole-screen state"
 * component, but as of this slice it has no other caller and its `icon`
 * parameter requires an `ImageVector` from a `material-icons` artifact not
 * currently on `:app`'s classpath — adding that dependency was out of this
 * slice's authorized file list. The empty state below instead reuses the
 * plain, centered `Text` idiom iOS's own `PastEventsView` already uses for
 * this exact case (no icon), rather than inventing new UI or an
 * unauthorized dependency change.
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
) {
    BeidScreen {
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
                    textAlign = TextAlign.Center,
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        } else {
            LazyColumn(
                modifier = Modifier.fillMaxWidth(),
                verticalArrangement = Arrangement.spacedBy(BeidSpacing.s),
            ) {
                items(records, key = { it.id.toString() }) { record ->
                    RecordRow(record, onClick = { onOpenDetail(record.id) })
                }
            }
        }
    }
}

/** Shared with [RecordDetailScreen] (same package) so both screens format a date identically. */
internal val recordDateFormatter: DateTimeFormatter =
    DateTimeFormatter.ofLocalizedDateTime(FormatStyle.MEDIUM).withZone(ZoneId.systemDefault())

@Composable
private fun RecordRow(record: RecordListItem, onClick: () -> Unit) {
    BeidPanel(
        modifier = Modifier
            .clickable(onClick = onClick)
            .testTag(RecordsScreenTestTags.recordRow(record.id)),
    ) {
        Text(
            text = record.eventLabel,
            style = MaterialTheme.typography.titleMedium,
            color = BeidTheme.colors.textPrimary,
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
 * [EventJoinRoute]/[AccountRoute].
 */
@Composable
fun RecordsRoute(
    proofRecordStore: ProofRecordStore,
    onOpenToday: () -> Unit,
    onOpenDetail: (UUID) -> Unit,
) {
    val viewModel: RecordsViewModel = viewModel(factory = RecordsViewModel.Factory(proofRecordStore))
    val records by viewModel.records.collectAsState()
    RecordsScreen(
        records = records.map(ProofRecord::toRecordListItem),
        onOpenToday = onOpenToday,
        onOpenDetail = onOpenDetail,
    )
}

@Preview(name = "Empty", showBackground = true)
@Composable
private fun RecordsScreenEmptyPreview() {
    BeidAppTheme {
        RecordsScreen(records = emptyList(), onOpenDetail = {})
    }
}
