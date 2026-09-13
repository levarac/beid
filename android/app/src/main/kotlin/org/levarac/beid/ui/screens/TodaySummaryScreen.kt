package org.levarac.beid.ui.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
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
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.lifecycle.viewmodel.compose.viewModel
import org.levarac.beid.R
import org.levarac.beid.persistence.ProofRecordStore
import org.levarac.beid.ui.designsystem.BeidPanel
import org.levarac.beid.ui.designsystem.BeidScreen
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
                    listOf(stringResource(R.string.today_summary_submission_unavailable))
                } else {
                    buildList {
                        if (submissionStatus.queued > 0) add(stringResource(R.string.today_summary_submission_queued, submissionStatus.queued))
                        if (submissionStatus.sending > 0) add(stringResource(R.string.today_summary_submission_sending, submissionStatus.sending))
                        if (submissionStatus.retrying > 0) add(stringResource(R.string.today_summary_submission_retrying, submissionStatus.retrying))
                        if (submissionStatus.stopped > 0) {
                            add(stringResource(R.string.today_summary_submission_stopped, submissionStatus.stopped))
                            add(stringResource(R.string.today_summary_submission_recovery))
                        }
                        if (submissionStatus.accepted > 0) add(stringResource(R.string.today_summary_submission_accepted, submissionStatus.accepted))
                        if (isEmpty()) add(stringResource(R.string.today_summary_submission_empty))
                    }
                }
                rows.forEach { row ->
                    Text(text = row, style = MaterialTheme.typography.bodyLarge, color = BeidTheme.colors.textSecondary)
                }
            }
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
