package org.levarac.beid.ui.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.requiredSize
import androidx.compose.foundation.layout.wrapContentWidth
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.SemanticsPropertyKey
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay
import org.levarac.beid.R
import org.levarac.beid.sensing.ScanEventSession
import org.levarac.beid.sensing.RadarPeerLiveness
import org.levarac.beid.sensing.ScanPhase
import org.levarac.beid.sensing.SensingRadarPeerSignal
import org.levarac.beid.ui.designsystem.BeidGlyph
import org.levarac.beid.ui.designsystem.BeidHeroHeader
import org.levarac.beid.ui.designsystem.BeidMetricRow
import org.levarac.beid.ui.designsystem.BeidPrimaryButton
import org.levarac.beid.ui.designsystem.BeidSecondaryButton
import org.levarac.beid.ui.designsystem.BeidStatusPill
import org.levarac.beid.ui.designsystem.EncounterFieldPulseGlyph
import org.levarac.beid.ui.designsystem.ProofSealMarkGlyph
import org.levarac.beid.ui.designsystem.SensingRadar
import org.levarac.beid.ui.designsystem.SensingRadarPeer
import org.levarac.beid.ui.theme.BeidFont
import org.levarac.beid.ui.theme.BeidSize
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
 * visible above them alongside Close, so a user can still reach Account
 * (and "Leave Event") during an active session. Because of
 * that, none of these take [org.levarac.beid.ui.designsystem.BeidScreen]/
 * `BeidStateScreen` (both call `Modifier.fillMaxSize()`, which throws when
 * measured inside `EventJoinScreen`'s existing `verticalScroll` Column,
 * whose children are measured with unbounded height) — every screen below
 * is a plain `Column`, the same embedded-content shape the `ScanPhaseDetail`
 * composable this replaces already used.
 *
 * [ScanEventSession] carries an optional name and canonical ID from verified
 * join. Missing display metadata stays absent; these screens do not invent
 * a name or expose an identity-verification retry state they do not own.
 */
@Composable
fun ScanFlowScreen(
    phase: ScanPhase,
    showEntranceCeremony: Boolean,
    onCeremonyFinished: () -> Unit,
    showSimulateSignalLost: Boolean = false,
    onSimulateSignalLost: () -> Unit,
    onResumeSensing: () -> Unit,
    onStartWalletBinding: () -> Unit = {},
    radarPeers: List<SensingRadarPeerSignal> = emptyList(),
    radarPeerLastHeardAtMillis: (String) -> Long? = { null },
) {
    when (phase) {
        ScanPhase.Idle, ScanPhase.Sensing -> SensingScreen()
        is ScanPhase.EventFound -> EventFoundScreen(phase.session, radarPeers, radarPeerLastHeardAtMillis)
        is ScanPhase.Recording -> RecordingScreen(
            session = phase.session,
            peersVerified = phase.peersVerified,
            showEntranceCeremony = showEntranceCeremony,
            onCeremonyFinished = onCeremonyFinished,
            showSimulateSignalLost = showSimulateSignalLost,
            onSimulateSignalLost = onSimulateSignalLost,
            onStartWalletBinding = onStartWalletBinding,
            radarPeers = radarPeers,
            radarPeerLastHeardAtMillis = radarPeerLastHeardAtMillis,
        )
        is ScanPhase.SignalLost -> SignalLostScreen(
            session = phase.session,
            peersVerified = phase.peersVerified,
            onResumeSensing = onResumeSensing,
        )
    }
}

/**
 * Screen 05: Sensing — the joined-but-no-event-yet phase. No radar here: on
 * iOS the radar belongs to `SensingSessionSurface`, which only EventFound and
 * Recording use; this phase's iOS screen is the pre-join `SensingView`. The
 * radar itself is [SessionRadar] below (beid#722).
 */
