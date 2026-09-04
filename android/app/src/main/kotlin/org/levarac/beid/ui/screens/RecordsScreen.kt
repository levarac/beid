package org.levarac.beid.ui.screens

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
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.tooling.preview.Preview
import androidx.lifecycle.viewmodel.compose.viewModel
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

/**
 * Records screen (beid#121) — Android's counterpart of iOS's
 * `Proof`/`ProofStore` + (a reduced) `CollectionHomeView`/`PastEventsView`.
 * Flat, reverse-chronological list of collected proofs; not a new design,
 * composed only from existing design-system vocabulary
 * ([BeidPanel]/[BeidMetricRow]/[BeidStatusPill]).
 *
 * **Stated scope reductions** (mirrors the precedent iOS's own
 * `PastEventsView.swift` doc comment sets for its own reduced slice):
 * - No grouping by event, no artwork/gradient, no daily-summary sheet — all
 *   iOS `CollectionHomeView` features this slice does not attempt; each is
 *   its own larger, separately scoped design surface.
 * - No event display name — Android has no session-type field to source one
 *   from yet, so rows show the raw [ProofRecord.eventCode] as-is.
 * - No tap-to-detail: rows carry no `clickable` modifier. The detail screen
 *   is beid#122, a separate, not-yet-built issue.
 * - Signature status is derived from [ProofRecord.hasSelfProof]/
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
 */
@Composable
fun RecordsScreen(records: List<ProofRecord>, onOpenToday: () -> Unit = {}) {
    BeidScreen {
        Text(
            text = stringResource(R.string.records_title),
            style = MaterialTheme.typography.headlineLarge,
            color = BeidTheme.colors.textPrimary,
        )

        BeidSecondaryButton(
            text = stringResource(R.string.records_today_button),
            contentColor = BeidTheme.colors.textPrimary,
            borderColor = BeidTheme.colors.strokeHairline,
            onClick = onOpenToday,
            modifier = Modifier.testTag(RecordsScreenTestTags.TODAY_BUTTON),
        )

        if (records.isEmpty()) {
            Text(
                text = stringResource(R.string.records_empty_message),
                style = MaterialTheme.typography.bodyLarge,
                color = BeidTheme.colors.textSecondary,
                textAlign = TextAlign.Center,
                modifier = Modifier
                    .fillMaxWidth()
                    .testTag(RecordsScreenTestTags.EMPTY_STATE),
            )
        } else {
            LazyColumn(
                modifier = Modifier.fillMaxWidth(),
                verticalArrangement = Arrangement.spacedBy(BeidSpacing.s),
            ) {
                items(records, key = { it.id.toString() }) { record -> RecordRow(record) }
            }
        }
    }
}

private val recordDateFormatter: DateTimeFormatter =
    DateTimeFormatter.ofLocalizedDateTime(FormatStyle.MEDIUM).withZone(ZoneId.systemDefault())

@Composable
private fun RecordRow(record: ProofRecord) {
    BeidPanel(modifier = Modifier.testTag(RecordsScreenTestTags.recordRow(record.id))) {
        Text(
            text = record.eventCode,
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
private fun signatureStatusPill(record: ProofRecord) {
    val (labelRes, tone) = when {
        record.hasBinding -> R.string.records_signature_status_bound to BeidStatusPill.Tone.Sealed
        record.hasSelfProof -> R.string.records_signature_status_self_proof to BeidStatusPill.Tone.Active
        else -> R.string.records_signature_status_not_signed to BeidStatusPill.Tone.Neutral
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
fun RecordsRoute(proofRecordStore: ProofRecordStore, onOpenToday: () -> Unit) {
    val viewModel: RecordsViewModel = viewModel(factory = RecordsViewModel.Factory(proofRecordStore))
    val records by viewModel.records.collectAsState()
    RecordsScreen(records = records, onOpenToday = onOpenToday)
}

@Preview(name = "Empty", showBackground = true)
@Composable
private fun RecordsScreenEmptyPreview() {
    BeidAppTheme {
        RecordsScreen(records = emptyList())
    }
}
