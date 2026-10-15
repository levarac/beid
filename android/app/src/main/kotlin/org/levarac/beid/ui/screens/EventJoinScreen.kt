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
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowBack
import androidx.compose.material.icons.filled.AccountCircle
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.tooling.preview.Preview
import androidx.lifecycle.viewmodel.compose.viewModel
import org.levarac.beid.BuildConfig
import org.levarac.beid.R
import org.levarac.beid.sensing.ClockPreflightController
import org.levarac.beid.sensing.OperatorDateHeaderSource
import org.levarac.beid.sensing.operatorOriginOrNull
import org.levarac.beid.sensing.EventJoinSession
import org.levarac.beid.sensing.EventJoinUiState
import org.levarac.beid.sensing.NearbyEventCard
import org.levarac.beid.sensing.NearbyEventCardVerification
import org.levarac.beid.sensing.ScanPhase
import org.levarac.beid.shared.event.EventJoinFailureReason
import org.levarac.beid.shared.event.NearbyEventSearchOutcome
import org.levarac.beid.ui.designsystem.BeidPanel
import org.levarac.beid.ui.designsystem.BeidPrimaryButton
import org.levarac.beid.ui.designsystem.BeidSecondaryButton
import org.levarac.beid.ui.designsystem.BeidStatusPill
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
    const val MANUAL_BACK_BUTTON = "event_join_manual_back_button"
    const val NEARBY_EVENT_LIST = "nearby_event_list"
    const val NEARBY_EVENTS_OMITTED = "nearby_events_omitted"

    /** beid#463: the rescue route out of a search that found nothing joinable. */
    const val RESCUE_ENTRY_BUTTON = "event_join_rescue_entry_button"

    /** beid#463: fills the code field from the clipboard, so no one hand-types 64 hex characters. */
    const val PASTE_BUTTON = "event_join_paste_button"
    const val BIND_WALLET_BUTTON = "event_join_bind_wallet_button"

    /** beid#464: the device-clock notice and its "Check again" action. */
    const val CLOCK_PREFLIGHT_NOTICE = "event_join_clock_preflight_notice"
    const val CLOCK_PREFLIGHT_RETRY = "event_join_clock_preflight_retry"

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
 *
 * [showSimulateSignalLost] defaults to `BuildConfig.DEBUG`, so the
 * Recording screen's test-only signal-loss trigger is absent from release
 * builds (beid#651); the renderers below it default to `false`.
 */
@Composable
fun EventJoinScreen(
    viewModel: EventJoinViewModel,
    onOpenAccount: () -> Unit,
    onOpenManualEventCode: () -> Unit,
    onStartWalletBinding: () -> Unit = {},
    showSimulateSignalLost: Boolean = BuildConfig.DEBUG,
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
        onStartWalletBinding = onStartWalletBinding,
        onRetryClockPreflight = viewModel::retryClockPreflight,
        showEntranceCeremony = !uiState.recordingCeremonyShown,
        onCeremonyFinished = viewModel::markRecordingCeremonyShown,
        showSimulateSignalLost = showSimulateSignalLost,
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
@OptIn(ExperimentalMaterial3Api::class)
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
    onStartWalletBinding: () -> Unit = {},
    /** beid#464. A no-op on the read-only scenario/preview path, which has no preflight. */
    onRetryClockPreflight: () -> Unit = {},
    showEntranceCeremony: Boolean = false,
    onCeremonyFinished: () -> Unit = {},
    showSimulateSignalLost: Boolean = false,
) {
    Scaffold(
        containerColor = BeidTheme.colors.surfaceCanvas,
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.event_join_title)) },
                actions = {
                    IconButton(
                        onClick = onOpenAccount,
                        modifier = Modifier.testTag(EventJoinScreenTestTags.ACCOUNT_ENTRY),
                    ) {
                        Icon(
                            imageVector = Icons.Filled.AccountCircle,
                            contentDescription = stringResource(R.string.event_join_account_action),
                        )
                    }
                },
            )
        },
    ) { innerPadding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding)
                .padding(horizontal = BeidSpacing.pageMargin)
                .padding(top = BeidSpacing.l, bottom = BeidSpacing.l)
                .verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(BeidSpacing.l),
        ) {
            val sessionState = state.sessionState
            if (sessionState is EventJoinUiState.Sensing) {
                ScanFlowScreen(
                    phase = sessionState.phase,
                    showEntranceCeremony = showEntranceCeremony,
                    onCeremonyFinished = onCeremonyFinished,
                    showSimulateSignalLost = showSimulateSignalLost,
                    onSimulateSignalLost = onSimulateSignalLost,
                    onResumeSensing = onResumeSensing,
                    onStartWalletBinding = onStartWalletBinding,
                )
            } else {
                Text(
                    text = stringResource(R.string.event_join_discovery_heading),
                    style = MaterialTheme.typography.headlineSmall,
                    color = BeidTheme.colors.textPrimary,
                    modifier = Modifier.semantics { heading() },
                )
                Text(
                    text = stringResource(R.string.event_join_discovery_supporting),
                    style = MaterialTheme.typography.bodyLarge,
                    color = BeidTheme.colors.textSecondary,
                )
                ClockPreflightNotice(state = state.clockPreflight, onRetry = onRetryClockPreflight)
                NearbyEventCards(
                    cards = state.nearbyEventCards,
                    selectedEventHashHex = state.selectedNearbyEventHashHex,
                    searchOutcome = state.searchOutcome,
                    omitted = state.nearbyEventsOmitted,
                    enabled = sessionState is EventJoinUiState.Idle || sessionState is EventJoinUiState.OwnerKeyUnavailable,
                    onJoin = onJoinNearbyEvent,
                    onOpenManualEventCode = onOpenManualEventCode,
                )
                if (sessionState !is EventJoinUiState.Idle) {
                    statusText(sessionState)?.let { currentStatus ->
                        Text(
                            text = currentStatus,
                            style = MaterialTheme.typography.bodyMedium,
                            color = BeidTheme.colors.textSecondary,
                            modifier = Modifier.semantics {
                                stateDescription = currentStatus
                                liveRegion = LiveRegionMode.Polite
                            },
                        )
                    }
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
fun ManualEventCodeScreen(viewModel: EventJoinViewModel, onBack: () -> Unit = {}) {
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
        onBack = onBack,
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
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ManualEventCodeContent(
    state: EventJoinScreenState,
    onEventCodeChanged: (String) -> Unit,
    onPasteEventCode: () -> Unit = {},
    onSubmit: () -> Unit,
    onBack: () -> Unit = {},
) {
    Scaffold(
        containerColor = BeidTheme.colors.surfaceCanvas,
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.event_join_code_label)) },
                navigationIcon = {
                    IconButton(
                        onClick = onBack,
                        modifier = Modifier.testTag(EventJoinScreenTestTags.MANUAL_BACK_BUTTON),
                    ) {
                        Icon(
                            imageVector = Icons.Filled.ArrowBack,
                            contentDescription = stringResource(R.string.event_join_back_action),
                        )
                    }
                },
            )
        },
    ) { innerPadding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding)
                .padding(horizontal = BeidSpacing.pageMargin)
                .padding(top = BeidSpacing.l, bottom = BeidSpacing.l)
                .verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(BeidSpacing.l),
        ) {
            Text(
                stringResource(R.string.event_join_code_label),
                style = MaterialTheme.typography.headlineSmall,
                modifier = Modifier.semantics { heading() },
            )
            Text(
                stringResource(R.string.event_join_code_helper),
                style = MaterialTheme.typography.bodyLarge,
                color = BeidTheme.colors.textSecondary,
            )
            BeidTextField(
                value = state.eventCode,
                onValueChange = onEventCodeChanged,
                placeholder = stringResource(R.string.event_join_code_label),
                isError = state.fieldError != null,
                keyboardOptions = KeyboardOptions(
                    capitalization = KeyboardCapitalization.None,
                    keyboardType = KeyboardType.Ascii,
                    imeAction = ImeAction.Done,
                    autoCorrectEnabled = false,
                ),
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
            if (state.sessionState is EventJoinUiState.OwnerKeyUnavailable) {
                statusText(state.sessionState)?.let { status ->
                    Text(status, color = BeidTheme.colors.textPrimary)
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
@OptIn(ExperimentalMaterial3Api::class)
fun ManualEventCodeRoute(session: EventJoinSession, onBack: () -> Unit = {}) {
    val viewModel: EventJoinViewModel = viewModel(factory = EventJoinViewModel.Factory(session))
    ManualEventCodeScreen(viewModel, onBack)
}

/**
 * Barnard kept 32 hashes and dropped the rest. Saying nothing would leave the
 * list reading as "this is what is nearby", which it is not.
 *
 * **Static, and deliberately without a number.** The SDK reports *that* it
 * dropped events, never how many, so a count here would be invented.
 * `docs/specs/event-discovery.md` §5.3 says append one static row rather than
 * trying to read the omitted event's own payload, which by then carries an
 * empty marker rather than a real hint (beid#450).
 *
 * Shown in the empty branch too: "nothing nearby" plus "some not shown" is
 * the most misleading combination of all.
 */
@Composable
private fun OmittedNearbyEventsRow() {
    Text(
        text = stringResource(R.string.event_join_nearby_events_omitted),
        style = MaterialTheme.typography.bodySmall,
        color = BeidTheme.colors.textSecondary,
        modifier = Modifier.testTag(EventJoinScreenTestTags.NEARBY_EVENTS_OMITTED),
    )
}

@Composable
private fun NearbyEventCards(
    cards: List<NearbyEventCard>,
    selectedEventHashHex: String?,
    searchOutcome: NearbyEventSearchOutcome,
    omitted: Boolean,
    enabled: Boolean,
    onJoin: (String) -> Unit,
    onOpenManualEventCode: () -> Unit,
) {
    if (cards.isEmpty()) {
        val isSearching = searchOutcome == NearbyEventSearchOutcome.SEARCHING
        val searchingLabel = stringResource(
            if (isSearching) R.string.event_join_searching_nearby else R.string.event_join_no_nearby_title,
        )
        BeidPanel(
            modifier = Modifier
                .testTag(EventJoinScreenTestTags.NEARBY_EVENT_LIST),
        ) {
            Column(
                verticalArrangement = Arrangement.spacedBy(BeidSpacing.s),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                if (isSearching) {
                    CircularProgressIndicator(
                        modifier = Modifier.semantics { stateDescription = searchingLabel },
                        color = BeidTheme.colors.signalActive,
                    )
                }
                Text(
                    text = searchingLabel,
                    color = BeidTheme.colors.textPrimary,
                    style = MaterialTheme.typography.titleMedium,
                    modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite },
                )
                if (isSearching) {
                    Text(stringResource(R.string.event_join_rescue_guidance), color = BeidTheme.colors.textSecondary)
                } else {
                    Text(
                        stringResource(R.string.event_join_rescue_prompt),
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
                if (omitted) {
                    OmittedNearbyEventsRow()
                }
            }
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
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Column(
                        modifier = Modifier.weight(1f),
                        verticalArrangement = Arrangement.spacedBy(BeidSpacing.xs),
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
                    }
                    BeidStatusPill(
                        // `eventIdHex` stays the single joinability gate, here as
                        // everywhere else on this card; `verification` only breaks
                        // down the not-yet-joinable case (beid#584).
                        label = stringResource(
                            when {
                                card.eventIdHex != null -> R.string.event_join_candidate_verified
                                card.verification == NearbyEventCardVerification.RETRYING ->
                                    R.string.event_join_candidate_retrying
                                card.verification == NearbyEventCardVerification.NOT_REGISTERED ->
                                    R.string.event_join_candidate_not_registered
                                else -> R.string.event_join_candidate_unverified
                            },
                        ),
                        tone = if (card.eventIdHex != null) BeidStatusPill.Tone.Active else BeidStatusPill.Tone.Neutral,
                    )
                }
                if (card.displayValidFromEpochSeconds != null && card.displayValidUntilEpochSeconds != null) Text(
                    text = stringResource(
                        R.string.event_join_validity_period,
                        card.displayValidFromEpochSeconds,
                        card.displayValidUntilEpochSeconds,
                    ),
                    style = MaterialTheme.typography.bodyMedium,
                    color = BeidTheme.colors.textSecondary,
                )
                // beid#584: this line used to say "Waiting for event
                // verification" for every non-joinable card, including one
                // whose every registry read had failed. It is the full-width
                // line rather than the pill because the pill shares a row with
                // the beacon name and cannot hold a sentence.
                if (card.eventIdHex == null) Text(
                    text = stringResource(
                        when (card.verification) {
                            NearbyEventCardVerification.RETRYING -> R.string.event_join_verification_retrying
                            NearbyEventCardVerification.NOT_REGISTERED ->
                                R.string.event_join_verification_not_registered
                            else -> R.string.event_join_not_joinable_yet
                        },
                    ),
                    style = MaterialTheme.typography.labelSmall,
                    color = BeidTheme.colors.textSecondary,
                )
                if (selected) Text(
                    text = stringResource(R.string.event_join_selected),
                    style = MaterialTheme.typography.labelSmall,
                    color = BeidTheme.colors.textSecondary,
                )
                if (cardEnabled) {
                    Text(
                        text = stringResource(R.string.event_join_join_affordance),
                        style = MaterialTheme.typography.labelLarge,
                        color = BeidTheme.colors.actionPrimary,
                    )
                }
            }
        }
        if (searchOutcome == NearbyEventSearchOutcome.RESCUE_ENTRY_OFFERED) {
            // Candidates and the "nothing found" panel are mutually exclusive.
            // Keep the manual-code escape hatch for an unjoinable candidate,
            // without presenting the contradictory empty-state copy.
            BeidSecondaryButton(
                text = stringResource(R.string.event_join_rescue_enter_code),
                contentColor = BeidTheme.colors.textPrimary,
                borderColor = BeidTheme.colors.textSecondary,
                onClick = onOpenManualEventCode,
                modifier = Modifier.testTag(EventJoinScreenTestTags.RESCUE_ENTRY_BUTTON),
            )
        }

        if (omitted) {
            OmittedNearbyEventsRow()
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
    onStartWalletBinding: () -> Unit = {},
    /** beid#464。テストが偽の日付ソースを渡せるように引数にしている。本番は既定値だけを使う。 */
    clockPreflight: ClockPreflightController = remember {
        ClockPreflightController(
            OperatorDateHeaderSource(operatorOriginOrNull(BuildConfig.EVENT_CODE_LOOKUP_URL_TEMPLATE)),
        )
    },
) {
    LaunchedEffect(session) { session.startNearbyEventDiscovery() }
    val viewModel: EventJoinViewModel = viewModel(factory = EventJoinViewModel.Factory(session, clockPreflight))
    EventJoinScreen(viewModel, onOpenAccount, onOpenManualEventCode, onStartWalletBinding)
}

@Composable
private fun statusText(state: EventJoinUiState): String? = when (state) {
    is EventJoinUiState.Idle -> stringResource(R.string.event_join_status_idle)
    is EventJoinUiState.RequestingPermission -> stringResource(R.string.event_join_status_requesting_permission)
    is EventJoinUiState.VerifyingRegistry -> stringResource(R.string.event_join_status_verifying_registry)
    // Sensing owns the entire body through ScanFlowScreen; it has no status
    // line in the event-discovery body.
    is EventJoinUiState.Sensing -> null
    is EventJoinUiState.OwnerKeyUnavailable -> stringResource(R.string.event_join_owner_key_unavailable)
    is EventJoinUiState.PermissionDenied -> stringResource(R.string.event_join_status_permission_denied)
    // Same copy as the field-level message, reached through the same shared
    // reason, so the status line and the inline error cannot say two different
    // things about one refusal.
    is EventJoinUiState.JoinFailed -> EventJoinFieldError.JoinFailed(state.reason).message()
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
