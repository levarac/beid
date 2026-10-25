package org.levarac.beid.ui.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedCard
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import java.util.UUID
import org.levarac.beid.R
import org.levarac.beid.persistence.ProofRecord
import org.levarac.beid.persistence.ProofRecordStore
import org.levarac.beid.sensing.EventJoinSession
import org.levarac.beid.sensing.EventJoinUiState
import org.levarac.beid.sensing.ScanPhase
import org.levarac.beid.ui.theme.BeidSpacing
import org.levarac.beid.ui.theme.BeidTheme

/** Home wraps the existing discovery route: one session, ViewModel, renderer, and automatic start. */
@Composable
fun HomeRoute(
    session: EventJoinSession,
    proofRecordStore: ProofRecordStore,
    onOpenAccount: () -> Unit,
    onOpenManualEventCode: () -> Unit,
    onOpenRecord: (UUID) -> Unit,
    onOpenEventRecords: (UUID) -> Unit,
    onStartWalletBinding: () -> Unit = {},
) {
    val records by proofRecordStore.recordsFlow.collectAsState()
    val state by session.state.collectAsState()
    // Sensing before event identification has no code to exclude. Never infer one from a name or ID.
    val activeCode = when (val phase = (state as? EventJoinUiState.Sensing)?.phase) {
        is ScanPhase.EventFound -> phase.session.eventCode
        is ScanPhase.Recording -> phase.session.eventCode
        is ScanPhase.SignalLost -> phase.session.eventCode
        else -> null
    }
    val groups = remember(records, activeCode) { homeProofRecordGroups(records, activeCode) }
    EventJoinRoute(
        session = session,
        onOpenAccount = onOpenAccount,
        onOpenManualEventCode = onOpenManualEventCode,
        onStartWalletBinding = onStartWalletBinding,
        modifier = Modifier.testTag("collection_home"),
        title = stringResource(R.string.home_title),
    ) {
        Text(
            stringResource(R.string.home_collection_title),
            style = MaterialTheme.typography.headlineSmall,
            color = BeidTheme.colors.textPrimary,
            modifier = Modifier.semantics { heading() },
        )
        if (groups.isEmpty()) {
            Text(
                stringResource(R.string.home_collection_empty),
                style = MaterialTheme.typography.bodyLarge,
                color = BeidTheme.colors.textSecondary,
                modifier = Modifier.testTag("home_empty_collection"),
            )
        }
        groups.forEach { group ->
            CollectionEventCard(group) {
                val latestId = group.first().id
                if (group.size == 1) onOpenRecord(latestId) else onOpenEventRecords(latestId)
            }
        }
    }
}

@Composable
private fun CollectionEventCard(records: List<ProofRecord>, onClick: () -> Unit) {
    val latest = records.first()
    val label = records.firstNotNullOfOrNull { it.eventName } ?: latest.toRecordListItem().displayLabel
    Column(Modifier.testTag("home_event_group")) {
        OutlinedCard(
            onClick = onClick,
            modifier = Modifier.fillMaxWidth().heightIn(min = BeidSpacing.xxl).testTag("home_group_${latest.id}"),
        ) {
            Column(
                Modifier.padding(BeidSpacing.m),
                verticalArrangement = Arrangement.spacedBy(BeidSpacing.s),
            ) {
                Text(label, style = MaterialTheme.typography.titleMedium)
                Text(recordDateFormatter.format(latest.createdAt), style = MaterialTheme.typography.bodyMedium)
                Text(
                    pluralStringResource(R.plurals.home_record_count, records.size, records.size),
                    style = MaterialTheme.typography.bodyMedium,
                )
            }
        }
    }
}
