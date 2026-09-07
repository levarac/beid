package org.levarac.beid.ui.screens

import androidx.compose.foundation.clickable
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.tooling.preview.Preview
import androidx.lifecycle.viewmodel.compose.viewModel
import org.levarac.beid.R
import org.levarac.beid.sensing.EventJoinSession
import org.levarac.beid.sensing.EventJoinUiState
import org.levarac.beid.sensing.ScanPhase
import org.levarac.beid.ui.designsystem.BeidPanel
import org.levarac.beid.ui.designsystem.BeidPrimaryButton
import org.levarac.beid.ui.designsystem.BeidTextField
import org.levarac.beid.ui.theme.BeidAppTheme
import org.levarac.beid.ui.theme.BeidSpacing
import org.levarac.beid.ui.theme.BeidTheme

/**
 * Compose test tags for [EventJoinScreen] — not user-facing copy, so these
 * deliberately do not go through the string catalog (see AGENTS.md's
 * Localization Process).
 */
object EventJoinScreenTestTags {
    const val SUBMIT_BUTTON = "event_join_submit_button"
    const val FIELD_ERROR = "event_join_field_error"
    const val PHASE_STATUS_PILL = "event_join_phase_status_pill"
    const val PEERS_VERIFIED_ROW = "event_join_peers_verified_row"
    const val RESUME_BUTTON = "event_join_resume_button"
    const val SIMULATE_SIGNAL_LOST_BUTTON = "event_join_simulate_signal_lost_button"
    const val ACCOUNT_ENTRY = "event_join_account_entry"
    const val NEARBY_EVENT_LIST = "nearby_event_list"

    fun nearbyEventCard(eventCodeHashHex: String): String = "nearby_event_card_$eventCodeHashHex"
}

@Composable
private fun EventJoinFieldError.message(): String = when (this) {
    EventJoinFieldError.EmptyCode -> stringResource(R.string.event_join_error_empty_code)
    EventJoinFieldError.JoinFailed -> stringResource(R.string.event_join_error_join_failed)
}

/**
 * Event-join screen — this scaffold's one working screen (task brief: "one
 * screen proving the SDK call compiles and runs"). Mirrors the manual-entry
 * event-join slice landing on iOS in parallel; a stub/simple version here is
 * intentional, not a placeholder for missing work.
 *
 * State lives in [viewModel], not here — this composable only renders
 * [EventJoinViewModel.uiState] and forwards user actions back to it.
 *
 * Once [EventJoinUiState.Sensing] is reached, the title and
 * [NearbyEventCards] give way to [ScanFlowScreen] (beid#336) — the Android
 * equivalent of iOS's `ScanFlowView` full-screen cover, except the
 * account-entry [Text] above stays visible in every state: it is Android's
 * only door to the Account screen (and therefore to "Leave Event"), so it
 * is chrome, not swapped-out body content, even while a session is active.
 */
@Composable
fun EventJoinScreen(viewModel: EventJoinViewModel, onOpenAccount: () -> Unit) {
    val uiState by viewModel.uiState.collectAsState()

    Scaffold(containerColor = BeidTheme.colors.surfaceCanvas) { innerPadding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding)
                .padding(BeidSpacing.pageMargin)
                .verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(BeidSpacing.l, Alignment.CenterVertically),
        ) {
            Text(
                text = stringResource(R.string.account_title),
                style = MaterialTheme.typography.bodyMedium,
                color = BeidTheme.colors.textPrimary,
                modifier = Modifier
                    .clickable(onClick = onOpenAccount)
                    .testTag(EventJoinScreenTestTags.ACCOUNT_ENTRY),
            )

            val sessionState = uiState.sessionState
            if (sessionState is EventJoinUiState.Sensing) {
                ScanFlowScreen(
                    phase = sessionState.phase,
                    showEntranceCeremony = !viewModel.recordingCeremonyShown,
                    onCeremonyFinished = viewModel::markRecordingCeremonyShown,
                    onSimulateSignalLost = viewModel::simulateSignalLost,
                    onResumeSensing = viewModel::resumeSensing,
                )
            } else {
                Text(
                    text = stringResource(R.string.event_join_title),
                    style = MaterialTheme.typography.headlineLarge,
                    color = BeidTheme.colors.textPrimary,
                )
                NearbyEventCards(
                    cards = uiState.nearbyEventCards,
                    selectedEventHashHex = uiState.selectedNearbyEventHashHex,
                    enabled = sessionState is EventJoinUiState.Idle,
                    onJoin = viewModel::joinNearbyEvent,
                )
                if (sessionState !is EventJoinUiState.Idle) {
                    Text(
                        text = statusText(sessionState),
                        style = MaterialTheme.typography.bodyMedium,
                        color = BeidTheme.colors.textSecondary,
                    )
                }
                if (sessionState is EventJoinUiState.PermissionDenied) {
                    BeidPrimaryButton(
                        text = stringResource(R.string.event_join_open_settings),
                        containerColor = BeidTheme.colors.actionPrimary,
                        contentColor = BeidTheme.colors.surfaceCanvas,
                        onClick = viewModel::openAppSettings,
                        modifier = Modifier.testTag(EventJoinScreenTestTags.SUBMIT_BUTTON),
                    )
                }
            }
        }
    }
}

