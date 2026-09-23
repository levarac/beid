package org.levarac.beid.venue

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter

/** Pack-first operator surface. This build accepts a pasted venue link only. */
@Composable
internal fun VenueScreen(controller: VenueController) {
    val state by controller.state.collectAsStateWithLifecycle()
    var link by remember { mutableStateOf("") }
    Column(
        modifier = Modifier.fillMaxSize().padding(24.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Text("Venue broadcast", style = MaterialTheme.typography.headlineMedium)
        Card(Modifier.fillMaxWidth().testTag("venue-pack")) {
            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text("This event", style = MaterialTheme.typography.titleMedium)
                val pack = state.pack
                if (pack == null) {
                    Text("Paste the venue link to import its pack.")
                } else {
                    Text(pack.displayName, style = MaterialTheme.typography.titleLarge)
                    Text(pack.eventIdHex.take(16) + "…")
                    Text("Valid ${pack.validFromUnixSeconds.asTime()} – ${pack.validUntilUnixSeconds.asTime()}")
                    Text(if (state.isBroadcasting) "Broadcasting" else "Ready")
                }
            }
        }
        OutlinedTextField(
            value = link,
            onValueChange = { link = it },
            label = { Text("Venue link") },
            modifier = Modifier.fillMaxWidth().testTag("venue-link"),
            enabled = !state.isImporting,
        )
        Button(
            onClick = { controller.useLink(link) },
            enabled = link.isNotBlank() && !state.isImporting,
            modifier = Modifier.testTag("venue-use-link"),
        ) { Text(if (state.isImporting) "Checking…" else "Use this link") }
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Button(
                onClick = controller::start,
                enabled = state.pack != null && !state.isBroadcasting,
                modifier = Modifier.testTag("venue-start"),
            ) { Text("Start or refresh") }
            Button(
                onClick = controller::stop,
                enabled = state.isBroadcasting,
                modifier = Modifier.testTag("venue-stop"),
            ) { Text("Stop") }
        }
        state.message?.let { Text(it, modifier = Modifier.testTag("venue-message")) }
    }
}

private val venueTimeFormatter = DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm")
    .withZone(ZoneId.systemDefault())

private fun Long.asTime(): String = venueTimeFormatter.format(Instant.ofEpochSecond(this))
