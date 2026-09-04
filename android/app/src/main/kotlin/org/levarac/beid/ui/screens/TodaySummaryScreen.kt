package org.levarac.beid.ui.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
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

/**
 * Android parity surface for iOS PR #293. It intentionally reports only
 * today's persisted-record count and the submission feature's actual build
 * state. Accepted, verified, and public-scope rows remain absent because no
 * Android data source currently backs those claims.
 */
@Composable
fun TodaySummaryScreen(recordCount: Int, submissionEnabled: Boolean) {
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
                Text(
                    text = stringResource(
                        if (submissionEnabled) {
                            R.string.today_summary_submission_enabled
                        } else {
                            R.string.today_summary_submission_disabled
                        },
                    ),
                    style = MaterialTheme.typography.bodyLarge,
                    color = BeidTheme.colors.textSecondary,
                )
            }
        }
    }
}

@Composable
fun TodaySummaryRoute(proofRecordStore: ProofRecordStore) {
    val viewModel: TodaySummaryViewModel = viewModel(factory = TodaySummaryViewModel.Factory(proofRecordStore))
    val recordCount by viewModel.recordCount.collectAsState()
    TodaySummaryScreen(recordCount = recordCount, submissionEnabled = false)
}
