package org.levarac.beid.ui.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import org.levarac.beid.shared.report.UnsentWindowSubmissionSummary
import androidx.compose.ui.Modifier
import androidx.compose.ui.Alignment
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.lifecycle.viewmodel.compose.viewModel
import org.levarac.beid.R
import org.levarac.beid.persistence.ProofRecordStore
import org.levarac.beid.ui.designsystem.BeidPanel
import org.levarac.beid.ui.designsystem.BeidScreen
import org.levarac.beid.ui.designsystem.BeidStatusPill
import org.levarac.beid.ui.theme.BeidSpacing
import org.levarac.beid.ui.theme.BeidTheme

object TodaySummaryScreenTestTags {
    const val EMPTY_STATE = "today_summary_empty_state"
}

/** Today's proof count and separately labelled all-time durable submission status. */
@Composable
fun TodaySummaryScreen(recordCount: Int, submissionStatus: UnsentWindowSubmissionSummary? = null) {
    BeidScreen {
        Text(
            text = stringResource(R.string.today_summary_title),
            style = MaterialTheme.typography.headlineLarge,
            color = BeidTheme.colors.textPrimary,
            modifier = Modifier.semantics { heading() },
        )

        if (recordCount == 0) {
            BeidPanel(modifier = Modifier.testTag(TodaySummaryScreenTestTags.EMPTY_STATE)) {
                Text(
                    text = stringResource(R.string.today_summary_empty_title),
                    style = MaterialTheme.typography.titleMedium,
                    color = BeidTheme.colors.textPrimary,
                )
                Text(
                    text = stringResource(R.string.today_summary_empty_message),
                    style = MaterialTheme.typography.bodyLarge,
                    color = BeidTheme.colors.textSecondary,
                )
            }
        } else {
            BeidPanel {
                Text(
                    text = pluralStringResource(
                        R.plurals.today_summary_record_count,
                        recordCount,
                        recordCount,
                    ),
                    style = MaterialTheme.typography.titleMedium,
                    color = BeidTheme.colors.textPrimary,
                )
            }
        }

        BeidPanel {
            Column(
                modifier = Modifier.fillMaxWidth(),
                verticalArrangement = Arrangement.spacedBy(BeidSpacing.s),
            ) {
                Text(
                    text = stringResource(R.string.today_summary_submission_title),
                    style = MaterialTheme.typography.titleMedium,
                    color = BeidTheme.colors.textPrimary,
                )
                val rows = if (submissionStatus == null) {
                    listOf(SubmissionRow(stringResource(R.string.today_summary_submission_unavailable), null, BeidStatusPill.Tone.Neutral))
                } else {
                    buildList {
                        if (submissionStatus.queued > 0) add(SubmissionRow(stringResource(R.string.today_summary_submission_queued_label), stringResource(R.string.today_summary_submission_queued, submissionStatus.queued), BeidStatusPill.Tone.Neutral))
                        if (submissionStatus.sending > 0) add(SubmissionRow(stringResource(R.string.today_summary_submission_sending_label), stringResource(R.string.today_summary_submission_sending, submissionStatus.sending), BeidStatusPill.Tone.Active))
                        if (submissionStatus.retrying > 0) add(SubmissionRow(stringResource(R.string.today_summary_submission_retrying_label), stringResource(R.string.today_summary_submission_retrying, submissionStatus.retrying), BeidStatusPill.Tone.Paused))
                        if (submissionStatus.stopped > 0) {
                            add(SubmissionRow(stringResource(R.string.today_summary_submission_stopped_label), stringResource(R.string.today_summary_submission_stopped, submissionStatus.stopped), BeidStatusPill.Tone.Paused))
                            add(SubmissionRow(stringResource(R.string.today_summary_submission_recovery_label), stringResource(R.string.today_summary_submission_recovery), BeidStatusPill.Tone.Neutral))
                        }
                        if (submissionStatus.accepted > 0) add(SubmissionRow(stringResource(R.string.today_summary_submission_accepted_label), stringResource(R.string.today_summary_submission_accepted, submissionStatus.accepted), BeidStatusPill.Tone.Sealed))
                        if (isEmpty()) add(SubmissionRow(stringResource(R.string.today_summary_submission_empty_label), stringResource(R.string.today_summary_submission_empty), BeidStatusPill.Tone.Neutral))
                    }
                }
                rows.forEach { row ->
                    SubmissionStatusRow(row)
                }
            }
        }
    }
}

private data class SubmissionRow(val label: String, val detail: String?, val tone: BeidStatusPill.Tone)

@Composable
private fun SubmissionStatusRow(row: SubmissionRow) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .semantics {
                stateDescription = listOfNotNull(row.label, row.detail).joinToString(". ")
                liveRegion = LiveRegionMode.Polite
            },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(BeidSpacing.s),
    ) {
        BeidStatusPill(label = row.label, tone = row.tone)
        row.detail?.let {
            Text(text = it, style = MaterialTheme.typography.bodyLarge, color = BeidTheme.colors.textSecondary)
        }
    }
}

@Composable
fun TodaySummaryRoute(proofRecordStore: ProofRecordStore) {
    val viewModel: TodaySummaryViewModel = viewModel(factory = TodaySummaryViewModel.Factory(proofRecordStore))
    val recordCount by viewModel.recordCount.collectAsState()
    val filesDir = LocalContext.current.filesDir
    val statusFlow = remember(filesDir) { observeTodaySubmissionStatus(filesDir) }
    // Lifecycle collection cancels polling when the screen stops or leaves composition.
    val status by statusFlow.collectAsStateWithLifecycle(initialValue = null)
    TodaySummaryScreen(recordCount = recordCount, submissionStatus = status)
}
