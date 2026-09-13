package org.levarac.beid.ui.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import kotlinx.coroutines.delay
import org.levarac.beid.R
import org.levarac.beid.sensing.ScanEventSession
import org.levarac.beid.sensing.ScanPhase
import org.levarac.beid.ui.designsystem.BeidGlyph
import org.levarac.beid.ui.designsystem.BeidHeroHeader
import org.levarac.beid.ui.designsystem.BeidMetricRow
import org.levarac.beid.ui.designsystem.BeidPrimaryButton
import org.levarac.beid.ui.designsystem.BeidSecondaryButton
import org.levarac.beid.ui.designsystem.BeidStatusPill
import org.levarac.beid.ui.designsystem.EncounterFieldPulseGlyph
import org.levarac.beid.ui.designsystem.ProofSealMarkGlyph
import org.levarac.beid.ui.theme.BeidSpacing
import org.levarac.beid.ui.theme.BeidTheme

/**
 * The four full-screen bodies of the scan flow (mirrors iOS's
 * `ios/Beid/Views/{Sensing,EventFound,Recording,SignalLost}View.swift`),
 * plus [ScanFlowScreen], the router that mirrors iOS's
 * `ScanFlowContent.route(for:)`/`.view(phase:sensing:)`.
 *
 * Unlike iOS's `ScanFlowView` (a full-screen cover with its own
 * `NavigationStack` + toolbar), these screens are composed as a *portion*
 * of `EventJoinScreen`'s existing content — the account-entry text stays
 * visible above them so a user can still reach Account (and "Leave Event")
 * during an active session, Android's only such affordance. Because of
 * that, none of these take [org.levarac.beid.ui.designsystem.BeidScreen]/
 * `BeidStateScreen` (both call `Modifier.fillMaxSize()`, which throws when
 * measured inside `EventJoinScreen`'s existing `verticalScroll` Column,
 * whose children are measured with unbounded height) — every screen below
 * is a plain `Column`, the same embedded-content shape the `ScanPhaseDetail`
 * composable this replaces already used.
 *
 * **Data gap vs. iOS, stated once here for all four screens:** Android's
 * [ScanEventSession] is `data class ScanEventSession(val eventCode: String)`
 * — it carries none of iOS's richer `EventSession` (display name, identity
 * verification status). These screens show only what that model actually
 * has; they do not invent an event name or fake a verification-retry
 * affordance. [EventFoundScreen] and the steady-state [RecordingScreen]
 * accordingly show no event-identity content beyond what their design
 * calls for; [SignalLostScreen] is the one screen whose copy needs "the
 * event," and it uses the one real field, `eventCode`.
 */
@Composable
fun ScanFlowScreen(
    phase: ScanPhase,
    showEntranceCeremony: Boolean,
    onCeremonyFinished: () -> Unit,
    onSimulateSignalLost: () -> Unit,
    onResumeSensing: () -> Unit,
    onStartWalletBinding: () -> Unit = {},
) {
    when (phase) {
        ScanPhase.Idle, ScanPhase.Sensing -> SensingScreen()
        is ScanPhase.EventFound -> EventFoundScreen(phase.session)
        is ScanPhase.Recording -> RecordingScreen(
            session = phase.session,
            peersVerified = phase.peersVerified,
            showEntranceCeremony = showEntranceCeremony,
            onCeremonyFinished = onCeremonyFinished,
            onSimulateSignalLost = onSimulateSignalLost,
            onStartWalletBinding = onStartWalletBinding,
        )
        is ScanPhase.SignalLost -> SignalLostScreen(
            session = phase.session,
            peersVerified = phase.peersVerified,
            onResumeSensing = onResumeSensing,
        )
    }
}

/**
 * Screen 05: Sensing — mirrors iOS's `SensingView`. iOS's animated radar
 * rings (`DS.Motion`) are not ported: DESIGN.md marks `DS.Motion` springs
 * `PROPOSAL — Ken ratification pending`, and android/README.md already
 * defers all Compose animation-spec work to "once a motion-bearing screen
 * lands" — this is that screen, but the motion itself stays out of scope
 * for beid#336, which is about phase *content*, not animation.
 */
@Composable
fun SensingScreen() {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(BeidSpacing.l),
    ) {
        BeidStatusPill(
            label = stringResource(R.string.event_join_status_pill_active),
            tone = BeidStatusPill.Tone.Active,
            modifier = Modifier.testTag(EventJoinScreenTestTags.PHASE_STATUS_PILL),
        )
        BeidGlyph(
            tint = BeidTheme.colors.signalActive,
            contentSlot = { EncounterFieldPulseGlyph() },
        )
        Text(
            text = stringResource(R.string.scan_sensing_message),
            style = MaterialTheme.typography.bodyLarge,
            color = BeidTheme.colors.textSecondary,
            textAlign = TextAlign.Center,
        )
    }
}

/**
 * Screen 06a: Event Found — mirrors iOS's `EventFoundView`. No retry
 * affordance: Android has no identity-verification state to retry (see
 * this file's data-gap note), so [ScanEventSession] is accepted only for
 * signature symmetry with the other phase screens and future extensibility
 * once Android's session model grows.
 */
@Composable
fun EventFoundScreen(session: ScanEventSession) {
    BeidHeroHeader(
        icon = Icons.Filled.AutoAwesome,
        title = stringResource(R.string.scan_event_found_title),
        subtitle = stringResource(R.string.scan_event_found_message),
        tint = BeidTheme.colors.signalActive,
    )
}

