package org.levarac.beid.venue

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import java.util.Base64
import kotlinx.coroutines.CompletableDeferred
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
class VenueLinkScreenTest {
    @get:Rule val compose = createComposeRule()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val radio = VenueTestRadio()
    @After fun close() { scope.cancel() }

    private fun show(importer: VenuePackImporter = VenuePackImporter { VenueImportOutcome.Ready(venueTestPack()) }): VenueController {
        val controller = VenueController(importer, radio, scope)
        compose.setContent { BeidAppTheme { VenueScreen(controller) } }
        return controller
    }

    private fun paste(link: String = "https://venue.example/#test") {
        compose.onNodeWithTag("venue-link").performTextInput(link)
        compose.onNodeWithTag("venue-use-link").performClick()
        compose.waitForIdle()
    }

    @Test fun emptyPackExplainsBothInputsAndShowsQrBeforeAnyPermission() {
        show()
        compose.onNodeWithText("No pack yet. Paste the link the organiser gave you, or scan its QR code.").assertIsDisplayed()
        compose.onNodeWithTag("venue-scan").assertIsDisplayed().assertIsEnabled()
        compose.onNodeWithTag("venue-start").assertIsNotEnabled()
    }

    @Test fun unavailableQrExplainsThePasteAlternative() {
        show()
        compose.onNodeWithTag("venue-scan").performClick()
        compose.onNodeWithText("QR scanning is not available in this build. Paste the link instead.").assertIsDisplayed()
    }

    @Test fun importedPackShowsIdentityPeriodAndExplicitStart() {
        show()
        paste()
        compose.onNodeWithText("Example Event").assertIsDisplayed()
        compose.onNodeWithText("0303030303030303…").assertIsDisplayed()
        compose.onNodeWithText("Valid", substring = true).assertIsDisplayed()
        compose.onNodeWithText("Pack checked. Start broadcasting when ready.").assertIsDisplayed()
        compose.onNodeWithText("Start broadcasting").assertIsDisplayed()
        kotlin.test.assertEquals(0, radio.starts)
    }

    @Test fun startRefreshAndStopDescribeThePackWithoutClaimingOnAirProof() {
        show()
        paste()
        compose.onNodeWithTag("venue-start").performClick()
        compose.waitForIdle()
        compose.onNodeWithText("Asked to broadcast").assertIsDisplayed()
        compose.onNodeWithText("The system has not confirmed it is on air.").assertIsDisplayed()
        compose.onNodeWithText("Refresh pack").assertIsDisplayed().assertIsEnabled()
        compose.onNodeWithTag("venue-stop").performClick()
        compose.onNodeWithText("Broadcast stopped.").assertIsDisplayed()
        compose.onNodeWithText("Example Event").assertIsDisplayed()
    }

    @Test fun decodedEventIsVisibleBeforeFetchingWithoutInventingAName() {
        val fetch = CompletableDeferred<ByteArray?>()
        show(SharedVenuePackImporter(null, VenueBundleAcquirer { fetch.await() }))
        val handoff = requireNotNull(javaClass.getResourceAsStream("/full-schedule.venue-handoff.hex"))
            .use { it.readBytes().decodeToString().trim().chunked(2).map { it.toInt(16).toByte() }.toByteArray() }
        paste("https://venue.example/#" + Base64.getUrlEncoder().withoutPadding().encodeToString(handoff))
        compose.onNodeWithText("Link event: 996ab4d7cd078519…").assertIsDisplayed()
        compose.onNodeWithText("Getting the pack.").assertIsDisplayed()
        compose.onNodeWithText("Example Event").assertDoesNotExist()
        compose.onNodeWithTag("venue-start").assertIsNotEnabled()
        kotlin.test.assertEquals(0, radio.starts)
    }

    @Test fun malformedLinkHasActionableCopy() {
        show(SharedVenuePackImporter(null, VenueBundleAcquirer { error("must not fetch") }))
        paste("not a link")
        compose.onNodeWithText("That is not a venue link. Paste the whole link, including everything after the #.").assertIsDisplayed()
    }

    @Test fun digestMismatchIsDistinctFromUnreadableLinkAndKeepsRadio() {
        var result: VenueImportOutcome = VenueImportOutcome.Ready(venueTestPack())
        val controller = show(VenuePackImporter { result })
        paste()
        compose.onNodeWithTag("venue-start").performClick()
        compose.waitForIdle()
        result = VenueImportOutcome.LinkPackMismatch
        compose.runOnIdle { controller.useLink("https://venue.example/#changed") }
        compose.onNodeWithText("The link and the pack do not agree. Ask the organiser for a current link.").assertIsDisplayed()
        compose.onNodeWithText("Asked to broadcast").assertIsDisplayed()
        kotlin.test.assertEquals(0, radio.stops)
    }

    @Test fun blockedPackUsesEverydayCopyInsteadOfInternalReason() {
        show(VenuePackImporter { VenueImportOutcome.NotReady("notStarted") })
        paste()
        compose.onNodeWithText("This event has not started yet.").assertIsDisplayed()
        compose.onNodeWithTag("venue-start").assertIsNotEnabled()
    }

    @Test fun missingPackAddressAndInsecureAddressHaveDifferentExplanations() {
        var result: VenueImportOutcome = VenueImportOutcome.BundleAddressMissing
        val controller = show(VenuePackImporter { result })
        paste()
        compose.onNodeWithText("This link names an event but does not say where to get its pack.").assertIsDisplayed()
        result = VenueImportOutcome.BundleAddressUnsupported
        compose.runOnIdle { controller.useLink("another link") }
        compose.onNodeWithText("The pack must use a secure HTTPS address.").assertIsDisplayed()
    }

    @Test fun rejectedPackCannotBeStarted() {
        show(VenuePackImporter { VenueImportOutcome.VerificationFailed })
        paste()
        compose.onNodeWithText("The pack could not be verified.").assertIsDisplayed()
        compose.onNodeWithTag("venue-start").assertIsNotEnabled()
        kotlin.test.assertEquals(0, radio.starts)
    }
}

internal fun venueTestPack() = VenuePack("03".repeat(32), "Example Event", 1_790_294_400, 1_790_467_200, byteArrayOf(3), 1_790_294_700)

internal class VenueTestRadio : VenueRadio {
    var starts = 0
    var stops = 0
    var permission: ((Boolean) -> Unit)? = null
    var deferPermission = false
    var startResult = true
    val containers = mutableListOf<ByteArray>()
    override fun requestPermission(completion: (Boolean) -> Unit) {
        if (deferPermission) permission = completion else completion(true)
    }
    override fun start(container: ByteArray): Boolean { starts++; containers += container; return startResult }
    override fun stop() { stops++ }
    override fun forwardPermissionResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) = false
    override fun dispose() = Unit
}
