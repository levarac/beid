package org.levarac.beid.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.lifecycle.viewmodel.compose.viewModel
import org.levarac.beid.R
import org.levarac.beid.sensing.BluetoothRadioMonitor
import org.levarac.beid.sensing.EventJoinSession
import org.levarac.beid.sensing.EventJoinUiState
import org.levarac.beid.ui.designsystem.BeidSecondaryButton
import org.levarac.beid.ui.theme.BeidSize
import org.levarac.beid.ui.theme.BeidSpacing
import org.levarac.beid.ui.theme.BeidTheme

/**
 * Compose test tags for [AccountScreen] — not user-facing copy, same
 * convention as [EventJoinScreenTestTags].
 */
object AccountScreenTestTags {
    const val BLUETOOTH_STATUS_TEXT = "account_bluetooth_status_text"
    const val LEAVE_EVENT_BUTTON = "account_leave_event_button"
}

/**
 * Account screen (beid#126) — mirrors iOS's `AccountSheetView` at the subset
 * currently in scope on Android: Bluetooth radio status and Leave Event.
 * Wallet, Venue Device, Past Events, and a second Join Event entry are
 * deliberately absent — see the PR description for the row-by-row mapping.
 *
 * State lives in [viewModel], not here — same split as [EventJoinScreen]/
 * [EventJoinViewModel], so this composable stays a pure function that Compose
 * tests can render directly against a fake session.
 */
@Composable
fun AccountScreen(viewModel: AccountViewModel, isBluetoothOn: Boolean) {
    val uiState by viewModel.uiState.collectAsState()
    val isSessionActive = uiState.sessionState is EventJoinUiState.Sensing

    Scaffold(containerColor = BeidTheme.colors.surfaceCanvas) { innerPadding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding)
                .padding(BeidSpacing.pageMargin),
            verticalArrangement = Arrangement.spacedBy(BeidSpacing.l),
        ) {
            Text(
                text = stringResource(R.string.account_title),
                style = MaterialTheme.typography.headlineLarge,
                color = BeidTheme.colors.textPrimary,
            )

            // Plain Row + colored dot + Text — not BeidStatusPill, whose Tone enum only
            // maps Active/Paused onto signalActive/signalWarning (BLE signal quality),
            // not this generic on/off radio-power toggle. Mirrors iOS's own hand-rolled
            // Label + Circle + Text in AccountSheetView for the same reason.
            val bluetoothStatusColor = if (isBluetoothOn) BeidTheme.colors.statusOn else BeidTheme.colors.statusOff
            val bluetoothStatusText = stringResource(
                if (isBluetoothOn) R.string.account_bluetooth_status_on else R.string.account_bluetooth_status_off,
            )
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    text = stringResource(R.string.account_bluetooth_label),
                    style = MaterialTheme.typography.bodyLarge,
                    color = BeidTheme.colors.textPrimary,
                )
                Row(
                    horizontalArrangement = Arrangement.spacedBy(BeidSpacing.xs),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Box(
                        modifier = Modifier
                            .size(BeidSize.statusDot)
                            .background(color = bluetoothStatusColor, shape = CircleShape),
                    )
                    Text(
                        text = bluetoothStatusText,
                        style = MaterialTheme.typography.bodyMedium,
                        color = bluetoothStatusColor,
                        modifier = Modifier.testTag(AccountScreenTestTags.BLUETOOTH_STATUS_TEXT),
                    )
                }
            }

            // No motif accent (DESIGN.md §5: account is outside sensing/ceremony/recovery
            // moments) and no destructive-colored tint (no ratified DS.Color for that,
            // see the PR report) — same neutral secondary-button treatment EventJoinScreen
            // already uses for its own non-primary action. The "Leave Event" label alone
            // carries the destructive meaning.
            BeidSecondaryButton(
                text = stringResource(R.string.account_leave_event_button),
                contentColor = BeidTheme.colors.textPrimary,
                borderColor = BeidTheme.colors.strokeHairline,
                onClick = viewModel::leaveEvent,
                enabled = isSessionActive,
                modifier = Modifier.testTag(AccountScreenTestTags.LEAVE_EVENT_BUTTON),
            )
        }
    }
}

/**
 * Constructs (via [AccountViewModel.Factory]) and remembers the screen's
 * [AccountViewModel], and reads [BluetoothRadioMonitor] once per screen
 * entry — a plain [remember]-scoped read, not a live listener, consistent
 * with how [BluetoothOffScreen]'s "I've turned it on" already treats radio
 * state in this codebase.
 */
@Composable
fun AccountRoute(session: EventJoinSession) {
    val context = LocalContext.current
    val bluetoothMonitor = remember { BluetoothRadioMonitor(context) }
    val isBluetoothOn = remember { bluetoothMonitor.isOn }
    val viewModel: AccountViewModel = viewModel(factory = AccountViewModel.Factory(session))
    AccountScreen(viewModel = viewModel, isBluetoothOn = isBluetoothOn)
}