/**
 * Pure rendering seam used by read-only scenarios without constructing a
 * coordinator. [showEntranceCeremony]/[onCeremonyFinished] default to
 * "skip the ceremony" — read-only scenario/demo playback has no
 * coordinator-backed [EventJoinSession.recordingCeremonyShown] to seed
 * from, and a scripted frame sequence flashing a 2-second ceremony mid-demo
 * would fight the scenario's own frame-advance timing, so demo playback
 * always renders [RecordingScreen]'s steady state directly.
 */
@Composable
fun EventJoinScreen(
    state: EventJoinScreenState,
    onEventCodeChanged: (String) -> Unit,
    onSubmit: () -> Unit,
    onOpenSettings: () -> Unit,
    onOpenAccount: () -> Unit,
    onSimulateSignalLost: () -> Unit,
    onResumeSensing: () -> Unit,
    showEntranceCeremony: Boolean = false,
    onCeremonyFinished: () -> Unit = {},
) {
    Scaffold(containerColor = BeidTheme.colors.surfaceCanvas) { innerPadding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding)
                .padding(BeidSpacing.pageMargin)
                .verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(BeidSpacing.l, Alignment.CenterVertically),
        ) {
            // Plain clickable text — this screen's only entry point into the new Account
            // screen (beid#126). iOS has no direct equivalent to mirror here (its Account
            // sheet opens from a CollectionHomeView toolbar button that doesn't exist on
            // Android yet), so kept minimal and undesigned: existing typography/color
            // tokens only, no new icon or reusable component. Stays visible in every
            // state, including Sensing (beid#336) — Android's only door to Account.
            Text(
                text = stringResource(R.string.account_title),
                style = MaterialTheme.typography.bodyMedium,
                color = BeidTheme.colors.textPrimary,
                modifier = Modifier
                    .clickable(onClick = onOpenAccount)
                    .testTag(EventJoinScreenTestTags.ACCOUNT_ENTRY),
            )

            if (state.sessionState is EventJoinUiState.Sensing) {
                ScanFlowScreen(
                    phase = state.sessionState.phase,
                    showEntranceCeremony = showEntranceCeremony,
                    onCeremonyFinished = onCeremonyFinished,
                    onSimulateSignalLost = onSimulateSignalLost,
                    onResumeSensing = onResumeSensing,
                )
            } else {
                Text(
                    text = stringResource(R.string.event_join_title),
                    style = MaterialTheme.typography.headlineLarge,
                    color = BeidTheme.colors.textPrimary,
                )

                Column(verticalArrangement = Arrangement.spacedBy(BeidSpacing.s)) {
                    BeidTextField(
                        value = state.eventCode,
                        onValueChange = onEventCodeChanged,
                        placeholder = stringResource(R.string.event_join_code_label),
                        isError = state.fieldError != null,
                    )

                    state.fieldError?.let { error ->
                        // iOS renders this row in DS.Color.textPrimary (plain ink), not a warning
                        // accent — DESIGN.md §5's accent map reserves signalWarning for BLE
                        // signal-loss recovery screens, and a validation/join error isn't that.
                        Row(
                            horizontalArrangement = Arrangement.spacedBy(BeidSpacing.xs),
                            modifier = Modifier.testTag(EventJoinScreenTestTags.FIELD_ERROR),
                        ) {
                            Text(
                                text = "⚠",
                                style = MaterialTheme.typography.bodyMedium,
                                color = BeidTheme.colors.textPrimary,
                            )
                            Text(
                                text = error.message(),
                                style = MaterialTheme.typography.bodyMedium,
                                color = BeidTheme.colors.textPrimary,
                            )
                        }
                    }
                }

                Text(
                    text = statusText(state.sessionState),
                    style = MaterialTheme.typography.bodyMedium,
                    color = BeidTheme.colors.textSecondary,
                )

                if (state.sessionState is EventJoinUiState.PermissionDenied) {
                    BeidPrimaryButton(
                        text = stringResource(R.string.event_join_open_settings),
                        containerColor = BeidTheme.colors.actionPrimary,
                        contentColor = BeidTheme.colors.surfaceCanvas,
                        onClick = onOpenSettings,
                        modifier = Modifier.testTag(EventJoinScreenTestTags.SUBMIT_BUTTON),
                    )
                } else {
                    BeidPrimaryButton(
                        text = stringResource(R.string.event_join_button),
                        containerColor = BeidTheme.colors.actionPrimary,
                        contentColor = BeidTheme.colors.surfaceCanvas,
                        onClick = onSubmit,
                        enabled = state.sessionState !is EventJoinUiState.RequestingPermission,
                        modifier = Modifier.testTag(EventJoinScreenTestTags.SUBMIT_BUTTON),
                    )
                }
            }
        }
    }
}