@Composable
fun SensingScreen() {
    val sensingStatus = stringResource(R.string.event_join_status_sensing)
    Column(
        modifier = Modifier.fillMaxWidth(),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(BeidSpacing.l),
    ) {
        BeidStatusPill(
            label = stringResource(R.string.event_join_status_pill_active),
            tone = BeidStatusPill.Tone.Active,
            modifier = Modifier.testTag(EventJoinScreenTestTags.PHASE_STATUS_PILL),
        )
        Text(
            text = stringResource(R.string.scan_sensing_heading),
            style = MaterialTheme.typography.headlineSmall,
            color = BeidTheme.colors.textPrimary,
            modifier = Modifier.semantics { heading() },
        )
        CircularProgressIndicator(
            color = BeidTheme.colors.actionPrimary,
            modifier = Modifier.semantics {
                stateDescription = sensingStatus
            },
        )
        BeidGlyph(
            tint = BeidTheme.colors.actionPrimary,
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
fun EventFoundScreen(
    session: ScanEventSession,
    radarPeers: List<SensingRadarPeerSignal> = emptyList(),
    radarPeerLastHeardAtMillis: (String) -> Long? = { null },
) {
    val foundMessage = stringResource(R.string.scan_event_found_message)
    val foundStatus = stringResource(R.string.scan_event_found_status)
    Column(
        modifier = Modifier.fillMaxWidth().semantics {
            stateDescription = foundMessage
            liveRegion = LiveRegionMode.Polite
        },
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(BeidSpacing.l),
    ) {
        BeidHeroHeader(
            icon = Icons.Filled.AutoAwesome,
            title = stringResource(R.string.scan_event_found_title),
            subtitle = foundMessage,
            tint = BeidTheme.colors.actionPrimary,
        )
        BeidStatusPill(
            label = foundStatus,
            tone = BeidStatusPill.Tone.Active,
        )
        SessionRadar(radarPeers, radarPeerLastHeardAtMillis)
        CircularProgressIndicator(
            color = BeidTheme.colors.actionPrimary,
            modifier = Modifier.semantics {
                stateDescription = foundStatus
            },
        )
    }
}

/**
 * Screens 06b/06c/07 merged: the steady Recording phase — mirrors iOS's
 * `RecordingView`. Tinted [BeidTheme.colors.actionPrimary] throughout (not
 * just the ceremony), matching iOS's `.tint(DS.Color.actionPrimary)` on the
 * whole view (#628: Flat 2b has one ink).
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
    showSimulateSignalLost: Boolean = false,
    onSimulateSignalLost: () -> Unit,
    onStartWalletBinding: () -> Unit = {},
    ceremonyDwellMillis: Long = 2000,
    radarPeers: List<SensingRadarPeerSignal> = emptyList(),
    radarPeerLastHeardAtMillis: (String) -> Long? = { null },
) {
    val recordingStatus = stringResource(R.string.event_join_status_recording)
    var showCeremony by remember { mutableStateOf(showEntranceCeremony) }

    LaunchedEffect(session) {
        onCeremonyFinished()
        if (showEntranceCeremony) {
            delay(ceremonyDwellMillis)
            showCeremony = false
        }
    }

    Column(
        modifier = Modifier.fillMaxWidth(),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(BeidSpacing.l),
    ) {
        session.eventName?.let { eventName ->
            Text(
                text = eventName,
                style = MaterialTheme.typography.titleLarge,
                color = BeidTheme.colors.textPrimary,
                textAlign = TextAlign.Center,
                modifier = Modifier.fillMaxWidth().semantics { heading() },
            )
        }
        if (showCeremony) {
            BeidHeroHeader(
                title = stringResource(R.string.scan_recording_ceremony_title),
                subtitle = stringResource(R.string.scan_recording_ceremony_subtitle),
                tint = BeidTheme.colors.actionPrimary,
                contentSlot = { ProofSealMarkGlyph() },
            )
        } else {
            BeidStatusPill(
                label = stringResource(R.string.event_join_status_pill_active),
                tone = BeidStatusPill.Tone.Active,
                modifier = Modifier.semantics {
                    stateDescription = recordingStatus
                    liveRegion = LiveRegionMode.Polite
                },
            )
            Text(
                text = stringResource(R.string.scan_recording_heading),
                style = MaterialTheme.typography.headlineSmall,
                color = BeidTheme.colors.textPrimary,
                modifier = Modifier.semantics { heading() },
            )
            Text(
                text = stringResource(R.string.scan_recording_supporting),
                style = MaterialTheme.typography.bodyLarge,
                color = BeidTheme.colors.textSecondary,
            )
            SessionRadar(radarPeers, radarPeerLastHeardAtMillis)
            BeidMetricRow(
                label = stringResource(R.string.event_join_peers_verified_label),
                value = peersVerified.toString(),
                modifier = Modifier.testTag(EventJoinScreenTestTags.PEERS_VERIFIED_ROW),
            )
            // Debug builds only (beid#651), mirroring iOS's `#if DEBUG` gate in
            // RecordingView.swift. The owner decided on 2026-09-22 not to build real
            // signal-loss detection, so this is the only route to SignalLost.
            if (showSimulateSignalLost) {
                BeidSecondaryButton(
                    text = stringResource(R.string.event_join_simulate_signal_lost),
                    contentColor = BeidTheme.colors.actionPrimary,
                    borderColor = BeidTheme.colors.actionPrimary,
                    onClick = onSimulateSignalLost,
                    modifier = Modifier.testTag(EventJoinScreenTestTags.SIMULATE_SIGNAL_LOST_BUTTON),
                )
            }
            BeidSecondaryButton(
                text = stringResource(R.string.event_join_bind_wallet),
                contentColor = BeidTheme.colors.actionPrimary,
                borderColor = BeidTheme.colors.actionPrimary,
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
    val signalLostStatus = stringResource(R.string.event_join_status_signal_lost)
    Column(
        modifier = Modifier.fillMaxWidth().semantics {
            stateDescription = signalLostStatus
            liveRegion = LiveRegionMode.Polite
        },
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(BeidSpacing.l),
    ) {
        BeidHeroHeader(
            icon = Icons.Filled.Warning,
            title = stringResource(R.string.scan_signal_lost_title),
            subtitle = stringResource(R.string.scan_signal_lost_message, session.eventName ?: session.eventCode),
            tint = BeidTheme.colors.actionPrimary,
        )
        BeidStatusPill(
            label = stringResource(R.string.event_join_status_pill_paused),
            tone = BeidStatusPill.Tone.Paused,
            modifier = Modifier.testTag(EventJoinScreenTestTags.PHASE_STATUS_PILL),
        )
        Text(
            text = stringResource(R.string.scan_signal_lost_supporting),
            style = MaterialTheme.typography.bodyLarge,
            color = BeidTheme.colors.textSecondary,
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
            containerColor = BeidTheme.colors.actionPrimary,
            contentColor = BeidTheme.colors.labelOnActionPrimary,
            onClick = onResumeSensing,
            modifier = Modifier.testTag(EventJoinScreenTestTags.RESUME_BUTTON),
        )
    }
}

/**
 * The session radar's wall clock, in epoch milliseconds: the same base as
 * Barnard's event timestamps. Injectable so tests can drive time.
 */
internal val LocalSessionRadarClock = staticCompositionLocalOf<() -> Long> { System::currentTimeMillis }

/** Test-only: the dim flag of every peer the session radar is given, in order. Never an id. */
internal val SessionRadarDimmedPeers = SemanticsPropertyKey<List<Boolean>>("SessionRadarDimmedPeers")

/** iOS `TimelineView(.periodic(from: .now, by: 1))`. */
private const val SESSION_RADAR_TICK_MILLIS = 1_000L

/**
 * The sensing radar (beid#722, iOS `SensingSessionSurface`'s
 * `SensingRadarView`) for EventFound and Recording.
 *
 * - Peers: the detected peers of the live session, as
 *   [org.levarac.beid.sensing.EventJoinSession.radarPeers] publishes them;
 *   a new list per detection recomposes and redraws it. Ids place a node only.
 * - Liveness (release/1.1.0 `SensingView.radarPeers(at:)`, #855/#901): a
 *   one-second ticker re-reads the wall clock ([LocalSessionRadarClock]) and
 *   each peer's last-heard time
 *   ([org.levarac.beid.sensing.EventJoinSession.radarPeerLastHeardAtMillis]),
 *   so with no new observation a peer dims from 30 s of silence and leaves
 *   the radar at 300 s ([RadarPeerLiveness]). The last-heard time is read
 *   live, never from the published list, because an RSSI sample moves it
 *   without a republish.
 * - Caption: "HEARD IN THE LAST 5 MINUTES" directly below the radar, as
 *   release/1.1.0 `SensingSessionSurface` draws it (DESIGN.md), so the
 *   300 s window is visible and not only spoken. Mono 11 in `textSecondary`,
 *   not iOS's `textSecondaryOnInk`: this radar sits on the light page, not on
 *   an ink panel. Left readable by TalkBack, as iOS leaves it for VoiceOver.
 * - Edges: never. iOS (integration/ios-1.1.1, still so in release/1.1.0
 *   `SensingView`) hardcodes `showsEdges: false` for every presentation (an
 *   edge would suggest a two-way link no device measures); SubPM decision
 *   2026-11-19, superseding main/#795's per-presentation edges.
 * - Counts: 0 and 0. The radar speaks only the number of devices heard
 *   (release/1.1.0 `radar.accessibility.devicesHeard`) and draws neither
 *   count, and iOS itself passes `mutualDeviceCount: 0`.
 * - Not yet ported from release/1.1.0 `SensingView`: the recorded-window
 *   mark; the component supports it, this caller does not pass it. The live
 *   window count sits behind `scanSessionMetrics`, whose aggregation is
 *   evaluated only while 05e is visible, so it is not run per detection for a
 *   value nothing reads.
 * - Size: iOS `min(radarField, width - pageMargin)`, where width is the screen
 *   width outside the page margins. This content sits inside Now's
 *   page-margin inset (two margins), so that width is [maxWidth] plus two
 *   margins; the radar may overflow the column by half a margin each side,
 *   centred, exactly as on iOS.
 */
@Composable
private fun SessionRadar(radarPeers: List<SensingRadarPeerSignal>, lastHeardAtMillis: (String) -> Long?) {
    val clock = LocalSessionRadarClock.current
    var nowMillis by remember(clock) { mutableLongStateOf(clock()) }
    LaunchedEffect(clock) {
        while (true) {
            delay(SESSION_RADAR_TICK_MILLIS)
            nowMillis = clock()
        }
    }
    // Not remembered: last-heard times move without a recomposition, so they
    // are re-read on every tick and every new list.
    val peers = radarPeers.mapNotNull { peer ->
        val lastHeard = lastHeardAtMillis(peer.displayId)
        if (!RadarPeerLiveness.isCurrent(lastHeard, nowMillis)) return@mapNotNull null
        SensingRadarPeer(peer.displayId, peer.dbm, isDimmed = RadarPeerLiveness.isDimmed(lastHeard, nowMillis))
    }
    Column(
        modifier = Modifier.fillMaxWidth(),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(BeidSpacing.m),
    ) {
        BoxWithConstraints(
            Modifier.fillMaxWidth().semantics { this[SessionRadarDimmedPeers] = peers.map { it.isDimmed } },
            contentAlignment = Alignment.Center,
        ) {
            val size = minOf(BeidSize.radarField, maxWidth + BeidSpacing.pageMargin).coerceAtLeast(0.dp)
            SensingRadar(
                peers = peers,
                mutualDeviceCount = 0,
                observedWindowCount = 0,
                modifier = Modifier.requiredSize(size),
                showsEdges = false,
                size = size,
            )
        }
        NowStyledText(
            text = stringResource(R.string.radar_time_window_caption),
            style = BeidFont.Library.labelMono11,
            color = BeidTheme.colors.textSecondary,
            modifier = Modifier.fillMaxWidth().wrapContentWidth(Alignment.CenterHorizontally),
        )
    }
}
