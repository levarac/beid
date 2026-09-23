package org.levarac.beid.venue

import java.util.Base64
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals

class SharedVenuePackImporterTest {
    private val importer = SharedVenuePackImporter(registryClient = null, acquirer = VenueBundleAcquirer { error("must not fetch") })

    @Test
    fun malformedFragmentIsRejectedBySharedLinkDecoder() = runTest {
        assertEquals(VenueImportOutcome.LinkUnreadable, importer.import("https://venue.example/#%%%"))
    }

    @Test
    fun handoffWithoutBundleAddressIsDistinct() = runTest {
        assertEquals(VenueImportOutcome.BundleAddressMissing, importer.import("https://venue.example/#$NO_URL_HANDOFF"))
    }

    @Test
    fun fileBundleAddressIsRejectedBeforeAnyRead() = runTest {
        val original = Base64.getUrlDecoder().decode(NO_URL_HANDOFF)
        val fileUrl = "file:///tmp"
        val withUrl = byteArrayOf(0xa7.toByte()) + original.drop(1) +
            byteArrayOf(7, (0x60 + fileUrl.length).toByte()) + fileUrl.encodeToByteArray()
        val fragment = Base64.getUrlEncoder().withoutPadding().encodeToString(withUrl)
        assertEquals(
            VenueImportOutcome.BundleAddressUnsupported,
            importer.import("https://venue.example/#$fragment"),
        )
    }

    private companion object {
        const val NO_URL_HANDOFF = "pgEBAlggAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAQRUAQEBAQEBAQEBAQEBAQEBAQEBAQEFVAICAgICAgICAgICAgICAgICAgICBlggBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwc"
    }
}
