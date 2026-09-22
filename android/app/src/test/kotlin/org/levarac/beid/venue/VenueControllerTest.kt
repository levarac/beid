package org.levarac.beid.venue

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceUntilIdle
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

@OptIn(ExperimentalCoroutinesApi::class)
class VenueControllerTest {
    @Test
    fun invalidLinkWhileBroadcastingDoesNotTouchRadioLease() {
        val dispatcher = StandardTestDispatcher()
        val scope = TestScope(dispatcher)
        val radio = FakeRadio()
        var outcome: VenueImportOutcome = VenueImportOutcome.Ready(pack())
        val controller = VenueController(VenuePackImporter { outcome }, radio, scope)

        controller.useLink("https://example.test/#valid")
        scope.advanceUntilIdle()
        controller.start()
        assertTrue(controller.state.value.isBroadcasting)

        outcome = VenueImportOutcome.LinkUnreadable
        controller.useLink("broken")
        scope.advanceUntilIdle()

        assertTrue(controller.state.value.isBroadcasting)
        assertEquals(0, radio.stopCalls)
        assertEquals("That link cannot be read.", controller.state.value.message)
    }

    @Test
    fun radioStartsOnlyAfterExplicitStartAndPermission() {
        val dispatcher = StandardTestDispatcher()
        val scope = TestScope(dispatcher)
        val radio = FakeRadio()
        val controller = VenueController(VenuePackImporter { VenueImportOutcome.Ready(pack()) }, radio, scope)

        controller.useLink("https://example.test/#valid")
        scope.advanceUntilIdle()
        assertEquals(0, radio.startCalls)

        controller.start()
        assertEquals(1, radio.startCalls)
        assertTrue(controller.state.value.isBroadcasting)
        controller.stop()
        assertFalse(controller.state.value.isBroadcasting)
    }

    private fun pack() = VenuePack("03".repeat(32), "Example Event", 1, 2, byteArrayOf(3), 2)

    private class FakeRadio : VenueRadio {
        var startCalls = 0
        var stopCalls = 0
        override fun requestPermission(completion: (Boolean) -> Unit) = completion(true)
        override fun start(container: ByteArray): Boolean { startCalls++; return true }
        override fun stop() { stopCalls++ }
        override fun forwardPermissionResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) = false
        override fun dispose() = Unit
    }
}
