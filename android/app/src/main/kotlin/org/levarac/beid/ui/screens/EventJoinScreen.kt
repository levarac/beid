package org.levarac.beid.ui.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import org.levarac.beid.R
import org.levarac.beid.sensing.EventJoinCoordinator
import org.levarac.beid.sensing.EventJoinUiState
import org.levarac.beid.ui.theme.BeidAppTheme
import org.levarac.beid.ui.theme.BeidSpacing
import org.levarac.beid.ui.theme.BeidTheme

/**
 * Event-join screen — this scaffold's one working screen (task brief: "one
 * screen proving the SDK call compiles and runs"). Mirrors the manual-entry
 * event-join slice landing on iOS in parallel; a stub/simple version here is
 * intentional, not a placeholder for missing work.
 *
 * [coordinator] is owned by `MainActivity` (not created here) because
 * `BarnardEngine.requestPermissions` is Activity-driven on Android — the
 * hosting Activity must forward `onRequestPermissionsResult` into the same
 * engine instance for the request to ever resolve (see
 * android/vendor/barnard's README "Usage").
 */
@Composable
fun EventJoinScreen(coordinator: EventJoinCoordinator) {
    val uiState by coordinator.state.collectAsState()
    var eventCode by remember { mutableStateOf("") }

    Scaffold(containerColor = BeidTheme.colors.surfaceCanvas) { innerPadding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding)
                .padding(BeidSpacing.pageMargin),
            verticalArrangement = Arrangement.spacedBy(BeidSpacing.l, Alignment.CenterVertically),
        ) {
            Text(
                text = stringResource(R.string.event_join_title),
                style = androidx.compose.material3.MaterialTheme.typography.headlineLarge,
                color = BeidTheme.colors.textPrimary,
            )

            OutlinedTextField(
                value = eventCode,
                onValueChange = { eventCode = it },
                label = { Text(stringResource(R.string.event_join_code_label)) },
                modifier = Modifier.fillMaxWidth(),
            )

            Text(
                text = statusText(uiState),
                style = androidx.compose.material3.MaterialTheme.typography.bodyMedium,
                color = BeidTheme.colors.textSecondary,
            )

            when (uiState) {
                is EventJoinUiState.PermissionDenied -> {
                    Button(
                        onClick = { coordinator.openAppSettings() },
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Text(stringResource(R.string.event_join_open_settings))
                    }
                }
                else -> {
                    Button(
                        onClick = { coordinator.joinEvent(eventCode) },
                        enabled = eventCode.isNotBlank() && uiState !is EventJoinUiState.RequestingPermission,
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Text(stringResource(R.string.event_join_button))
                    }
                }
            }
        }
    }
}

@Composable
private fun statusText(state: EventJoinUiState): String = when (state) {
    is EventJoinUiState.Idle -> stringResource(R.string.event_join_status_idle)
    is EventJoinUiState.RequestingPermission -> stringResource(R.string.event_join_status_requesting_permission)
    is EventJoinUiState.Sensing -> stringResource(R.string.event_join_status_sensing)
    is EventJoinUiState.PermissionDenied -> stringResource(R.string.event_join_status_permission_denied)
}

@Preview(showBackground = true)
@Composable
private fun EventJoinScreenPreview() {
    BeidAppTheme {
        Column(
            modifier = Modifier.padding(BeidSpacing.pageMargin),
            verticalArrangement = Arrangement.spacedBy(BeidSpacing.l),
        ) {
            Text(stringResource(R.string.event_join_title))
            Text(stringResource(R.string.event_join_status_idle))
        }
    }
}
