package org.levarac.beid.venue

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch
import org.levarac.beid.R
import org.levarac.beid.ui.designsystem.BeidPanel
import org.levarac.beid.ui.designsystem.BeidPrimaryButton
import org.levarac.beid.ui.designsystem.BeidScreen
import org.levarac.beid.ui.designsystem.BeidSecondaryButton
import org.levarac.beid.ui.designsystem.BeidTextField
import org.levarac.beid.ui.theme.BeidFont
import org.levarac.beid.ui.theme.BeidSpacing
import org.levarac.beid.ui.theme.BeidTheme

/**
 * Pack-first surface. Both carriers feed the same link import; neither starts the radio.
 *
 * Layout follows iOS `VenueSignedServingView` on Beid components: a scrolling body
 * (eyebrow, title, subtitle, pack panel, link field and its actions) above a pinned
 * footer whose only filled CTA is Start broadcasting / Refresh pack, with Stop under it.
 *
 * Deliberate divergence from iOS draft PR #824, which makes Scan QR code the filled
 * primary at the top: on Android it must not be the primary while Android has no
 * scanner (production passes [UnavailableVenueQrLinkScanner]), so here it is a
 * secondary after Use this link (PM decision, 2026-11-19). [UseLinkButton] and
 * [ScanButton] are separate composables so adopting #824's order once a scanner ships
 * is a reorder, not a rewrite.
 */
@Composable
internal fun VenueScreen(
    controller: VenueController,
    scanner: VenueQrLinkScanner = UnavailableVenueQrLinkScanner,
) {
    val state by controller.state.collectAsStateWithLifecycle()
    var link by remember { mutableStateOf("") }
    var isScanning by remember { mutableStateOf(false) }
    var scanUnavailable by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    val canUseInput = !state.isImporting && !state.isStarting && !isScanning
    BeidScreen(
        footer = {
            Column(
                modifier = Modifier.padding(bottom = BeidSpacing.l),
                verticalArrangement = Arrangement.spacedBy(BeidSpacing.s),
            ) {
                BeidPrimaryButton(
                    text = stringResource(if (state.isBroadcasting) R.string.venue_refresh else R.string.venue_start),
                    containerColor = BeidTheme.colors.actionPrimary,
                    contentColor = BeidTheme.colors.labelOnActionPrimary,
                    onClick = controller::start,
                    enabled = state.pack != null && canUseInput,
                    modifier = Modifier.testTag("venue-start"),
                )
                BeidSecondaryButton(
                    text = stringResource(R.string.venue_stop),
                    contentColor = BeidTheme.colors.textPrimary,
                    borderColor = BeidTheme.colors.strokeHairline,
                    onClick = controller::stop,
                    enabled = state.isBroadcasting || state.isStarting,
                    modifier = Modifier.testTag("venue-stop"),
                )
            }
        },
    ) {
        Column(
            modifier = Modifier.weight(1f).fillMaxWidth()
                .verticalScroll(rememberScrollState()).padding(top = BeidSpacing.l),
            verticalArrangement = Arrangement.spacedBy(BeidSpacing.m),
        ) {
            Column {
                Text(
                    BeidFont.Library.labelMono10.cased(stringResource(R.string.venue_eyebrow)),
                    style = BeidFont.Library.labelMono10.textStyle,
                    color = BeidTheme.colors.textSecondary,
                    modifier = Modifier.padding(bottom = BeidSpacing.s),
                )
                Text(
                    stringResource(R.string.venue_title),
                    style = MaterialTheme.typography.headlineMedium,
                    color = BeidTheme.colors.textPrimary,
                )
                Text(
                    stringResource(R.string.venue_subtitle),
                    style = BeidFont.Library.body15.textStyle,
                    color = BeidTheme.colors.textSecondary,
                    modifier = Modifier.padding(top = BeidSpacing.m),
                )
            }
            BeidPanel(Modifier.testTag("venue-pack")) {
                Column(verticalArrangement = Arrangement.spacedBy(BeidSpacing.s)) {
                    Text(stringResource(R.string.venue_current_pack), style = MaterialTheme.typography.titleMedium)
                    val pack = state.pack
                    if (pack == null) {
                        Text(stringResource(R.string.venue_no_pack))
                    } else {
                        PackIdentity(pack)
                        Text(stringResource(if (state.isBroadcasting) R.string.venue_requested else R.string.venue_ready))
                        if (state.isBroadcasting) {
                            Text(stringResource(R.string.venue_requested_until, pack.stopAtUnixSeconds.asTime()))
                            Text(stringResource(R.string.venue_radio_unconfirmed), style = MaterialTheme.typography.bodySmall)
                        }
                    }
                    state.pendingPack?.let { pending ->
                        HorizontalDivider(color = BeidTheme.colors.strokeHairline)
                        Text(stringResource(R.string.venue_pending_pack), style = MaterialTheme.typography.titleSmall)
                        PackIdentity(pending)
                    }
                }
            }
            Column(verticalArrangement = Arrangement.spacedBy(BeidSpacing.s)) {
                // BeidTextField has a placeholder slot only; its persistent label is a
                // caption above it, as iOS's "Link" caption sits above its field.
                Text(
                    BeidFont.Library.labelMono10.cased(stringResource(R.string.venue_link_label)),
                    style = BeidFont.Library.labelMono10.textStyle,
                    color = BeidTheme.colors.textSecondary,
                )
                BeidTextField(
                    value = link,
                    onValueChange = { link = it },
                    placeholder = "",
                    isError = false,
                    enabled = canUseInput,
                    modifier = Modifier.testTag("venue-link"),
                )
            }
            state.linkEventIdHex?.let {
                Text(stringResource(R.string.venue_link_event, it.shortEventId()), modifier = Modifier.testTag("venue-link-event"))
            }
            if (state.isImporting) {
                Text(stringResource(if (state.importStage == VenueImportStage.GETTING) R.string.venue_getting else R.string.venue_checking))
            } else if (state.isStarting) {
                Text(stringResource(R.string.venue_waiting_bluetooth))
            }
            state.message?.let { Text(stringResource(it.text), modifier = Modifier.testTag("venue-message")) }
            UseLinkButton(
                enabled = link.isNotBlank() && canUseInput,
                onClick = { scanUnavailable = false; controller.useLink(link) },
            )
            ScanButton(
                isScanning = isScanning,
                enabled = canUseInput,
                onClick = {
                    isScanning = true
                    scanUnavailable = false
                    scope.launch {
                        try {
                            when (val result = scanner.scan()) {
                                is VenueQrScanResult.Link -> {
                                    link = result.value
                                    controller.useLink(result.value)
                                }
                                VenueQrScanResult.Cancelled -> Unit
                                VenueQrScanResult.Unavailable -> scanUnavailable = true
                            }
                        } catch (cancelled: CancellationException) {
                            throw cancelled
                        } catch (_: Exception) {
                            scanUnavailable = true
                        } finally {
                            isScanning = false
                        }
                    }
                },
            )
            if (scanUnavailable) Text(stringResource(R.string.venue_scan_unavailable))
        }
    }
}