@Composable
fun ManualEventCodeScreen(viewModel: EventJoinViewModel) {
    val uiState by viewModel.uiState.collectAsState()
    Scaffold(containerColor = BeidTheme.colors.surfaceCanvas) { innerPadding ->
        Column(
            modifier = Modifier.fillMaxSize().padding(innerPadding).padding(BeidSpacing.pageMargin),
            verticalArrangement = Arrangement.spacedBy(BeidSpacing.l, Alignment.CenterVertically),
        ) {
            Text(stringResource(R.string.event_join_code_label), style = MaterialTheme.typography.headlineLarge)
            BeidTextField(
                value = uiState.eventCode,
                onValueChange = viewModel::onEventCodeChanged,
                placeholder = stringResource(R.string.event_join_code_label),
                isError = uiState.fieldError != null,
            )
            uiState.fieldError?.let { error ->
                Row(
                    horizontalArrangement = Arrangement.spacedBy(BeidSpacing.xs),
                    modifier = Modifier.testTag(EventJoinScreenTestTags.FIELD_ERROR),
                ) {
                    Text("⚠", color = BeidTheme.colors.textPrimary)
                    Text(error.message(), color = BeidTheme.colors.textPrimary)
                }
            }
            BeidPrimaryButton(
                text = stringResource(R.string.event_join_button),
                containerColor = BeidTheme.colors.actionPrimary,
                contentColor = BeidTheme.colors.surfaceCanvas,
                onClick = viewModel::submit,
                modifier = Modifier.testTag(EventJoinScreenTestTags.SUBMIT_BUTTON),
            )
        }
    }
}

@Composable
fun ManualEventCodeRoute(session: EventJoinSession) {
    val viewModel: EventJoinViewModel = viewModel(factory = EventJoinViewModel.Factory(session))
    ManualEventCodeScreen(viewModel)
}

@Composable
private fun NearbyEventCards(
    cards: List<org.levarac.beid.sensing.NearbyEventCard>,
    selectedEventHashHex: String?,
    enabled: Boolean,
    onJoin: (String) -> Unit,
) {
    if (cards.isEmpty()) {
        Column(modifier = Modifier.testTag(EventJoinScreenTestTags.NEARBY_EVENT_LIST)) {
            Text(stringResource(R.string.event_join_searching_nearby), color = BeidTheme.colors.textSecondary)
            Text(stringResource(R.string.event_join_rescue_guidance), color = BeidTheme.colors.textSecondary)
        }
        return
    }
    Column(
        verticalArrangement = Arrangement.spacedBy(BeidSpacing.s),
        modifier = Modifier.testTag(EventJoinScreenTestTags.NEARBY_EVENT_LIST),
    ) {
        cards.forEach { card ->
            val cardEnabled = enabled && card.eventIdHex != null
            val selected = cardEnabled && card.eventCodeHashHex == selectedEventHashHex
            BeidPanel(
                modifier = Modifier
                    .selectable(
                        selected = selected,
                        enabled = cardEnabled,
                        onClick = { onJoin(card.eventCodeHashHex) },
                        role = Role.RadioButton,
                    )
                    .testTag(EventJoinScreenTestTags.nearbyEventCard(card.eventCodeHashHex)),
            ) {
                Text(
                    text = stringResource(R.string.event_join_beacon_name_label),
                    style = MaterialTheme.typography.labelSmall,
                    color = BeidTheme.colors.textSecondary,
                )
                Text(
                    text = card.beaconDisplayName ?: stringResource(R.string.event_join_beacon_name_missing),
                    style = MaterialTheme.typography.titleMedium,
                    color = BeidTheme.colors.textPrimary,
                )
                if (card.validFromEpochSeconds != null && card.validUntilEpochSeconds != null) Text(
                    text = stringResource(
                        R.string.event_join_validity_period,
                        card.validFromEpochSeconds,
                        card.validUntilEpochSeconds,
                    ),
                    style = MaterialTheme.typography.bodyMedium,
                    color = BeidTheme.colors.textSecondary,
                )
                if (card.eventIdHex == null) Text(
                    text = stringResource(R.string.event_join_not_joinable_yet),
                    style = MaterialTheme.typography.labelSmall,
                    color = BeidTheme.colors.textSecondary,
                )
                if (selected) Text(
                    text = stringResource(R.string.event_join_selected),
                    style = MaterialTheme.typography.labelSmall,
                    color = BeidTheme.colors.textSecondary,
                )
            }
        }
    }
}

