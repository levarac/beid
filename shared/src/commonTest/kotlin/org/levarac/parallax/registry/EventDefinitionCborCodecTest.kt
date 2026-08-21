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
        assertEquals("https://operator.example/v1", definition.submissionEndpoint)
        assertEquals(DEFINITION_RECEIPT_PUBLIC_KEY_HEX, definition.receiptPublicKeyHex.removePrefix("0x"))
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

    @Test
    fun unknownTopLevelKeyIsRejected() {
        val malformed = eventDefinitionCbor().withTopLevelKey8(9)

        assertMalformed(malformed)
    }

    @Test
    fun duplicateTopLevelKeyIsRejected() {
        val malformed = eventDefinitionCbor().withTopLevelKey8(7)

        assertMalformed(malformed)
    }

    @Test
    fun wrongTopLevelMajorTypeIsRejected() {
        val malformed = eventDefinitionCbor().copyOf().also { it[0] = 0x88.toByte() }

        assertMalformed(malformed)
    }

    @Test
    fun nonMinimalUnsignedEncodingIsRejected() {
        val valid = eventDefinitionCbor()
        val malformed = ByteArray(valid.size + 1)
        valid.copyInto(malformed, endIndex = 2)
        malformed[2] = 0x18
        malformed[3] = 0x01
        valid.copyInto(malformed, destinationOffset = 4, startIndex = 3)

        assertMalformed(malformed)
    }

    @Test
    fun indefiniteLengthEncodingIsRejected() {
        val malformed = eventDefinitionCbor().copyOf().also { it[0] = 0xbf.toByte() }

        assertMalformed(malformed)
    }

    @Test
    fun fixedLengthEventIdIsRejected() {
        assertMalformed(eventDefinitionCbor(eventIdHex = "01".repeat(31)))
    }

    @Test
    fun fixedLengthAuthoritySignatureIsRejected() {
        assertMalformed(eventDefinitionCbor(authoritySignatureHex = "05".repeat(63)))
    }

    @Test
    fun fixedLengthReceiptPublicKeyIsRejected() {
        assertMalformed(eventDefinitionCbor(receiptPublicKeyHex = "02" + "00".repeat(31)))
    }

    @Test
    fun invalidReceiptPublicKeyPrefixIsRejectedLoudly() {
        val error = assertFailsWith<DefinitionDecodeException> {
            EventDefinitionCborCodec.decode(
                eventDefinitionCbor(receiptPublicKeyHex = "04" + "00".repeat(32)),
            )
        }
        assertEquals(DefinitionDecodeError.INVALID_RECEIPT_PUBLIC_KEY, error.reason)
    }

    @Test
    fun delegationCountCapIsEnforced() {
        assertMalformed(
            eventDefinitionCbor(
                delegations = List(MAX_EVENT_DEFINITION_DELEGATIONS + 1) { DelegationFixture() },
            ),
        )
    }

    @Test
    fun payloadSizeCapIsEnforced() {
        assertMalformed(ByteArray(MAX_EVENT_DEFINITION_PAYLOAD_BYTES + 1))
    }

    @Test
    fun trailingBytesAreRejected() {
        assertMalformed(eventDefinitionCbor() + byteArrayOf(0))
    }

    private fun assertMalformed(bytes: ByteArray) {
        val error = assertFailsWith<DefinitionDecodeException> {
            EventDefinitionCborCodec.decode(bytes)
        }
        assertEquals(DefinitionDecodeError.MALFORMED, error.reason)
    }

    private fun ByteArray.withTopLevelKey8(value: Int): ByteArray {
        val copy = copyOf()
        val keyIndex = indexOfFirst { (it.toInt() and 0xff) == 8 }
        require(keyIndex >= 0)
        copy[keyIndex] = value.toByte()
        return copy
    }
}