@Composable
private fun UseLinkButton(enabled: Boolean, onClick: () -> Unit) {
    BeidSecondaryButton(
        text = stringResource(R.string.venue_use_link),
        contentColor = BeidTheme.colors.textPrimary,
        borderColor = BeidTheme.colors.strokeHairline,
        onClick = onClick,
        enabled = enabled,
        modifier = Modifier.testTag("venue-use-link"),
    )
}

@Composable
private fun ScanButton(isScanning: Boolean, enabled: Boolean, onClick: () -> Unit) {
    BeidSecondaryButton(
        text = stringResource(if (isScanning) R.string.venue_scanning else R.string.venue_scan),
        contentColor = BeidTheme.colors.textPrimary,
        borderColor = BeidTheme.colors.strokeHairline,
        onClick = onClick,
        enabled = enabled,
        modifier = Modifier.testTag("venue-scan"),
    )
}

@Composable
private fun PackIdentity(pack: VenuePack) {
    if (pack.displayName.isNotBlank()) Text(pack.displayName, style = MaterialTheme.typography.titleLarge)
    Text(pack.eventIdHex.shortEventId())
    Text(stringResource(R.string.venue_valid, pack.validFromUnixSeconds.asTime(), pack.validUntilUnixSeconds.asTime()))
}

private fun String.shortEventId(): String = take(16) + "…"

private val venueTimeFormatter = DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm")
    .withZone(ZoneId.systemDefault())

private fun Long.asTime(): String = venueTimeFormatter.format(Instant.ofEpochSecond(this))