/**
 * Constructs (via [EventJoinViewModel.Factory]) and remembers the screen's
 * [EventJoinViewModel], scoped to the current [androidx.lifecycle.ViewModelStoreOwner]
 * (`MainActivity`). Kept separate from [EventJoinScreen] so the latter stays
 * a pure function of [EventJoinViewModel] for Compose tests to render
 * directly against a fake session, without a real [EventJoinSession].
 */
@Composable
fun EventJoinRoute(session: EventJoinSession, onOpenAccount: () -> Unit) {
    LaunchedEffect(session) { session.startNearbyEventDiscovery() }
    val viewModel: EventJoinViewModel = viewModel(factory = EventJoinViewModel.Factory(session))
    EventJoinScreen(viewModel, onOpenAccount)
}

@Composable
private fun statusText(state: EventJoinUiState): String = when (state) {
    is EventJoinUiState.Idle -> stringResource(R.string.event_join_status_idle)
    is EventJoinUiState.RequestingPermission -> stringResource(R.string.event_join_status_requesting_permission)
    is EventJoinUiState.Sensing -> phaseStatusText(state.phase)
    is EventJoinUiState.PermissionDenied -> stringResource(R.string.event_join_status_permission_denied)
    is EventJoinUiState.JoinFailed -> stringResource(R.string.event_join_error_join_failed)
}

@Composable
private fun phaseStatusText(phase: ScanPhase): String = when (phase) {
    ScanPhase.Idle, ScanPhase.Sensing -> stringResource(R.string.event_join_status_sensing)
    is ScanPhase.EventFound -> stringResource(R.string.event_join_status_event_found)
    is ScanPhase.Recording -> stringResource(R.string.event_join_status_recording)
    is ScanPhase.SignalLost -> stringResource(R.string.event_join_status_signal_lost)
}

@Preview(name = "Idle", showBackground = true)
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

@Preview(name = "Error — empty code", showBackground = true)
@Composable
private fun EventJoinScreenEmptyCodeErrorPreview() {
    BeidAppTheme {
        EventJoinFieldErrorPreview(EventJoinFieldError.EmptyCode)
    }
}

/**
 * Pins [EventJoinFieldError.JoinFailed]'s copy/visual even though it has no
 * live producer yet (see the kdoc on [EventJoinFieldError]) — Preview is the
 * only way to exercise it until [EventJoinSession] gains a distinct
 * join-failure state.
 */
@Preview(name = "Error — join failed (dormant, see kdoc)", showBackground = true)
@Composable
private fun EventJoinScreenJoinFailedErrorPreview() {
    BeidAppTheme {
        EventJoinFieldErrorPreview(EventJoinFieldError.JoinFailed)
    }
}

@Composable
private fun EventJoinFieldErrorPreview(error: EventJoinFieldError) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(BeidSpacing.pageMargin),
        verticalArrangement = Arrangement.spacedBy(BeidSpacing.l),
    ) {
        Text(
            text = stringResource(R.string.event_join_title),
            style = MaterialTheme.typography.headlineLarge,
            color = BeidTheme.colors.textPrimary,
        )

        Column(verticalArrangement = Arrangement.spacedBy(BeidSpacing.s)) {
            BeidTextField(
                value = "",
                onValueChange = {},
                placeholder = stringResource(R.string.event_join_code_label),
                isError = true,
            )

            Row(horizontalArrangement = Arrangement.spacedBy(BeidSpacing.xs)) {
                Text(text = "⚠", color = BeidTheme.colors.textPrimary)
                Text(text = error.message(), color = BeidTheme.colors.textPrimary)
            }
        }

        BeidPrimaryButton(
            text = stringResource(R.string.event_join_button),
            containerColor = BeidTheme.colors.actionPrimary,
            contentColor = BeidTheme.colors.surfaceCanvas,
            onClick = {},
        )
    }
}
