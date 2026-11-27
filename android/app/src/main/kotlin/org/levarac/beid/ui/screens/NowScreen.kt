package org.levarac.beid.ui.screens

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import org.levarac.beid.R
import org.levarac.beid.navigation.NowStandbyPresentation
import org.levarac.beid.sensing.EventJoinUiState
import org.levarac.beid.sensing.SensingRadarPeerSignal
import org.levarac.beid.ui.designsystem.BeidPrimaryButton
import org.levarac.beid.ui.theme.BeidFont
import org.levarac.beid.ui.theme.BeidRadius
import org.levarac.beid.ui.theme.BeidSize
import org.levarac.beid.ui.theme.BeidSpacing
import org.levarac.beid.ui.theme.BeidTextStyle
import org.levarac.beid.ui.theme.BeidTheme

/** Compose test tags for [NowContent]; not user-facing copy. */
object NowScreenTestTags {
    const val ROOT = "home_now"
    const val TITLE = "home_now_title"
    const val LISTENING = "home_listening"
    const val LISTENING_ELAPSED = "home_listening_elapsed"
    const val ENTER_CODE = "home_enter_code"
    const val ALSO_NEARBY = "home_also_nearby"
    const val BLUETOOTH_OFF = "home_bluetooth_off"
    const val BLUETOOTH_OFF_DOT = "home_bluetooth_off_dot"
    const val BLUETOOTH_FIX = "home_bluetooth_fix"
    const val BLUETOOTH_OPEN_SETTINGS = "home_bluetooth_open_settings"
}

/**
 * The Now tab's body — the Android port of iOS #795's `NowHomeView`
 * (`ios/Beid/Views/CollectionHomeView.swift`), content only: the Home shell
 * supplies the top bar and the tab bar, and [EventJoinContent] wraps the same
 * body in its own top bar for the read-only scenario path (beid#363: one
 * renderer for both).
 *
 * At rest (no session) it shows the large "Now" title, the clock notice, and
 * either the inline Bluetooth-off block or the listening strip, the DO THIS
 * NOW tile, the FOUND NEARBY / ALSO NEARBY candidates (each joined only by an
 * explicit JOIN tap) and, after the standby gate's 30-second wait, ENTER
 * EVENT CODE. Once a session is sensing, the existing in-session screens
 * ([ScanFlowScreen], [SensingStopConfirmScreen]) take over unchanged, with the
 * Bluetooth-off block above them when the radio is off (iOS: the block above
 * the session summary).
 *
 * [bluetoothOff] is a plain input: this file never reads the radio.
 */
