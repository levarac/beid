package org.levarac.beid.venue

import androidx.annotation.StringRes
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import org.levarac.beid.R

internal enum class VenueNotice(@get:StringRes val text: Int) {
    CHECKED(R.string.venue_checked),
    LINK_UNREADABLE(R.string.venue_link_unreadable),
    ADDRESS_MISSING(R.string.venue_address_missing),
    ADDRESS_UNSUPPORTED(R.string.venue_address_unsupported),
    FETCH_FAILED(R.string.venue_fetch_failed),
    LINK_PACK_MISMATCH(R.string.venue_link_pack_mismatch),
    VERIFICATION_FAILED(R.string.venue_verification_failed),
    NOT_STARTED(R.string.venue_not_started),
    EXPIRED(R.string.venue_expired),
    NO_CURRENT_PERIOD(R.string.venue_no_current_period),
    PERIOD_REJECTED(R.string.venue_period_rejected),
    EVENT_UPDATED(R.string.venue_event_updated),
    CLOCK_UNAVAILABLE(R.string.venue_clock_unavailable),
    RECORD_UNAVAILABLE(R.string.venue_record_unavailable),
    CANNOT_BROADCAST(R.string.venue_cannot_broadcast),
    BLUETOOTH_PERMISSION(R.string.venue_bluetooth_permission),
    RADIO_FAILED(R.string.venue_radio_failed),
    STOPPED(R.string.venue_stopped),
}

internal data class VenueUiState(
    // While a radio request is active, this remains the pack installed in that request.
    val pack: VenuePack? = null,
    val pendingPack: VenuePack? = null,
    val linkEventIdHex: String? = null,
    val importStage: VenueImportStage = VenueImportStage.CHECKING,
    val isImporting: Boolean = false,
    val isStarting: Boolean = false,
    // Means Barnard accepted a request, not confirmation that it is on air.
    val isBroadcasting: Boolean = false,
    val message: VenueNotice? = null,
)

/** Keeps input and import failures independent from the active radio request. */
internal class VenueController(
    private val importer: VenuePackImporter,
    private val radio: VenueRadio,
    private val scope: CoroutineScope,
) {
    private val mutableState = MutableStateFlow(VenueUiState())
    val state: StateFlow<VenueUiState> = mutableState.asStateFlow()
    private var importJob: Job? = null
    private var selectedLink: String? = null
    private var operation = 0L
    private var disposed = false

    fun useLink(link: String) {
        if (disposed) return
        val request = nextOperation()
        val input = link.trim()
        mutableState.value = mutableState.value.copy(
            isImporting = true, isStarting = false, linkEventIdHex = null, message = null,
            importStage = VenueImportStage.CHECKING,
        )
        importJob = scope.launch {
            val result = import(input, request)
            if (!isCurrent(request)) return@launch
            mutableState.value = when (result) {
                is VenueImportOutcome.Ready -> {
                    selectedLink = input
                    val current = mutableState.value
                    current.copy(
                        pack = if (current.isBroadcasting) current.pack else result.pack,
                        pendingPack = if (current.isBroadcasting) result.pack else null,
                        isImporting = false, message = VenueNotice.CHECKED,
                    )
                }
                else -> mutableState.value.copy(isImporting = false, message = result.notice())
            }
        }
    }

    fun start() {
        if (disposed || mutableState.value.isImporting || mutableState.value.isStarting) return
        val link = selectedLink ?: return
        val request = nextOperation()
        mutableState.value = mutableState.value.copy(isImporting = true, isStarting = true, message = null)
        importJob = scope.launch {
            // Use precisely the same import verification again: a previously checked lease can expire.
            val result = import(link, request)
            if (!isCurrent(request)) return@launch
            mutableState.value = mutableState.value.copy(isImporting = false)
            if (result !is VenueImportOutcome.Ready) {
                mutableState.value = mutableState.value.copy(isStarting = false, message = result.notice())
                return@launch
            }
            radio.requestPermission { granted ->
                if (!isCurrent(request) || !mutableState.value.isStarting) return@requestPermission
                mutableState.value = when {
                    !granted -> mutableState.value.copy(isStarting = false, message = VenueNotice.BLUETOOTH_PERMISSION)
                    radio.start(result.pack.container) -> mutableState.value.copy(
                        pack = result.pack, pendingPack = null, isStarting = false,
                        isBroadcasting = true, message = null,
                    )
                    else -> mutableState.value.copy(
                        isStarting = false, isBroadcasting = false, message = VenueNotice.RADIO_FAILED,
                    )
                }
            }
        }
    }

    fun stop() {
        if (disposed) return
        nextOperation()
        radio.stop()
        mutableState.value = mutableState.value.copy(
            isImporting = false, isStarting = false, isBroadcasting = false, message = VenueNotice.STOPPED,
        )
    }

    fun dispose() {
        if (disposed) return
        disposed = true
        nextOperation()
        radio.stop()
        radio.dispose()
    }

    private fun nextOperation(): Long {
        operation++
        importJob?.cancel()
        return operation
    }

    private fun isCurrent(request: Long): Boolean = !disposed && operation == request

    private suspend fun import(link: String, request: Long): VenueImportOutcome = importer.import(link) { progress ->
        if (isCurrent(request)) mutableState.value = mutableState.value.copy(
            linkEventIdHex = progress.eventIdHex, importStage = progress.stage,
        )
    }
}

private fun VenueImportOutcome.notice(): VenueNotice = when (this) {
    VenueImportOutcome.LinkUnreadable -> VenueNotice.LINK_UNREADABLE
    VenueImportOutcome.BundleAddressMissing -> VenueNotice.ADDRESS_MISSING
    VenueImportOutcome.BundleAddressUnsupported -> VenueNotice.ADDRESS_UNSUPPORTED
    VenueImportOutcome.FetchFailed -> VenueNotice.FETCH_FAILED
    VenueImportOutcome.LinkPackMismatch -> VenueNotice.LINK_PACK_MISMATCH
    VenueImportOutcome.VerificationFailed -> VenueNotice.VERIFICATION_FAILED
    is VenueImportOutcome.NotReady -> when (reason) {
        "notStarted" -> VenueNotice.NOT_STARTED
        "expired" -> VenueNotice.EXPIRED
        "noCurrentEnvelope" -> VenueNotice.NO_CURRENT_PERIOD
        "envelopeRejected" -> VenueNotice.PERIOD_REJECTED
        "staleDefinition" -> VenueNotice.EVENT_UPDATED
        "clockUnavailable" -> VenueNotice.CLOCK_UNAVAILABLE
        "registryUnavailable" -> VenueNotice.RECORD_UNAVAILABLE
        else -> VenueNotice.CANNOT_BROADCAST
    }
    is VenueImportOutcome.Ready -> VenueNotice.CHECKED
}
