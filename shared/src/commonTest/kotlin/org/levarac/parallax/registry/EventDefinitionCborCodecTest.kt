package org.levarac.parallax.registry

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

class EventDefinitionCborCodecTest {
    @Test
    fun validDefinitionAndDelegationDecode() {
        val definition = EventDefinitionCborCodec.decode(eventDefinitionCbor())

        assertEquals(1, definition.schemaVersion)
        assertEquals(DEFINITION_EVENT_ID_HEX, definition.eventIdHex.removePrefix("0x"))
        assertEquals(100L, definition.validFrom)
        assertEquals(200L, definition.validUntil)
        assertEquals(90L, definition.signedAt)
        assertEquals(1, definition.delegationCount)
        val delegation = requireNotNull(definition.delegationAt(0))
        assertTrue(delegation.hasRole(DelegationRoles.RECEPTION))
        assertEquals(130L, delegation.validFrom)
        assertEquals(180L, delegation.validUntil)
    }

    @Test
    fun malformedPayloadProducesTypedDecodeError() {
        val valid = eventDefinitionCbor()
        val malformed = valid.copyOf(valid.lastIndex)

        val error = assertFailsWith<DefinitionDecodeException> {
            EventDefinitionCborCodec.decode(malformed)
        }
        assertEquals(DefinitionDecodeError.MALFORMED, error.reason)
    }

    @Test
    fun unsupportedVersionIsRejectedExplicitly() {
        val error = assertFailsWith<DefinitionDecodeException> {
            EventDefinitionCborCodec.decode(eventDefinitionCbor(schemaVersion = 2L))
        }
        assertEquals(DefinitionDecodeError.UNSUPPORTED_VERSION, error.reason)
    }

    @Test
    fun backdatedDelegationIsRejectedAsForwardValidityViolation() {
        val error = assertFailsWith<DefinitionDecodeException> {
            EventDefinitionCborCodec.decode(
                eventDefinitionCbor(
                    delegations = listOf(
                        DelegationFixture(issuedAt = 95L, validFrom = 99L),
                    ),
                ),
            )
        }
        assertEquals(DefinitionDecodeError.FORWARD_VALIDITY, error.reason)
    }
}
