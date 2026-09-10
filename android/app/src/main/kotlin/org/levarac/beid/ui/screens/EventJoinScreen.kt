package org.levarac.beid.ui.screens

import androidx.compose.foundation.clickable
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
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
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.tooling.preview.Preview
import androidx.lifecycle.viewmodel.compose.viewModel
import org.levarac.beid.R
import org.levarac.beid.sensing.EventJoinSession
import org.levarac.beid.sensing.EventJoinUiState
import org.levarac.beid.sensing.NearbyEventCard
import org.levarac.beid.sensing.ScanPhase
import org.levarac.beid.shared.event.EventJoinFailureReason
import org.levarac.beid.shared.event.NearbyEventSearchOutcome
import org.levarac.beid.ui.designsystem.BeidPanel
import org.levarac.beid.ui.designsystem.BeidPrimaryButton
import org.levarac.beid.ui.designsystem.BeidSecondaryButton
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

    /** beid#463: the rescue route out of a search that found nothing joinable. */
    const val RESCUE_ENTRY_BUTTON = "event_join_rescue_entry_button"

    /** beid#463: fills the code field from the clipboard, so no one hand-types 64 hex characters. */
    const val PASTE_BUTTON = "event_join_paste_button"

    fun nearbyEventCard(eventCodeHashHex: String): String = "nearby_event_card_$eventCodeHashHex"
}

/**
 * The one place a refusal becomes a sentence (beid#463).
 *
 * The branch is on the shared [EventJoinFailureReason] rather than on anything
 * this file decides, and it is exhaustive with no `else`: a reason added later
 * has to be given copy here rather than silently inheriting the generic
 * message, which is how the network case got hidden in the first place.
 */
@Composable
private fun EventJoinFieldError.message(): String = when (this) {
    EventJoinFieldError.EmptyCode -> stringResource(R.string.event_join_error_empty_code)
    is EventJoinFieldError.JoinFailed -> when (reason) {
        EventJoinFailureReason.NETWORK_REQUIRED -> stringResource(R.string.event_join_error_network_required)
        EventJoinFailureReason.EVENT_NOT_FOUND -> stringResource(R.string.event_join_error_event_not_found)
        EventJoinFailureReason.CODE_MISMATCH -> stringResource(R.string.event_join_error_code_mismatch)
        EventJoinFailureReason.EVENT_NOT_ACTIVE -> stringResource(R.string.event_join_error_event_not_active)
        EventJoinFailureReason.VERIFICATION_FAILED -> stringResource(R.string.event_join_error_verification_failed)
        EventJoinFailureReason.UNKNOWN -> stringResource(R.string.event_join_error_join_failed)
    }
}

/**
 * Event-join screen — this scaffold's one working screen (task brief: "one
 * screen proving the SDK call compiles and runs"). Mirrors the manual-entry
 * event-join slice landing on iOS in parallel; a stub/simple version here is
 * intentional, not a placeholder for missing work.
 *
 * State lives in [viewModel], not here — this composable only collects
 * [EventJoinViewModel.uiState] and forwards user actions back to it. The
 * rendering itself belongs to [EventJoinContent], the one renderer this
 * production path and the read-only scenario/preview path share (beid#363).
 */
@Composable
fun EventJoinScreen(
    viewModel: EventJoinViewModel,
    onOpenAccount: () -> Unit,
    onOpenManualEventCode: () -> Unit,
) {
    val uiState by viewModel.uiState.collectAsState()

    EventJoinContent(
        state = uiState,
        onOpenAccount = onOpenAccount,
        onOpenManualEventCode = onOpenManualEventCode,
        onJoinNearbyEvent = viewModel::joinNearbyEvent,
        onOpenSettings = viewModel::openAppSettings,
        onSimulateSignalLost = viewModel::simulateSignalLost,
        onResumeSensing = viewModel::resumeSensing,
        showEntranceCeremony = !viewModel.recordingCeremonyShown,
        onCeremonyFinished = viewModel::markRecordingCeremonyShown,
    )
}

