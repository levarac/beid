package org.levarac.beid.venue

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceUntilIdle
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
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
        scope.advanceUntilIdle()
        assertTrue(controller.state.value.isBroadcasting)

        outcome = VenueImportOutcome.LinkUnreadable
        controller.useLink("broken")
        scope.advanceUntilIdle()

        assertTrue(controller.state.value.isBroadcasting)
        assertEquals(0, radio.stopCalls)
        kotlin.test.assertNotNull(controller.state.value.message)
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
        scope.advanceUntilIdle()
        assertEquals(1, radio.startCalls)
        assertTrue(controller.state.value.isBroadcasting)
        controller.stop()
        assertFalse(controller.state.value.isBroadcasting)
    }

    @Test
    fun failedRefreshStopsTheRadioSoItMatchesTheStoppedScreen() {
        val dispatcher = StandardTestDispatcher()
        val scope = TestScope(dispatcher)
        val radio = FakeRadio()
        val packs = mapOf(LINK_A to pack("0a"), LINK_B to pack("0b"))
        val controller = VenueController(VenuePackImporter { VenueImportOutcome.Ready(packs.getValue(it)) }, radio, scope)

        controller.useLink(LINK_A)
        scope.advanceUntilIdle()
        controller.start()
        scope.advanceUntilIdle()
        assertTrue(controller.state.value.isBroadcasting)

        controller.useLink(LINK_B)
        scope.advanceUntilIdle()
        radio.startResult = false
        controller.start()
        scope.advanceUntilIdle()

        assertEquals(2, radio.startCalls)
        assertEquals(1, radio.stopCalls)
        val state = controller.state.value
        assertFalse(state.isBroadcasting)
        assertFalse(state.isStarting)
        assertEquals(VenueNotice.RADIO_FAILED, state.message)
    }

    @Test
    fun rejectedRefreshOfPendingLinkIsNotPromotedOnStop() {
        val dispatcher = StandardTestDispatcher()
        val scope = TestScope(dispatcher)
        val radio = FakeRadio()
        val imported = mutableListOf<String>()
        var pendingOutcome: VenueImportOutcome = VenueImportOutcome.Ready(pack("0b"))
        val controller = VenueController(
            VenuePackImporter { link ->
                imported += link
                if (link == LINK_A) VenueImportOutcome.Ready(pack("0a")) else pendingOutcome
            },
            radio,
            scope,
        )

        controller.useLink(LINK_A)
        scope.advanceUntilIdle()
        controller.start()
        scope.advanceUntilIdle()
        controller.useLink(LINK_B)
        scope.advanceUntilIdle()
        assertEquals("0b".repeat(32), controller.state.value.pendingPack?.eventIdHex)

        pendingOutcome = VenueImportOutcome.NotReady("expired")
        controller.start()
        scope.advanceUntilIdle()

        var state = controller.state.value
        assertTrue(state.isBroadcasting)
        assertEquals("0a".repeat(32), state.pack?.eventIdHex)
        assertNull(state.pendingPack)
        assertEquals(VenueNotice.EXPIRED, state.message)
        assertEquals(0, radio.stopCalls)

        controller.stop()
        state = controller.state.value
        assertEquals("0a".repeat(32), state.pack?.eventIdHex)
        assertEquals("0a".repeat(32), state.linkEventIdHex)

        controller.start()
        scope.advanceUntilIdle()
        assertEquals(LINK_A, imported.last())
        assertEquals(2, radio.startCalls)
        assertTrue(controller.state.value.isBroadcasting)
        assertEquals("0a".repeat(32), controller.state.value.pack?.eventIdHex)
    }

    private fun pack(id: String = "03") =
        VenuePack(id.repeat(32), "Example Event", 1, 2, byteArrayOf(id.toInt(16).toByte()), 2)

    private companion object {
        const val LINK_A = "https://example.test/#a"
        const val LINK_B = "https://example.test/#b"
    }

    private class FakeRadio : VenueRadio {
        var startCalls = 0
        var stopCalls = 0
        var startResult = true
        override fun requestPermission(completion: (Boolean) -> Unit) = completion(true)
        override fun start(container: ByteArray): Boolean { startCalls++; return startResult }
        override fun stop() { stopCalls++ }
        override fun forwardPermissionResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) = false
        override fun dispose() = Unit
    }
}
