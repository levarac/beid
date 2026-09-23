package org.levarac.beid.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
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
import org.levarac.beid.ui.AppVersion
import org.levarac.beid.R
import org.levarac.beid.sensing.BluetoothRadioMonitor
import org.levarac.beid.sensing.EventJoinSession
import org.levarac.beid.sensing.EventJoinUiState
import org.levarac.beid.sensing.CachedWalletHint
import org.levarac.beid.sensing.WalletConnectorState
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
    const val RECORDS_BUTTON = "account_records_button"
    const val MANUAL_EVENT_CODE_BUTTON = "account_manual_event_code_button"
    const val VENUE_BROADCAST_BUTTON = "account_venue_broadcast_button"
    const val RELAY_NOTE = "account_relay_note"
    const val VERSION_TEXT = "account_version_text"
    const val WALLET_REFERENCE = "account_wallet_reference"
}

/**
 * Account screen (beid#126) — mirrors iOS's `AccountSheetView` at the subset
 * currently in scope on Android. Manual EventCode rescue and Past Events use
 * the existing Account list. The wallet row is display-only: connection is
 * still initiated from the recording flow, and no disconnect placement is
 * invented here.
 *
 * State lives in [viewModel], not here — same split as [EventJoinScreen]/
 * [EventJoinViewModel], so this composable stays a pure function that Compose
 * tests can render directly against a fake session.
 */
@Composable
fun AccountScreen(
    viewModel: AccountViewModel,
    isBluetoothOn: Boolean,
    onOpenRecords: () -> Unit,
    onOpenManualEventCode: () -> Unit = {},
    walletState: WalletConnectorState = WalletConnectorState.Idle,
    onOpenVenue: () -> Unit = {},
) {
    val uiState by viewModel.uiState.collectAsState()
    val isSessionActive = uiState.sessionState is EventJoinUiState.Sensing

    Scaffold(containerColor = BeidTheme.colors.surfaceCanvas) { innerPadding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding)
                .padding(BeidSpacing.pageMargin)
                .verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(BeidSpacing.l),
        ) {
            Text(
                text = stringResource(R.string.account_title),
                style = MaterialTheme.typography.headlineLarge,
                color = BeidTheme.colors.textPrimary,
            )

            WalletReference(walletState)

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

            // Relay is on whenever this phone is sensing at an event it joined
            // (beid#367). It is stated here rather than hidden, because the
            // phone is transmitting on someone else's behalf.
            Text(
                text = stringResource(R.string.account_relay_note),
                style = MaterialTheme.typography.bodySmall,
                color = BeidTheme.colors.textSecondary,
                modifier = Modifier.testTag(AccountScreenTestTags.RELAY_NOTE),
            )

            // Mirrors iOS AccountSheetView's "Past Events" row placement/precedent (beid#121)
            // — the records list is reached from here, not promoted to replace EventJoin as
            // home. See RecordsScreen.kt's kdoc for the full placement reasoning.
            BeidSecondaryButton(
                text = stringResource(R.string.account_records_button),
                contentColor = BeidTheme.colors.textPrimary,
                borderColor = BeidTheme.colors.strokeHairline,
                onClick = onOpenRecords,
                modifier = Modifier.testTag(AccountScreenTestTags.RECORDS_BUTTON),
            )

            BeidSecondaryButton(
                text = stringResource(R.string.account_manual_event_code_button),
                contentColor = BeidTheme.colors.textPrimary,
                borderColor = BeidTheme.colors.strokeHairline,
                onClick = onOpenManualEventCode,
                modifier = Modifier.testTag(AccountScreenTestTags.MANUAL_EVENT_CODE_BUTTON),
            )

            BeidSecondaryButton(
                text = stringResource(R.string.account_venue_broadcast_button),
                contentColor = BeidTheme.colors.textPrimary,
                borderColor = BeidTheme.colors.strokeHairline,
                onClick = onOpenVenue,
                modifier = Modifier.testTag(AccountScreenTestTags.VENUE_BROADCAST_BUTTON),
            )

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

            // beid#491: the build position, in the same shape as iOS's row.
            // Two builds showing the same height came from the same commit,
            // which is what lets a tester report about Android and one about
            // iOS be matched up.
            Text(
                text = stringResource(R.string.account_version_label, AppVersion.displayString()),
                style = MaterialTheme.typography.bodySmall,
                color = BeidTheme.colors.textSecondary,
                modifier = Modifier.testTag(AccountScreenTestTags.VERSION_TEXT),
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
fun AccountRoute(
    session: EventJoinSession,
    onOpenRecords: () -> Unit,
    onOpenManualEventCode: () -> Unit,
    walletState: WalletConnectorState = WalletConnectorState.Idle,
    onOpenVenue: () -> Unit = {},
) {
    val context = LocalContext.current
    val bluetoothMonitor = remember { BluetoothRadioMonitor(context) }
    val isBluetoothOn = remember { bluetoothMonitor.isOn }
    val viewModel: AccountViewModel = viewModel(factory = AccountViewModel.Factory(session))
    AccountScreen(
        viewModel = viewModel,
        isBluetoothOn = isBluetoothOn,
        onOpenRecords = onOpenRecords,
        onOpenManualEventCode = onOpenManualEventCode,
        walletState = walletState,
        onOpenVenue = onOpenVenue,
    )
}

@Composable
private fun WalletReference(state: WalletConnectorState) {
    val hint = when (state) {
        is WalletConnectorState.Restored -> state.hint
        is WalletConnectorState.Connecting -> state.hint
        is WalletConnectorState.AwaitingApproval -> state.hint
        is WalletConnectorState.Connected -> CachedWalletHint(state.live.address, state.live.chainId)
        is WalletConnectorState.Failed -> state.hint
        WalletConnectorState.Idle -> null
    }
    Column(
        modifier = Modifier.fillMaxWidth().testTag(AccountScreenTestTags.WALLET_REFERENCE),
        verticalArrangement = Arrangement.spacedBy(BeidSpacing.xs),
    ) {
        Text(
            text = stringResource(R.string.account_wallet_reference_title),
            style = MaterialTheme.typography.titleMedium,
            color = BeidTheme.colors.textPrimary,
        )
        if (hint == null) {
            Text(
                text = stringResource(R.string.account_wallet_optional),
                style = MaterialTheme.typography.bodyMedium,
                color = BeidTheme.colors.textSecondary,
            )
        } else {
            Text(
                text = stringResource(R.string.account_wallet_reference_value, hint.truncatedAddress, hint.chainId),
                style = MaterialTheme.typography.bodyMedium,
                color = BeidTheme.colors.textPrimary,
            )
            Text(
                text = stringResource(
                    if (state is WalletConnectorState.Connected || state is WalletConnectorState.Failed && state.live != null) {
                        R.string.account_wallet_live_reference_note
                    } else {
                        R.string.account_wallet_restored_reference_note
                    },
                ),
                style = MaterialTheme.typography.bodySmall,
                color = BeidTheme.colors.textSecondary,
            )
        }
    }
}