@Composable
fun NowContent(
    state: EventJoinScreenState,
    standby: NowStandbyPresentation,
    bluetoothOff: Boolean,
    onJoinNearbyEvent: (String) -> Unit,
    onOpenCodeEntry: () -> Unit,
    onFixBluetooth: () -> Unit,
    onOpenBluetoothSettings: () -> Unit,
    onOpenSettings: () -> Unit,
    onSimulateSignalLost: () -> Unit,
    onResumeSensing: () -> Unit,
    modifier: Modifier = Modifier,
    onStartWalletBinding: () -> Unit = {},
    onRetryClockPreflight: () -> Unit = {},
    showEntranceCeremony: Boolean = false,
    onCeremonyFinished: () -> Unit = {},
    showSimulateSignalLost: Boolean = false,
    onKeepSensing: () -> Unit = {},
    onConfirmStopSensing: () -> Unit = {},
    /** beid#722: the live session's detected peers for the EventFound / Recording radar. */
    radarPeers: List<SensingRadarPeerSignal> = emptyList(),
    /** Display-only last-heard lookup for [radarPeers]; see `EventJoinSession.radarPeerLastHeardAtMillis`. */
    radarPeerLastHeardAtMillis: (String) -> Long? = { null },
) {
    // System Back on the confirmation means "Keep sensing". Home is the
    // navigation root, so an unhandled Back would leave the activity instead.
    BackHandler(enabled = state.stopConfirmation != null) { onKeepSensing() }
    val confirmation = state.stopConfirmation
    if (confirmation != null) {
        SensingStopConfirmScreen(
            event = confirmation.event,
            metrics = state.scanSessionMetrics,
            onStop = onConfirmStopSensing,
            onKeepSensing = onKeepSensing,
            modifier = modifier,
        )
        return
    }
    Column(
        modifier = modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = BeidSpacing.pageMargin)
            .padding(top = BeidSpacing.s, bottom = BeidSpacing.l)
            .testTag(NowScreenTestTags.ROOT),
        verticalArrangement = Arrangement.spacedBy(BeidSpacing.l),
    ) {
        val sessionState = state.sessionState
        if (sessionState is EventJoinUiState.Sensing) {
            if (bluetoothOff) {
                BluetoothOffBlock(onFix = onFixBluetooth, onOpenSettings = onOpenBluetoothSettings)
            }
            ScanFlowScreen(
                phase = sessionState.phase,
                showEntranceCeremony = showEntranceCeremony,
                onCeremonyFinished = onCeremonyFinished,
                showSimulateSignalLost = showSimulateSignalLost,
                onSimulateSignalLost = onSimulateSignalLost,
                onResumeSensing = onResumeSensing,
                onStartWalletBinding = onStartWalletBinding,
                radarPeers = radarPeers,
                radarPeerLastHeardAtMillis = radarPeerLastHeardAtMillis,
            )
            return@Column
        }
        Text(
            text = stringResource(R.string.home_now_title),
            style = BeidFont.Library.display60.textStyle,
            color = BeidTheme.colors.textPrimary,
            modifier = Modifier
                .semantics { heading() }
                .testTag(NowScreenTestTags.TITLE),
        )
        ClockPreflightNotice(state = state.clockPreflight, onRetry = onRetryClockPreflight)
        if (bluetoothOff) {
            BluetoothOffBlock(onFix = onFixBluetooth, onOpenSettings = onOpenBluetoothSettings)
        } else {
            // The discovery region, tagged as the nearby-event list has always
            // been: "back at discovery" is what callers assert with it.
            Column(
                modifier = Modifier.fillMaxWidth().testTag(EventJoinScreenTestTags.NEARBY_EVENT_LIST),
                verticalArrangement = Arrangement.spacedBy(BeidSpacing.l),
            ) {
                ListeningStrip(standby.elapsedSeconds)
                NowInstructionTile(
                    title = stringResource(R.string.now_standby_tile_title),
                    body = stringResource(R.string.now_standby_tile_body),
                )
                NearbyEventCards(
                    cards = state.nearbyEventCards,
                    omitted = state.nearbyEventsOmitted,
                    enabled = sessionState is EventJoinUiState.Idle ||
                        sessionState is EventJoinUiState.OwnerKeyUnavailable ||
                        sessionState is EventJoinUiState.JoinFailed,
                    onJoin = onJoinNearbyEvent,
                )
                if (standby.offersCodeEntry) {
                    NowTextControl(
                        label = stringResource(R.string.now_enter_event_code),
                        accessibilityLabel = stringResource(R.string.now_enter_event_code_accessibility),
                        trailingArrow = true,
                        onClick = onOpenCodeEntry,
                        modifier = Modifier.testTag(NowScreenTestTags.ENTER_CODE),
                    )
                }
            }
        }
        if (sessionState !is EventJoinUiState.Idle) {
            eventJoinStatusText(sessionState)?.let { currentStatus ->
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
                contentColor = BeidTheme.colors.labelOnActionPrimary,
                onClick = onOpenSettings,
                modifier = Modifier.testTag(EventJoinScreenTestTags.SUBMIT_BUTTON),
            )
        }
    }
}

/** iOS `listeningStrip`: a status dot, the listening label and the wait's `m:ss`, between hairlines. */
@Composable
private fun ListeningStrip(elapsedSeconds: Long) {
    Column(Modifier.fillMaxWidth().testTag(NowScreenTestTags.LISTENING)) {
        HorizontalDivider(color = BeidTheme.colors.strokeHairline)
        Row(
            modifier = Modifier.fillMaxWidth().padding(vertical = BeidSpacing.m),
            horizontalArrangement = Arrangement.spacedBy(BeidSpacing.s),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            NowStatusDot(BeidTheme.colors.textPrimary)
            NowStyledText(
                text = stringResource(R.string.now_listening),
                style = BeidFont.Library.labelMono10,
                color = BeidTheme.colors.textPrimary,
                modifier = Modifier.weight(1f),
            )
            NowStyledText(
                text = formatElapsed(elapsedSeconds),
                style = BeidFont.Library.labelMono10,
                color = BeidTheme.colors.textSecondary,
                modifier = Modifier.testTag(NowScreenTestTags.LISTENING_ELAPSED),
            )
        }
        HorizontalDivider(color = BeidTheme.colors.strokeHairline)
    }
}

/**
 * iOS `bluetoothOff` (integration/ios-1.1.1 `CollectionHomeView.swift` 244–264),
 * except its notice: DESIGN.md §5 "dots carry color, words carry meaning" puts
 * `statusOff` (under AA as text on the page ground) on a status dot before
 * the words, and the words in `textPrimary`.
 */
