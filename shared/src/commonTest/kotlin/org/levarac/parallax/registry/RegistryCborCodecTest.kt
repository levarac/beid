package org.levarac.parallax.registry

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotNull
import kotlin.test.assertNull

class RegistryCborCodecTest {
    @Test
    fun deployedAnvilFixtureDecodesEveryRegistrationAndDefinitionField() {
        val context = RegistryCborCodec.decode(DEPLOYED_ANVIL_CODEC_CBOR_HEX.codecHexToByteArray())

        assertEquals(1, context.schemaVersion)
        assertEquals("0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266", context.registration.registrarHex)
        assertEquals("0x70997970c51812dc3a010c7d01b50e0d17dc79c8", context.registration.operatorHex)
        assertEquals(
            "0x" + "00".repeat(30) + "5678",
            context.registration.keySetDigestHex,
            "The deployed fixture digest ends in 0x5678; it is not an all-zero digest.",
        )
        assertEquals(1_787_211_368L, context.registration.registeredAt)

        assertEquals(1, context.definitionState)
        assertEquals(1L, context.latestSequence)
        assertEquals(1, context.definitionCount)
        assertEquals("0x" + "00".repeat(31) + "d1", context.latestDefinitionDigestHex)

        val record = assertNotNull(context.definitionAt(0))
        assertEquals(1L, record.sequence)
        assertEquals("0x$CODEC_ZERO_DIGEST_HEX", record.previousDefinitionDigestHex)
        assertEquals("0x" + "00".repeat(31) + "d1", record.definitionDigestHex)
        assertEquals(2_000_000_000L, record.validFrom)
        assertEquals(2_000_000_100L, record.validUntil)
        assertEquals(1_787_211_381L, record.anchoredAt)
        assertNull(context.definitionAt(-1))
        assertNull(context.definitionAt(1))
    }

    @Test
    fun trailingBytesAreRejectedRatherThanIgnored() {
        assertFailsWith<IllegalArgumentException> {
            RegistryCborCodec.decode((DEPLOYED_ANVIL_CODEC_CBOR_HEX + "00").codecHexToByteArray())
        }
    }

    @Test
    fun unsupportedSchemaVersionIsRejected() {
        val mutated = mutateHexOnce(
            original = DEPLOYED_ANVIL_CODEC_CBOR_HEX,
            target = "a3010102a4",
            replacement = "a3010202a4",
        )

        assertFailsWith<IllegalArgumentException> {
            RegistryCborCodec.decode(mutated.codecHexToByteArray())
        }
    }

    @Test
    fun unknownDefinitionStateIsRejected() {
        val mutated = mutateHexOnce(
            original = DEPLOYED_ANVIL_CODEC_CBOR_HEX,
            target = "03a3010102010381",
            replacement = "03a3010902010381",
        )

        assertFailsWith<IllegalArgumentException> {
            RegistryCborCodec.decode(mutated.codecHexToByteArray())
        }
    }

    @Test
    fun definitionStateMustMatchWhetherRecordsArePresent() {
        val mutated = mutateHexOnce(
            original = DEPLOYED_ANVIL_CODEC_CBOR_HEX,
            target = "03a3010102010381",
            replacement = "03a3010002010381",
        )

        assertFailsWith<IllegalArgumentException> {
            RegistryCborCodec.decode(mutated.codecHexToByteArray())
        }
    }

    @Test
    fun latestSequenceMustMatchTheLastDefinitionRecord() {
        val mutated = mutateHexOnce(
            original = DEPLOYED_ANVIL_CODEC_CBOR_HEX,
            target = "03a30101020103818601",
            replacement = "03a30101020203818601",
        )

        assertFailsWith<IllegalArgumentException> {
            RegistryCborCodec.decode(mutated.codecHexToByteArray())
        }
    }

    @Test
    fun definitionRecordsMustBeContiguousAndOneBased() {
        val mutated = mutateHexOnce(
            original = DEPLOYED_ANVIL_CODEC_CBOR_HEX,
            target = "038186015820",
            replacement = "038186025820",
        )

        assertFailsWith<IllegalArgumentException> {
            RegistryCborCodec.decode(mutated.codecHexToByteArray())
        }
    }

    @Test
    fun declaredDefinitionCountMustFitTheRemainingPayloadBeforeAllocation() {
        val mutated = mutateHexOnce(
            original = DEPLOYED_ANVIL_CODEC_CBOR_HEX,
            target = "03a3010102010381",
            replacement = "03a301010201039818",
        )

        val failure = assertFailsWith<IllegalArgumentException> {
            RegistryCborCodec.decode(mutated.codecHexToByteArray())
        }
        assertEquals("definition count exceeds the remaining CBOR payload", failure.message)
    }

    @Test
    fun validityAtTwoToThePowerOf53IsRejectedAsProtocolUnsafe() {
        val unsafeValidity = "1b0020000000000000"
        val withUnsafeStart = mutateHexOnce(
            original = DEPLOYED_ANVIL_CODEC_CBOR_HEX,
            target = "1a77359400",
            replacement = unsafeValidity,
        )
        val withUnsafeWindow = mutateHexOnce(
            original = withUnsafeStart,
            target = "1a77359464",
            replacement = unsafeValidity,
        )

        val failure = assertFailsWith<IllegalArgumentException> {
            RegistryCborCodec.decode(withUnsafeWindow.codecHexToByteArray())
        }
        assertEquals("definition validity exceeds the protocol safe-integer maximum", failure.message)
    }

    @Test
    fun definitionAnchorCannotPredateRegistration() {
        val registeredOneSecondAfterAnchor = mutateHexOnce(
            original = DEPLOYED_ANVIL_CODEC_CBOR_HEX,
            target = "1a6a86ae68",
            replacement = "1a6a86ae76",
        )

        val failure = assertFailsWith<IllegalArgumentException> {
            RegistryCborCodec.decode(registeredOneSecondAfterAnchor.codecHexToByteArray())
        }
        assertEquals("definition cannot predate event registration", failure.message)
    }

    @Test
    fun firstDefinitionMustHaveTheZeroPredecessorDigest() {
        val recordPrefix = "038186015820"
        val mutated = mutateHexOnce(
            original = DEPLOYED_ANVIL_CODEC_CBOR_HEX,
            target = recordPrefix + CODEC_ZERO_DIGEST_HEX + "5820",
            replacement = recordPrefix + ("00".repeat(31) + "01") + "5820",
        )

        assertFailsWith<IllegalArgumentException> {
            RegistryCborCodec.decode(mutated.codecHexToByteArray())
        }
    }

    @Test
    fun nonCanonicalIntegerEncodingIsRejected() {
        val mutated = mutateHexOnce(
            original = DEPLOYED_ANVIL_CODEC_CBOR_HEX,
            target = "a3010102a4",
            replacement = "a301180102a4",
        )

        assertFailsWith<IllegalArgumentException> {
            RegistryCborCodec.decode(mutated.codecHexToByteArray())
        }
    }

    @Test
    fun indefiniteLengthTopLevelMapIsRejected() {
        val indefinite = "bf" + DEPLOYED_ANVIL_CODEC_CBOR_HEX.drop(2) + "ff"

        assertFailsWith<IllegalArgumentException> {
            RegistryCborCodec.decode(indefinite.codecHexToByteArray())
        }
    }

    private fun mutateHexOnce(original: String, target: String, replacement: String): String {
        val first = original.indexOf(target)
        require(first >= 0) { "mutation target is absent" }
        require(first == original.lastIndexOf(target)) { "mutation target is ambiguous" }
        return original.replaceRange(first, first + target.length, replacement)
    }
}
