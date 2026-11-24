package org.levarac.beid.venue

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import java.util.Base64
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import org.junit.After
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.levarac.beid.ui.theme.BeidAppTheme
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], qualifiers = "w412dp-h1000dp-mdpi")
class VenueQrLinkScannerTest {
    @get:Rule val compose = createComposeRule()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    @After fun close() { scope.cancel() }

    @Test fun scannedLinkUsesTheSameSharedDecodeAndAcquisitionPathAsPaste() {
        val handoff = requireNotNull(javaClass.getResourceAsStream("/full-schedule.venue-handoff.hex"))
            .use { it.readBytes().decodeToString().trim().chunked(2).map { it.toInt(16).toByte() }.toByteArray() }
        val link = "https://venue.example/#" + Base64.getUrlEncoder().withoutPadding().encodeToString(handoff)
        val fetched = mutableListOf<String>()
        val radio = VenueTestRadio()
        val controller = VenueController(SharedVenuePackImporter(null, VenueBundleAcquirer { fetched += it; null }), radio, scope)
        val scanner = FakeQrScanner(VenueQrScanResult.Link(link))
        compose.setContent { BeidAppTheme { VenueScreen(controller, scanner) } }
        compose.onNodeWithTag("venue-scan").performClick()
        compose.onNodeWithText("The pack could not be downloaded. Try again.").assertIsDisplayed()
        kotlin.test.assertEquals(1, scanner.calls)
        kotlin.test.assertEquals(listOf(org.levarac.parallax.venue.decodeVenueHandoffLink(link)!!.bundleUrl), fetched)
        kotlin.test.assertEquals(0, radio.starts)
    }

    @Test fun malformedScannedLinkShowsTheSameInputRefusalWithoutFetching() {
        val controller = VenueController(SharedVenuePackImporter(null, VenueBundleAcquirer { error("must not fetch") }), VenueTestRadio(), scope)
        compose.setContent { BeidAppTheme { VenueScreen(controller, FakeQrScanner(VenueQrScanResult.Link("broken"))) } }
        compose.onNodeWithTag("venue-scan").performClick()
        compose.onNodeWithText("That is not a venue link. Paste the whole link, including everything after the #.").assertIsDisplayed()
    }

    @Test fun cancellingScannerDoesNotImportOrTouchTheRadio() {
        val radio = VenueTestRadio()
        val controller = VenueController(VenuePackImporter { error("must not import") }, radio, scope)
        compose.setContent { BeidAppTheme { VenueScreen(controller, FakeQrScanner(VenueQrScanResult.Cancelled)) } }
        compose.onNodeWithTag("venue-scan").performClick()
        compose.waitForIdle()
        kotlin.test.assertEquals(0, radio.starts)
        kotlin.test.assertEquals(0, radio.stops)
        kotlin.test.assertNull(controller.state.value.pack)
    }

    private class FakeQrScanner(private val result: VenueQrScanResult) : VenueQrLinkScanner {
        var calls = 0
        override suspend fun scan(): VenueQrScanResult { calls++; return result }
    }
}