@Composable
private fun BluetoothOffBlock(onFix: () -> Unit, onOpenSettings: () -> Unit) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = BeidSpacing.m)
            .testTag(NowScreenTestTags.BLUETOOTH_OFF),
        verticalArrangement = Arrangement.spacedBy(BeidSpacing.s),
    ) {
        Row(
            horizontalArrangement = Arrangement.spacedBy(BeidSpacing.s),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            NowStatusDot(BeidTheme.colors.statusOff, Modifier.testTag(NowScreenTestTags.BLUETOOTH_OFF_DOT))
            NowStyledText(
                text = stringResource(R.string.now_bluetooth_off_label),
                style = BeidFont.Library.labelMono11,
                color = BeidTheme.colors.textPrimary,
            )
        }
        NowTextControl(
            label = stringResource(R.string.now_bluetooth_fix),
            accessibilityLabel = stringResource(R.string.now_bluetooth_fix_accessibility),
            trailingArrow = true,
            onClick = onFix,
            modifier = Modifier.testTag(NowScreenTestTags.BLUETOOTH_FIX),
        )
        NowInstructionTile(
            title = stringResource(R.string.now_bluetooth_off_tile_title),
            body = stringResource(R.string.now_bluetooth_off_tile_body),
        )
        NowTextControl(
            label = stringResource(R.string.now_open_settings),
            accessibilityLabel = stringResource(R.string.now_open_settings_accessibility),
            trailingArrow = true,
            onClick = onOpenSettings,
            modifier = Modifier.testTag(NowScreenTestTags.BLUETOOTH_OPEN_SETTINGS),
        )
    }
}

/**
 * A decorative status dot, `BeidStatusPill`'s size, placed as the pill places
 * it: first in a vertically centered row spaced by [BeidSpacing.s]. It carries
 * color only and the text beside it carries the meaning, so it has no
 * semantics of its own.
 */
@Composable
private fun NowStatusDot(color: Color, modifier: Modifier = Modifier) {
    Box(
        modifier
            .size(BeidSize.statusDot)
            .background(color, CircleShape)
            .clearAndSetSemantics {},
    )
}

/** iOS `instructionTile`: DO THIS NOW on a Flat 2b tile with the 12pt control radius. */
@Composable
internal fun NowInstructionTile(title: String, body: String) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(BeidTheme.colors.surfaceTile, RoundedCornerShape(BeidRadius.control))
            .padding(BeidSpacing.m)
            .semantics(mergeDescendants = true) {},
        verticalArrangement = Arrangement.spacedBy(BeidSpacing.s),
    ) {
        NowStyledText(
            text = stringResource(R.string.now_do_this_now),
            style = BeidFont.Library.labelMono10,
            color = BeidTheme.colors.textSecondary,
        )
        Text(title, style = BeidFont.Library.title17.textStyle, color = BeidTheme.colors.textPrimary)
        Text(body, style = BeidFont.Library.body13.textStyle, color = BeidTheme.colors.textSecondary)
    }
}

/**
 * iOS `BeidTextControl`: a monospaced uppercase text action, optionally with a
 * trailing "→" that is announced as [accessibilityLabel] instead of read out.
 * DESIGN.md: controls inside a screen are text, never icons.
 */
@Composable
internal fun NowTextControl(
    label: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    color: Color = BeidTheme.colors.textPrimary,
    disabledColor: Color = BeidTheme.colors.textSecondary,
    accessibilityLabel: String? = null,
    trailingArrow: Boolean = false,
    enabled: Boolean = true,
) {
    val text = if (trailingArrow) "$label →" else label
    Box(
        modifier = modifier
            .heightIn(min = BeidSpacing.xxl)
            .semantics(mergeDescendants = true) {
                if (accessibilityLabel != null) contentDescription = accessibilityLabel
            }
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick),
        contentAlignment = Alignment.CenterStart,
    ) {
        NowStyledText(
            text = text,
            style = BeidFont.Library.labelMono11,
            color = if (enabled) color else disabledColor,
            modifier = if (accessibilityLabel != null) Modifier.clearAndSetSemantics {} else Modifier,
        )
    }
}

/** A Library style with its case applied (Compose text styles cannot carry case). */
@Composable
internal fun NowStyledText(text: String, style: BeidTextStyle, color: Color, modifier: Modifier = Modifier) {
    Text(text = style.cased(text), style = style.textStyle, color = color, modifier = modifier)
}

/** iOS `elapsedString`: whole minutes and zero-padded seconds. */
internal fun formatElapsed(seconds: Long): String {
    val elapsed = maxOf(0L, seconds)
    return "%d:%02d".format(elapsed / 60, elapsed % 60)
}
