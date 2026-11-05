package org.levarac.beid.venue

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
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
import org.levarac.beid.ui.theme.BeidSpacing
import org.levarac.beid.ui.theme.BeidTheme

/** Pack-first surface. Both carriers feed the same link import; neither starts the radio. */
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
    Scaffold(containerColor = BeidTheme.colors.surfaceCanvas) { insets ->
        Column(
            modifier = Modifier.fillMaxSize().padding(insets)
                .verticalScroll(rememberScrollState()).padding(BeidSpacing.l),
            verticalArrangement = Arrangement.spacedBy(BeidSpacing.m),
        ) {
            Text(stringResource(R.string.venue_title), style = MaterialTheme.typography.headlineMedium)
            Card(
                Modifier.fillMaxWidth().testTag("venue-pack"),
                colors = CardDefaults.cardColors(containerColor = BeidTheme.colors.surfaceRaised),
            ) {
                Column(Modifier.padding(BeidSpacing.m), verticalArrangement = Arrangement.spacedBy(BeidSpacing.s)) {
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
                        HorizontalDivider()
                        Text(stringResource(R.string.venue_pending_pack), style = MaterialTheme.typography.titleSmall)
                        PackIdentity(pending)
                    }
                }
            }
            OutlinedTextField(
                value = link,
                onValueChange = { link = it },
                label = { Text(stringResource(R.string.venue_link_label)) },
                modifier = Modifier.fillMaxWidth().testTag("venue-link"),
                enabled = canUseInput,
                maxLines = 3,
            )
            state.linkEventIdHex?.let {
                Text(stringResource(R.string.venue_link_event, it.shortEventId()), modifier = Modifier.testTag("venue-link-event"))
            }
            if (state.isImporting) {
                Text(stringResource(if (state.importStage == VenueImportStage.GETTING) R.string.venue_getting else R.string.venue_checking))
            } else if (state.isStarting) {
                Text(stringResource(R.string.venue_waiting_bluetooth))
            }
            state.message?.let { Text(stringResource(it.text), modifier = Modifier.testTag("venue-message")) }
            Button(
                onClick = { scanUnavailable = false; controller.useLink(link) },
                enabled = link.isNotBlank() && canUseInput,
                modifier = Modifier.fillMaxWidth().testTag("venue-use-link"),
            ) { Text(stringResource(R.string.venue_use_link)) }
            OutlinedButton(
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
                enabled = canUseInput,
                modifier = Modifier.fillMaxWidth().testTag("venue-scan"),
            ) { Text(stringResource(if (isScanning) R.string.venue_scanning else R.string.venue_scan)) }
            if (scanUnavailable) Text(stringResource(R.string.venue_scan_unavailable))
            Row(horizontalArrangement = Arrangement.spacedBy(BeidSpacing.s)) {
                Button(
                    onClick = controller::start,
                    enabled = state.pack != null && canUseInput,
                    modifier = Modifier.weight(1f).testTag("venue-start"),
                ) { Text(stringResource(if (state.isBroadcasting) R.string.venue_refresh else R.string.venue_start)) }
                OutlinedButton(
                    onClick = controller::stop,
                    enabled = state.isBroadcasting || state.isStarting,
                    modifier = Modifier.weight(1f).testTag("venue-stop"),
                ) { Text(stringResource(R.string.venue_stop)) }
            }
        }
    }
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