/**
 * The screen's single stateless renderer: everything Event Join shows is a
 * function of [state] alone. Production ([EventJoinScreen]) and the
 * read-only scenario/preview path (`ReadOnlyScenarioContent`,
 * `ScenarioPreviews`) both call this, so a DEBUG launch-argument scenario
 * and a Compose preview show exactly what the app shows (beid#363 — before
 * it, the scenario path drew a separate legacy event-code input and never
 * read [EventJoinScreenState.nearbyEventCards]).
 *
 * It holds no [EventJoinSession], store, or coordinator handle, and reports
 * a chosen candidate only as an opaque `eventCodeHashHex` through
 * [onJoinNearbyEvent] — scenario callers pass a no-op there, so fixture
 * cards have no path into joining, recording, signing, or submission.
 *
 * Once [EventJoinUiState.Sensing] is reached, the title and the nearby-event
 * cards give way to [ScanFlowScreen] (beid#336) — the Android equivalent of
 * iOS's `ScanFlowView` full-screen cover, except the account-entry [Text]
 * above stays visible in every state: it is Android's only door to the
 * Account screen (and therefore to "Leave Event"), so it is chrome, not
 * swapped-out body content, even while a session is active.
 *
 * [showEntranceCeremony]/[onCeremonyFinished] default to "skip the
 * ceremony" — read-only scenario/demo playback has no coordinator-backed
 * [EventJoinSession.recordingCeremonyShown] to seed from, and a scripted
 * frame sequence flashing a 2-second ceremony mid-demo would fight the
 * scenario's own frame-advance timing, so demo playback always renders
 * [RecordingScreen]'s steady state directly.
 */
