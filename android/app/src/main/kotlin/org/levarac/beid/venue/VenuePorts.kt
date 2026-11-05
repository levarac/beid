package org.levarac.beid.venue

import android.app.Activity
import org.levarac.barnard.BarnardEngine
import org.levarac.barnard.BarnardPermissionResult

internal data class VenuePack(
    val eventIdHex: String,
    val displayName: String,
    val validFromUnixSeconds: Long,
    val validUntilUnixSeconds: Long,
    val container: ByteArray,
    val stopAtUnixSeconds: Long,
)

internal sealed interface VenueImportOutcome {
    data class Ready(val pack: VenuePack) : VenueImportOutcome
    data object LinkUnreadable : VenueImportOutcome
    data object BundleAddressMissing : VenueImportOutcome
    data object BundleAddressUnsupported : VenueImportOutcome
    data object FetchFailed : VenueImportOutcome
    data object LinkPackMismatch : VenueImportOutcome
    data object VerificationFailed : VenueImportOutcome
    data class NotReady(val reason: String) : VenueImportOutcome
}

internal enum class VenueImportStage { GETTING, CHECKING }

/** Presentation progress only; the event named by a link is not a verified pack. */
internal data class VenueImportProgress(val eventIdHex: String, val stage: VenueImportStage)

internal fun interface VenuePackImporter {
    suspend fun import(link: String): VenueImportOutcome

    suspend fun import(link: String, onProgress: (VenueImportProgress) -> Unit): VenueImportOutcome = import(link)
}

internal interface VenueRadio {
    fun requestPermission(completion: (Boolean) -> Unit)
    fun start(container: ByteArray): Boolean
    fun stop()
    fun forwardPermissionResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray): Boolean
    fun dispose()
}

/** A venue-only engine. It never shares participant engine state. */
internal class BarnardVenueRadio(activity: Activity) : VenueRadio {
    private val engine = BarnardEngine(activity.applicationContext).apply { setActivity(activity) }

    override fun requestPermission(completion: (Boolean) -> Unit) {
        engine.requestPermissions { completion(it is BarnardPermissionResult.Granted) }
    }

    override fun start(container: ByteArray): Boolean = runCatching {
        // Clear first: Barnard deliberately retains an older value if replacement fails.
        engine.configureOwnEventInfoEnvelopeV2(null)
        engine.configureOwnEventInfoEnvelopeV2(container)
        engine.startAdvertise()
    }.isSuccess

    override fun stop() {
        engine.configureOwnEventInfoEnvelopeV2(null)
        engine.stopAdvertise()
    }

    override fun forwardPermissionResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean = engine.onRequestPermissionsResult(requestCode, permissions, grantResults)

    override fun dispose() = engine.dispose()
}
