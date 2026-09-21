package org.levarac.beid.venue

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

internal data class VenueUiState(
    val pack: VenuePack? = null,
    val isImporting: Boolean = false,
    val isBroadcasting: Boolean = false,
    val message: String? = null,
)

/** Keeps link-input failures independent from the active radio lease. */
internal class VenueController(
    private val importer: VenuePackImporter,
    private val radio: VenueRadio,
    private val scope: CoroutineScope,
) {
    private val mutableState = MutableStateFlow(VenueUiState())
    val state: StateFlow<VenueUiState> = mutableState.asStateFlow()
    private var importJob: Job? = null

    fun useLink(link: String) {
        importJob?.cancel()
        mutableState.value = mutableState.value.copy(isImporting = true, message = null)
        importJob = scope.launch {
            when (val result = importer.import(link.trim())) {
                is VenueImportOutcome.Ready -> mutableState.value = mutableState.value.copy(
                    pack = result.pack,
                    isImporting = false,
                    message = "Pack checked. Start broadcasting when ready.",
                )
                else -> mutableState.value = mutableState.value.copy(
                    isImporting = false,
                    // Deliberately do not call radio.stop() or replace the currently served pack.
                    message = result.operatorMessage(),
                )
            }
        }
    }

    fun start() {
        val pack = mutableState.value.pack ?: return
        radio.requestPermission { granted ->
            mutableState.value = if (!granted) {
                mutableState.value.copy(message = "Bluetooth permission is needed to broadcast.")
            } else if (radio.start(pack.container)) {
                mutableState.value.copy(isBroadcasting = true, message = "Broadcasting this event.")
            } else {
                mutableState.value.copy(isBroadcasting = false, message = "The radio could not start.")
            }
        }
    }

    fun stop() {
        radio.stop()
        mutableState.value = mutableState.value.copy(isBroadcasting = false, message = "Broadcast stopped.")
    }

    fun dispose() {
        importJob?.cancel()
        radio.stop()
        radio.dispose()
    }
}

private fun VenueImportOutcome.operatorMessage(): String = when (this) {
    VenueImportOutcome.LinkUnreadable -> "That link cannot be read."
    VenueImportOutcome.BundleAddressMissing -> "That link does not name a pack."
    VenueImportOutcome.BundleAddressUnsupported -> "The pack must use a secure https address."
    VenueImportOutcome.FetchFailed -> "The pack could not be downloaded. Try again."
    VenueImportOutcome.LinkPackMismatch -> "The link and pack do not match."
    VenueImportOutcome.VerificationFailed -> "The pack could not be verified."
    is VenueImportOutcome.NotReady -> "This pack cannot broadcast now: $reason."
    is VenueImportOutcome.Ready -> error("ready is handled before message mapping")
}