@Composable
fun EventJoinContent(
    state: EventJoinScreenState,
    onOpenAccount: () -> Unit,
    /**
     * beid#463's rescue route. Defaulted to a no-op for the read-only
     * scenario/preview path, which has no navigator — the same reason
     * [onJoinNearbyEvent] is a no-op there.
     */
    onOpenManualEventCode: () -> Unit = {},
    onJoinNearbyEvent: (String) -> Unit,
    onOpenSettings: () -> Unit,
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
            // screen (beid#126). The two platforms reach Account from different surfaces:
            // on iOS from a toolbar button in `CollectionHomeView`
            // (`CollectionHomeView.swift` sets `accountSheetPresented`, which presents
            // `AccountSheetView`); on Android from this text, on the Join screen. Which
            // surface should host it on Android is the collection-home/navigation
            // decision tracked by beid#141, so this is kept minimal and undesigned:
            // existing typography/color tokens only, no new icon or reusable component.
            // Stays visible in every state, including Sensing (beid#336) — Android's only
            // door to Account.
            Text(
                text = stringResource(R.string.account_title),
                style = MaterialTheme.typography.bodyMedium,
                color = BeidTheme.colors.textPrimary,
                modifier = Modifier
                    .clickable(onClick = onOpenAccount)
                    .testTag(EventJoinScreenTestTags.ACCOUNT_ENTRY),
            )

            val sessionState = state.sessionState
            if (sessionState is EventJoinUiState.Sensing) {
                ScanFlowScreen(
                    phase = sessionState.phase,
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
                NearbyEventCards(
                    cards = state.nearbyEventCards,
                    selectedEventHashHex = state.selectedNearbyEventHashHex,
                    enabled = sessionState is EventJoinUiState.Idle,
                    onJoin = onJoinNearbyEvent,
                )
                // beid#463. Offered on the shared outcome, never on "the card
                // list looks empty": a screen full of candidates that cannot be
                // joined is the same dead end as an empty one, and the rule
                // that knows the difference lives in `shared/` so iOS offers
                // the route at the same moment.
                if (state.searchOutcome == NearbyEventSearchOutcome.RESCUE_ENTRY_OFFERED) {
                    Text(
                        text = stringResource(R.string.event_join_rescue_prompt),
                        style = MaterialTheme.typography.bodyMedium,
                        color = BeidTheme.colors.textSecondary,
                    )
                    BeidSecondaryButton(
                        text = stringResource(R.string.event_join_rescue_enter_code),
                        contentColor = BeidTheme.colors.textPrimary,
                        borderColor = BeidTheme.colors.textSecondary,
                        onClick = onOpenManualEventCode,
                        modifier = Modifier.testTag(EventJoinScreenTestTags.RESCUE_ENTRY_BUTTON),
                    )
                }
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
                        onClick = onOpenSettings,
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
    // The clipboard is read here and nowhere below: `ManualEventCodeContent`
    // stays a function of its state, and the ViewModel receives a plain
    // string, so neither of them needs an Android clipboard to be testable.
    val clipboard = LocalClipboardManager.current
    ManualEventCodeContent(
        state = uiState,
        onEventCodeChanged = viewModel::onEventCodeChanged,
        onPasteEventCode = { viewModel.onEventCodePasted(clipboard.getText()?.text) },
        onSubmit = viewModel::submit,
    )
}

/**
 * Manual event-code entry's single stateless renderer, extracted so its
 * previews render the real screen instead of a hand-drawn lookalike. Same
 * split [EventJoinScreen]/[EventJoinContent] use: this is the whole screen
 * as a function of [state], and [ManualEventCodeScreen] is only the
 * collector above it.
 *
 * This screen is reached from Account, not from Event Join — since beid#350
 * the Event Join surface offers nearby-event cards rather than a code field,
 * and beid#363 removed the second copy of that field the scenario path used
 * to draw.
 */
@Composable
fun ManualEventCodeContent(
    state: EventJoinScreenState,
    onEventCodeChanged: (String) -> Unit,
    onPasteEventCode: () -> Unit = {},
    onSubmit: () -> Unit,
) {
    Scaffold(containerColor = BeidTheme.colors.surfaceCanvas) { innerPadding ->
        Column(
            modifier = Modifier.fillMaxSize().padding(innerPadding).padding(BeidSpacing.pageMargin),
            verticalArrangement = Arrangement.spacedBy(BeidSpacing.l, Alignment.CenterVertically),
        ) {
            Text(stringResource(R.string.event_join_code_label), style = MaterialTheme.typography.headlineLarge)
            BeidTextField(
                value = state.eventCode,
                onValueChange = onEventCodeChanged,
                placeholder = stringResource(R.string.event_join_code_label),
                isError = state.fieldError != null,
            )
            state.fieldError?.let { error ->
                Row(
                    horizontalArrangement = Arrangement.spacedBy(BeidSpacing.xs),
                    modifier = Modifier.testTag(EventJoinScreenTestTags.FIELD_ERROR),
                ) {
                    Text("⚠", color = BeidTheme.colors.textPrimary)
                    Text(error.message(), color = BeidTheme.colors.textPrimary)
                }
            }
            // beid#463. A canonical open code is 64 hex characters, which the
            // issue rules out hand-entering as a route that does not exist in
            // practice. The field stays editable for a venue's short
            // human-readable code; this is what makes the canonical one usable
            // at all.
            BeidSecondaryButton(
                text = stringResource(R.string.event_join_paste_code),
                contentColor = BeidTheme.colors.textPrimary,
                borderColor = BeidTheme.colors.textSecondary,
                onClick = onPasteEventCode,
                modifier = Modifier.testTag(EventJoinScreenTestTags.PASTE_BUTTON),
            )
            BeidPrimaryButton(
                text = stringResource(R.string.event_join_button),
                containerColor = BeidTheme.colors.actionPrimary,
                contentColor = BeidTheme.colors.surfaceCanvas,
                onClick = onSubmit,
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
    cards: List<NearbyEventCard>,
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
                if (card.displayValidFromEpochSeconds != null && card.displayValidUntilEpochSeconds != null) Text(
                    text = stringResource(
                        R.string.event_join_validity_period,
                        card.displayValidFromEpochSeconds,
                        card.displayValidUntilEpochSeconds,
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
fun EventJoinRoute(
    session: EventJoinSession,
    onOpenAccount: () -> Unit,
    onOpenManualEventCode: () -> Unit,
) {
    LaunchedEffect(session) { session.startNearbyEventDiscovery() }
    val viewModel: EventJoinViewModel = viewModel(factory = EventJoinViewModel.Factory(session))
    EventJoinScreen(viewModel, onOpenAccount, onOpenManualEventCode)
}

@Composable
private fun statusText(state: EventJoinUiState): String = when (state) {
    is EventJoinUiState.Idle -> stringResource(R.string.event_join_status_idle)
    is EventJoinUiState.RequestingPermission -> stringResource(R.string.event_join_status_requesting_permission)
    is EventJoinUiState.VerifyingRegistry -> stringResource(R.string.event_join_status_verifying_registry)
    is EventJoinUiState.Sensing -> phaseStatusText(state.phase)
    is EventJoinUiState.PermissionDenied -> stringResource(R.string.event_join_status_permission_denied)
    // Same copy as the field-level message, reached through the same shared
    // reason, so the status line and the inline error cannot say two different
    // things about one refusal.
    is EventJoinUiState.JoinFailed -> EventJoinFieldError.JoinFailed(state.reason).message()
}

@Composable
private fun phaseStatusText(phase: ScanPhase): String = when (phase) {
    ScanPhase.Idle, ScanPhase.Sensing -> stringResource(R.string.event_join_status_sensing)
    is ScanPhase.EventFound -> stringResource(R.string.event_join_status_event_found)
    is ScanPhase.Recording -> stringResource(R.string.event_join_status_recording)
    is ScanPhase.SignalLost -> stringResource(R.string.event_join_status_signal_lost)
}

@Composable
private fun EventJoinContentPreview(state: EventJoinScreenState) {
    BeidAppTheme {
        EventJoinContent(
            state = state,
            onOpenAccount = {},
            onJoinNearbyEvent = {},
            onOpenSettings = {},
            onSimulateSignalLost = {},
            onResumeSensing = {},
        )
    }
}

@Preview(name = "Idle — searching for nearby events", showBackground = true)
@Composable
private fun EventJoinScreenPreview() {
    EventJoinContentPreview(EventJoinScreenState(sessionState = EventJoinUiState.Idle))
}

/**
 * Pins the nearby-event card list, including the "waiting for event
 * verification" card that stays display-only (beid#350) — the state
 * beid#363 made reachable from a preview and a DEBUG scenario.
 */
@Preview(name = "Idle — verified and unverified nearby cards", showBackground = true)
@Composable
private fun EventJoinScreenNearbyCardsPreview() {
    EventJoinContentPreview(
        EventJoinScreenState(
            sessionState = EventJoinUiState.Idle,
            nearbyEventCards = listOf(
                NearbyEventCard("Shibuya Open Space", "0x0123456789abcdef", 1_756_000_000L, 1_756_086_400L, "1111111111111111"),
                NearbyEventCard("Unnamed beacon nearby", null, null, null, "2222222222222222"),
            ),
            selectedNearbyEventHashHex = "1111111111111111",
        ),
    )
}

@Preview(name = "Permission denied", showBackground = true)
@Composable
private fun EventJoinScreenPermissionDeniedPreview() {
    EventJoinContentPreview(EventJoinScreenState(sessionState = EventJoinUiState.PermissionDenied))
}

/**
 * beid#463's rescue offer, and the case it exists for: a card on screen that
 * cannot be joined. An implementation that decided this on an empty list would
 * render this preview without the button.
 */
@Preview(name = "Idle — search found nothing joinable, rescue offered", showBackground = true)
@Composable
private fun EventJoinScreenRescueOfferedPreview() {
    EventJoinContentPreview(
        EventJoinScreenState(
            sessionState = EventJoinUiState.Idle,
            nearbyEventCards = listOf(
                NearbyEventCard("Unnamed beacon nearby", null, null, null, "2222222222222222"),
            ),
            searchOutcome = NearbyEventSearchOutcome.RESCUE_ENTRY_OFFERED,
        ),
    )
}

@Composable
private fun ManualEventCodeContentPreview(error: EventJoinFieldError) {
    BeidAppTheme {
        ManualEventCodeContent(
            state = EventJoinScreenState(fieldError = error),
            onEventCodeChanged = {},
            onSubmit = {},
        )
    }
}

@Preview(name = "Manual entry — error, empty code", showBackground = true)
@Composable
private fun ManualEventCodeEmptyCodeErrorPreview() {
    ManualEventCodeContentPreview(EventJoinFieldError.EmptyCode)
}

/**
 * The refusal a participant on a dead network sees (beid#463, acceptance
 * condition 3). Pinned as its own preview rather than folded into a generic
 * join-failure one, because the whole point is that this message differs from
 * every other refusal: it is the only one that does not ask them to check the
 * code.
 */
@Preview(name = "Manual entry — error, network required", showBackground = true)
@Composable
private fun ManualEventCodeNetworkRequiredErrorPreview() {
    ManualEventCodeContentPreview(EventJoinFieldError.JoinFailed(EventJoinFailureReason.NETWORK_REQUIRED))
}

/** The refusal for a code that resolved to some other event (beid#463). */
@Preview(name = "Manual entry — error, code did not match the event", showBackground = true)
@Composable
private fun ManualEventCodeMismatchErrorPreview() {
    ManualEventCodeContentPreview(EventJoinFieldError.JoinFailed(EventJoinFailureReason.CODE_MISMATCH))
}
