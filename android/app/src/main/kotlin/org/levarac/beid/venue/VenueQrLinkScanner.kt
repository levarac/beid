package org.levarac.beid.venue

/** Camera/QR integration boundary. A scanner returns the original link, never decoded pack data. */
internal fun interface VenueQrLinkScanner {
    suspend fun scan(): VenueQrScanResult
}

internal sealed interface VenueQrScanResult {
    data class Link(val value: String) : VenueQrScanResult
    data object Cancelled : VenueQrScanResult
    data object Unavailable : VenueQrScanResult
}

/** No QR dependency is selected for this build. Never requests camera permission. */
internal object UnavailableVenueQrLinkScanner : VenueQrLinkScanner {
    override suspend fun scan(): VenueQrScanResult = VenueQrScanResult.Unavailable
}
