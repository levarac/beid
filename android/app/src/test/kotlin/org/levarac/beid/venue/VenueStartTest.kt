package org.levarac.beid.venue

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.runCurrent
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

@OptIn(ExperimentalCoroutinesApi::class)
class VenueStartTest {
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
