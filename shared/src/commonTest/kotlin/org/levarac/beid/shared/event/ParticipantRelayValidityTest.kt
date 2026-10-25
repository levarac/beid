package org.levarac.beid.shared.event

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull

class ParticipantRelayValidityTest {
    @Test
    fun validityEndAtTheUnsigned32BitMaximumIsPreserved() {
        val validity = assertNotNull(participantRelayValidity(0L, 4_294_967_295L, 1L))
        assertEquals(0L, validity.validFromEnin)
        assertEquals(4_294_967_295L, validity.validThroughEnin)
        assertEquals(1L, validity.relayExpiresAtEnin)
    }

    @Test
    fun validityEndAboveTheUnsigned32BitMaximumIsClamped() {
        val validity = assertNotNull(participantRelayValidity(0L, 4_294_967_296L, 1L))
        assertEquals(0L, validity.validFromEnin)
        assertEquals(4_294_967_295L, validity.validThroughEnin)
        assertEquals(1L, validity.relayExpiresAtEnin)
    }

    @Test
    fun signedExpiryAtTheUnsigned32BitMaximumIsPreserved() {
        val validity = assertNotNull(participantRelayValidity(0L, 4_294_967_295L, 4_294_967_295L))
        assertEquals(4_294_967_295L, validity.relayExpiresAtEnin)
    }

    @Test
    fun signedExpiryAboveTheUnsigned32BitMaximumIsRejected() {
        assertNull(participantRelayValidity(0L, 4_294_967_296L, 4_294_967_296L))
    }

    @Test
    fun negativeSignedExpiryIsRejected() {
        assertNull(participantRelayValidity(0L, 1L, -1L))
    }

    @Test
    fun validityStartAtTheUnsigned32BitMaximumIsPreserved() {
        val validity = assertNotNull(participantRelayValidity(4_294_967_295L, 4_294_967_295L, 4_294_967_295L))
        assertEquals(4_294_967_295L, validity.validFromEnin)
    }

    @Test
    fun validityStartAboveTheUnsigned32BitMaximumIsRejected() {
        assertNull(participantRelayValidity(4_294_967_296L, 4_294_967_296L, 4_294_967_295L))
    }

    @Test
    fun negativeValidityBoundsRetainTheIosZeroClamp() {
        val validity = assertNotNull(participantRelayValidity(Long.MIN_VALUE, Long.MIN_VALUE, 0L))
        assertEquals(0L, validity.validFromEnin)
        assertEquals(0L, validity.validThroughEnin)
        assertEquals(0L, validity.relayExpiresAtEnin)
    }

    @Test
    fun extremeLongValuesNeverWrap() {
        val validity = assertNotNull(participantRelayValidity(0L, Long.MAX_VALUE, 1L))
        assertEquals(4_294_967_295L, validity.validThroughEnin)
        assertNull(participantRelayValidity(Long.MAX_VALUE, Long.MAX_VALUE, 1L))
        assertNull(participantRelayValidity(0L, Long.MAX_VALUE, Long.MAX_VALUE))
    }
}
