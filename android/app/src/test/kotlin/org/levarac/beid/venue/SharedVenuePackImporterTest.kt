package org.levarac.beid.venue

import java.util.Base64
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import org.levarac.parallax.venue.decodeVenueHandoffLink
import org.levarac.parallax.venue.decodeVenueHandoffLinkBytes

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

    @Test
    fun unsupportedSchemesNeverReachAcquisition() = runTest {
        for (url in listOf("http://venue.test/pack", "file:///pack", "ftp://venue.test/pack", "content://venue/pack")) {
            assertEquals(VenueImportOutcome.BundleAddressUnsupported, importer.import(linkWithUrl(url)), url)
        }
    }

    @Test
    fun acceptedFragmentUsesTheSharedEntryAndFetchesOnlyItsBundleUrl() = runTest {
        val url = "https://venue.test/pack"
        val link = linkWithUrl(url)
        kotlin.test.assertNotNull(decodeVenueHandoffLinkBytes(link))
        assertEquals(url, decodeVenueHandoffLink(link)?.bundleUrl)
        val fetched = mutableListOf<String>()
        val subject = SharedVenuePackImporter(null, VenueBundleAcquirer { fetched += it; null })
        assertEquals(VenueImportOutcome.FetchFailed, subject.import(link))
        assertEquals(listOf(url), fetched)
    }

    private fun linkWithUrl(url: String): String {
        val original = Base64.getUrlDecoder().decode(NO_URL_HANDOFF)
        val text = url.encodeToByteArray()
        val length = if (text.size < 24) byteArrayOf((0x60 + text.size).toByte())
            else byteArrayOf(0x78, text.size.toByte())
        val handoff = byteArrayOf(0xa7.toByte()) + original.drop(1) + byteArrayOf(7) + length + text
        return "https://venue.test/#" + Base64.getUrlEncoder().withoutPadding().encodeToString(handoff)
    }

    private companion object {
        const val NO_URL_HANDOFF = "pgEBAlggAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAQRUAQEBAQEBAQEBAQEBAQEBAQEBAQEFVAICAgICAgICAgICAgICAgICAgICBlggBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwc"
    }
}
