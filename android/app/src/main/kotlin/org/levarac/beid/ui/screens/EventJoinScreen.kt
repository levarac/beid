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
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
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
import org.levarac.beid.ui.designsystem.BeidMetricRow
import org.levarac.beid.ui.designsystem.BeidPanel
import org.levarac.beid.ui.designsystem.BeidPrimaryButton
import org.levarac.beid.ui.designsystem.BeidSecondaryButton
import org.levarac.beid.ui.designsystem.BeidStatusPill
import org.levarac.beid.ui.theme.BeidAppTheme
import org.levarac.beid.ui.theme.BeidRadius
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
            // Plain clickable text — this screen's only entry point into the new Account
            // screen (beid#126). iOS has no direct equivalent to mirror here (its Account
            // sheet opens from a CollectionHomeView toolbar button that doesn't exist on
            // Android yet), so kept minimal and undesigned: existing typography/color
            // tokens only, no new icon or reusable component.
            Text(
                text = stringResource(R.string.account_title),
                style = MaterialTheme.typography.bodyMedium,
                color = BeidTheme.colors.textPrimary,
                modifier = Modifier
                    .clickable(onClick = onOpenAccount)
                    .testTag(EventJoinScreenTestTags.ACCOUNT_ENTRY),
            )

            Text(
                text = stringResource(R.string.event_join_title),
                style = MaterialTheme.typography.headlineLarge,
                color = BeidTheme.colors.textPrimary,
            )

            NearbyEventCards(
                cards = uiState.nearbyEventCards,
                selectedEventHashHex = uiState.selectedNearbyEventHashHex,
                enabled = uiState.sessionState is EventJoinUiState.Idle,
                onJoin = viewModel::joinNearbyEvent,
            )

            if (uiState.sessionState !is EventJoinUiState.Idle) {
                Text(
                    text = statusText(uiState.sessionState),
                    style = MaterialTheme.typography.bodyMedium,
                    color = BeidTheme.colors.textSecondary,
                )
            }

            when (val sessionState = uiState.sessionState) {
                is EventJoinUiState.PermissionDenied -> {
                    BeidPrimaryButton(
                        text = stringResource(R.string.event_join_open_settings),
                        containerColor = BeidTheme.colors.actionPrimary,
                        contentColor = BeidTheme.colors.surfaceCanvas,
                        onClick = { viewModel.openAppSettings() },
                        modifier = Modifier.testTag(EventJoinScreenTestTags.SUBMIT_BUTTON),
                    )
                }
                is EventJoinUiState.Sensing -> {
                    ScanPhaseDetail(
                        phase = sessionState.phase,
                        onSimulateSignalLost = viewModel::simulateSignalLost,
                        onResumeSensing = viewModel::resumeSensing,
                    )
                }
                else -> Unit
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
            OutlinedTextField(
                value = uiState.eventCode,
                onValueChange = viewModel::onEventCodeChanged,
                label = { Text(stringResource(R.string.event_join_code_label)) },
                isError = uiState.fieldError != null,
                singleLine = true,
                shape = RoundedCornerShape(BeidRadius.control),
                colors = OutlinedTextFieldDefaults.colors(
                    focusedTextColor = BeidTheme.colors.textPrimary,
                    unfocusedTextColor = BeidTheme.colors.textPrimary,
                    errorTextColor = BeidTheme.colors.textPrimary,
                    focusedContainerColor = BeidTheme.colors.surfaceRaised,
                    unfocusedContainerColor = BeidTheme.colors.surfaceRaised,
                    errorContainerColor = BeidTheme.colors.surfaceRaised,
                    focusedBorderColor = BeidTheme.colors.actionPrimary,
                    unfocusedBorderColor = BeidTheme.colors.strokeHairline,
                    errorBorderColor = BeidTheme.colors.strokeHairline,
                    errorLabelColor = BeidTheme.colors.textSecondary,
                    cursorColor = BeidTheme.colors.actionPrimary,
                    errorCursorColor = BeidTheme.colors.actionPrimary,
                    errorSupportingTextColor = BeidTheme.colors.textPrimary,
                ),
                modifier = Modifier.fillMaxWidth(),
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
            val selected = card.eventCodeHashHex == selectedEventHashHex
            BeidPanel(
                modifier = Modifier
                    .selectable(
                        selected = selected,
                        enabled = enabled,
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
                    text = stringResource(R.string.event_join_validity_period, card.validFromEpochSeconds, card.validUntilEpochSeconds),
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
 * Renders the current [ScanPhase] once [EventJoinUiState.Sensing] is
 * reached — the plainest form distinguishing the four reachable phases
 * (`Sensing`/`EventFound`/`Recording`/`SignalLost`) via existing
 * design-system vocabulary ([BeidStatusPill]/[BeidMetricRow]), not a
 * redesign. `Idle` never renders here — it is never published as this
 * screen's [EventJoinUiState.Sensing] payload (see
 * [org.levarac.beid.sensing.EventJoinCoordinator]'s call sites into
 * `org.levarac.beid.shared.sensing`).
 */
@Composable
private fun ScanPhaseDetail(
    phase: ScanPhase,
    onSimulateSignalLost: () -> Unit,
    onResumeSensing: () -> Unit,
) {
    val isPaused = phase is ScanPhase.SignalLost
    Column(verticalArrangement = Arrangement.spacedBy(BeidSpacing.m)) {
        BeidStatusPill(
            label = stringResource(
                if (isPaused) R.string.event_join_status_pill_paused else R.string.event_join_status_pill_active,
            ),
            tone = if (isPaused) BeidStatusPill.Tone.Paused else BeidStatusPill.Tone.Active,
            modifier = Modifier.testTag(EventJoinScreenTestTags.PHASE_STATUS_PILL),
        )

        when (phase) {
            is ScanPhase.Recording -> {
                BeidMetricRow(
                    label = stringResource(R.string.event_join_peers_verified_label),
                    value = phase.peersVerified.toString(),
                    modifier = Modifier.testTag(EventJoinScreenTestTags.PEERS_VERIFIED_ROW),
                )
                // Android has no real BLE signal-loss detection yet (mirrors iOS's
                // own demo-only manual trigger) — this is the only way to reach
                // SignalLost until real detection lands.
                BeidSecondaryButton(
                    text = stringResource(R.string.event_join_simulate_signal_lost),
                    contentColor = BeidTheme.colors.textPrimary,
                    borderColor = BeidTheme.colors.strokeHairline,
                    onClick = onSimulateSignalLost,
                    modifier = Modifier.testTag(EventJoinScreenTestTags.SIMULATE_SIGNAL_LOST_BUTTON),
                )
            }
            is ScanPhase.SignalLost -> {
                BeidMetricRow(
                    label = stringResource(R.string.event_join_peers_verified_label),
                    value = phase.peersVerified.toString(),
                    modifier = Modifier.testTag(EventJoinScreenTestTags.PEERS_VERIFIED_ROW),
                )
                BeidPrimaryButton(
                    text = stringResource(R.string.event_join_resume_sensing),
                    containerColor = BeidTheme.colors.actionPrimary,
                    contentColor = BeidTheme.colors.surfaceCanvas,
                    onClick = onResumeSensing,
                    modifier = Modifier.testTag(EventJoinScreenTestTags.RESUME_BUTTON),
                )
            }
            ScanPhase.Idle, ScanPhase.Sensing, is ScanPhase.EventFound -> Unit
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
            OutlinedTextField(
                value = "",
                onValueChange = {},
                label = { Text(stringResource(R.string.event_join_code_label)) },
                isError = true,
                singleLine = true,
                shape = RoundedCornerShape(BeidRadius.control),
                colors = OutlinedTextFieldDefaults.colors(
                    errorBorderColor = BeidTheme.colors.strokeHairline,
                ),
                modifier = Modifier.fillMaxWidth(),
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