/**
 * Screens 06b/06c/07 merged: the steady Recording phase — mirrors iOS's
 * `RecordingView`. Tinted [BeidTheme.colors.proofSeal] throughout (not just
 * the ceremony), matching iOS's `.tint(DS.Color.proofSeal)` on the whole
 * view.
 *
 * [showEntranceCeremony] is read exactly once, at this composable's first
 * composition ([remember]'s seed-once semantics — the Compose analogue of
 * iOS's `@State private var showEntranceCeremony: Bool` seeded once in
 * `init`), so later recompositions of the same instance (e.g.
 * [peersVerified] growing) never re-evaluate it. [onCeremonyFinished] fires
 * immediately in the [LaunchedEffect] below — before [ceremonyDwellMillis]
 * elapses, not after — mirroring iOS's `RecordingView.onAppear` calling
 * `sensing.markRecordingCeremonyShown()` right away: a session that ends
 * mid-ceremony (backgrounded, navigated away) must still not replay the
 * ceremony next time. The [LaunchedEffect] is keyed on [session] (stable
 * across [peersVerified] growth within one continuous Recording phase, see
 * [ScanPhase.Recording]'s `.copy(peersVerified = ...)` call site) rather
 * than on the whole [ScanPhase.Recording] payload, specifically so a
 * `peersVerified` update never restarts the dwell timer.
 */
@Composable
fun RecordingScreen(
    session: ScanEventSession,
    peersVerified: Int,
    showEntranceCeremony: Boolean,
    onCeremonyFinished: () -> Unit,
    onSimulateSignalLost: () -> Unit,
    onStartWalletBinding: () -> Unit = {},
    ceremonyDwellMillis: Long = 2000,
) {
    var showCeremony by remember { mutableStateOf(showEntranceCeremony) }

    LaunchedEffect(session) {
        onCeremonyFinished()
        if (showEntranceCeremony) {
            delay(ceremonyDwellMillis)
            showCeremony = false
        }
    }

    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(BeidSpacing.l),
    ) {
        if (showCeremony) {
            BeidHeroHeader(
                title = stringResource(R.string.scan_recording_ceremony_title),
                subtitle = stringResource(R.string.scan_recording_ceremony_subtitle),
                tint = BeidTheme.colors.proofSeal,
                contentSlot = { ProofSealMarkGlyph() },
            )
        } else {
            BeidMetricRow(
                label = stringResource(R.string.event_join_peers_verified_label),
                value = peersVerified.toString(),
                modifier = Modifier.testTag(EventJoinScreenTestTags.PEERS_VERIFIED_ROW),
            )
            // Android has no real BLE signal-loss detection yet (mirrors iOS's own
            // demo-only manual trigger) — this is the only way to reach SignalLost
            // until real detection lands.
            BeidSecondaryButton(
                text = stringResource(R.string.event_join_simulate_signal_lost),
                contentColor = BeidTheme.colors.proofSeal,
                borderColor = BeidTheme.colors.proofSeal,
                onClick = onSimulateSignalLost,
                modifier = Modifier.testTag(EventJoinScreenTestTags.SIMULATE_SIGNAL_LOST_BUTTON),
            )
            BeidSecondaryButton(
                text = stringResource(R.string.event_join_bind_wallet),
                contentColor = BeidTheme.colors.proofSeal,
                borderColor = BeidTheme.colors.proofSeal,
                onClick = onStartWalletBinding,
                modifier = Modifier.testTag(EventJoinScreenTestTags.BIND_WALLET_BUTTON),
            )
        }
    }
}

/**
 * Screen 06d: Signal Lost — a pause, not a restart; [peersVerified] is
 * frozen but preserved. Mirrors iOS's `SignalLostView`. No retry
 * affordance, same reason as [EventFoundScreen].
 */
@Composable
fun SignalLostScreen(session: ScanEventSession, peersVerified: Int, onResumeSensing: () -> Unit) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(BeidSpacing.l),
    ) {
        BeidHeroHeader(
            icon = Icons.Filled.Warning,
            title = stringResource(R.string.scan_signal_lost_title),
            subtitle = stringResource(R.string.scan_signal_lost_message, session.eventCode),
            tint = BeidTheme.colors.signalWarning,
        )
        BeidStatusPill(
            label = stringResource(R.string.event_join_status_pill_paused),
            tone = BeidStatusPill.Tone.Paused,
            modifier = Modifier.testTag(EventJoinScreenTestTags.PHASE_STATUS_PILL),
        )
        BeidMetricRow(
            label = stringResource(R.string.event_join_peers_verified_label),
            value = peersVerified.toString(),
            modifier = Modifier.testTag(EventJoinScreenTestTags.PEERS_VERIFIED_ROW),
        )
        // "Try Again" keeps its exact label (DESIGN.md §11), but resumes the same
        // session in place — never a restart, which would discard peersVerified.
        BeidPrimaryButton(
            text = stringResource(R.string.event_join_resume_sensing),
            containerColor = BeidTheme.colors.signalWarning,
            contentColor = BeidTheme.colors.labelOnWarning,
            onClick = onResumeSensing,
            modifier = Modifier.testTag(EventJoinScreenTestTags.RESUME_BUTTON),
        )
    }
}
