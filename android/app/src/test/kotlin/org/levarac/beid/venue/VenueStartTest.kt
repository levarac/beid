package org.levarac.beid.venue

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.runCurrent
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

@OptIn(ExperimentalCoroutinesApi::class)
class VenueStartTest {
    @Test fun stopPromotesThePendingPackBeforeTheNextStart() = runTest {
        val first = venueTestPack()
        val second = first.copy(
            eventIdHex = "04".repeat(32), displayName = "Next Event", container = byteArrayOf(4),
            validFromUnixSeconds = first.validFromUnixSeconds + 86_400,
            validUntilUnixSeconds = first.validUntilUnixSeconds + 86_400,
            stopAtUnixSeconds = first.stopAtUnixSeconds + 86_400,
        )
        val imports = mutableListOf<String>()
        val radio = VenueTestRadio()
        val controller = VenueController(VenuePackImporter { link ->
            imports += link
            VenueImportOutcome.Ready(if (link == "first") first else second)
        }, radio, this)
        controller.useLink("first")
        runCurrent()
        controller.start()
        runCurrent()
        controller.useLink("second")
        runCurrent()
        assertTrue(controller.state.value.isBroadcasting)
        assertEquals(first, controller.state.value.pack)
        assertEquals(second, controller.state.value.pendingPack)
        assertEquals(listOf(first.container), radio.containers)
        assertEquals(0, radio.stops)

        controller.stop()

        assertFalse(controller.state.value.isBroadcasting)
        assertEquals(second, controller.state.value.pack)
        assertNull(controller.state.value.pendingPack)
        assertEquals(VenueNotice.STOPPED, controller.state.value.message)
        assertEquals(1, radio.stops)
        controller.start()
        runCurrent()
        assertEquals(listOf("first", "first", "second", "second"), imports)
        assertEquals(listOf(first.container, second.container), radio.containers)
        assertEquals(second, controller.state.value.pack)
        assertTrue(controller.state.value.isBroadcasting)
    }

    @Test fun stopWithoutAPendingPackKeepsTheCurrentPackForTheNextStart() = runTest {
        val first = venueTestPack()
        val imports = mutableListOf<String>()
        val radio = VenueTestRadio()
        val controller = VenueController(VenuePackImporter { link ->
            imports += link
            VenueImportOutcome.Ready(first)
        }, radio, this)
        controller.useLink("first")
        runCurrent()
        controller.start()
        runCurrent()

        controller.stop()

        assertFalse(controller.state.value.isBroadcasting)
        assertEquals(first, controller.state.value.pack)
        assertNull(controller.state.value.pendingPack)
        controller.start()
        runCurrent()
        assertEquals(listOf("first", "first", "first"), imports)
        assertEquals(listOf(first.container, first.container), radio.containers)
        assertTrue(controller.state.value.isBroadcasting)
    }

    @Test fun stopDoesNotPromoteAPackWhoseImportFailed() = runTest {
        val first = venueTestPack()
        val imports = mutableListOf<String>()
        val radio = VenueTestRadio()
        val controller = VenueController(VenuePackImporter { link ->
            imports += link
            if (link == "first") VenueImportOutcome.Ready(first) else VenueImportOutcome.VerificationFailed
        }, radio, this)
        controller.useLink("first")
        runCurrent()
        controller.start()
        runCurrent()
        controller.useLink("rejected")
        runCurrent()
        assertTrue(controller.state.value.isBroadcasting)
        assertEquals(VenueNotice.VERIFICATION_FAILED, controller.state.value.message)
        assertNull(controller.state.value.pendingPack)
        assertEquals(0, radio.stops)

        controller.stop()

        assertFalse(controller.state.value.isBroadcasting)
        assertEquals(first, controller.state.value.pack)
        assertNull(controller.state.value.pendingPack)
        controller.start()
        runCurrent()
        assertEquals(listOf("first", "first", "rejected", "first"), imports)
        assertEquals(listOf(first.container, first.container), radio.containers)
        assertTrue(controller.state.value.isBroadcasting)
    }

    @Test fun startChecksTheImportedLinkAgainBeforeRequestingRadio() = runTest {
        var imports = 0
        var result: VenueImportOutcome = VenueImportOutcome.Ready(venueTestPack())
        val radio = VenueTestRadio()
        val controller = VenueController(VenuePackImporter { imports++; result }, radio, this)
        controller.useLink("link")
        runCurrent()
        result = VenueImportOutcome.NotReady("expired")
        controller.start()
        runCurrent()
        assertEquals(2, imports)
        assertEquals(0, radio.starts)
        assertFalse(controller.state.value.isBroadcasting)
    }

    @Test fun stopDuringPermissionRequestCannotRestartTheRadioLater() = runTest {
        val radio = VenueTestRadio().apply { deferPermission = true }
        val controller = VenueController(VenuePackImporter { VenueImportOutcome.Ready(venueTestPack()) }, radio, this)
        controller.useLink("link")
        runCurrent()
        controller.start()
        runCurrent()
        controller.stop()
        radio.permission!!(true)
        assertEquals(0, radio.starts)
        assertFalse(controller.state.value.isBroadcasting)
    }

    @Test fun importingAnotherPackDoesNotRelabelTheActiveRadioBeforeStart() = runTest {
        val first = venueTestPack()
        val second = first.copy(eventIdHex = "04".repeat(32), displayName = "Second Event", container = byteArrayOf(4))
        var result = first
        val radio = VenueTestRadio()
        val controller = VenueController(VenuePackImporter { VenueImportOutcome.Ready(result) }, radio, this)
        controller.useLink("first")
        runCurrent()
        controller.start()
        runCurrent()
        result = second
        controller.useLink("second")
        runCurrent()
        assertTrue(controller.state.value.isBroadcasting)
        assertEquals(first, controller.state.value.pack)
        assertEquals(1, radio.starts)
        controller.start()
        runCurrent()
        assertEquals(second, controller.state.value.pack)
        assertEquals(2, radio.starts)
    }
}
