package org.levarac.parallax.venue

import kotlinx.serialization.json.jsonObject
import org.levarac.parallax.observation.ByteString32
import org.levarac.parallax.observation.CanonicalCbor
import org.levarac.parallax.registry.Address20
import org.levarac.parallax.registry.DefinitionDecodeError
import org.levarac.parallax.registry.DefinitionDecodeException
import org.levarac.parallax.registry.EventDefinitionCborCodec
import org.levarac.parallax.registry.RegistryCacheKey
import org.levarac.parallax.registry.RegistryDefinitionRecord
import org.levarac.parallax.registry.RegistryEventContext
import org.levarac.parallax.registry.RegistryRegistration
import org.levarac.parallax.registry.RegistryResolution
import org.levarac.parallax.registry.decodeHex
import org.levarac.parallax.registry.definitionForUseTime
import org.levarac.parallax.registry.requiredString
import org.levarac.parallax.registry.toPrefixedHex
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotNull
import kotlin.test.assertNull

class VenueBundleIdentityTest {
    @Test
    fun acceptsBothPinnedModesAfterChainAndHandoffIdentityChecks() {
        for (mode in listOf("authorityDirect", "delegate")) {
            val (bundle, handoff) = fixturePair(mode)
            val result = verifyVenueBundleIdentity(bundle, handoff, read(bundle))
            val identity = assertNotNull(result.identity)
            assertNull(result.failureCode)
            assertEquals(bundle.eventId, identity.definition.eventId)
            assertEquals(1L, identity.definition.sequence.value)
            assertEquals(BLOCK_HASH, identity.readKey.blockHashHex)
            assertEquals(bundle.bundleDigest, identity.bundle.bundleDigest)
        }
    }

    @Test
    fun everyHandoffCoordinateAndDigestMustAgree() {
        val (bundle, handoff) = fixturePair()
        val wrong = listOf(
            handoffCopy(handoff, eventId = ByteString32(ByteArray(32))),
            handoffCopy(handoff, chainId = 1),
            handoffCopy(handoff, eventRegistry = Address20(ByteArray(20))),
            handoffCopy(handoff, definitionRegistry = Address20(ByteArray(20))),
            handoffCopy(handoff, digest = ByteString32(ByteArray(32))),
        )
        for (candidate in wrong) expectFailure("handoff_mismatch", bundle, candidate, read(bundle))
    }

    @Test
    fun matchingUntrustedBundleAndHandoffCannotChooseAnotherDeployment() {
        val (original, handoff) = fixturePair()
        val wrong = listOf(
            reencode(original, chainId = 1),
            reencode(original, eventRegistry = Address20(ByteArray(20))),
            reencode(original, definitionRegistry = Address20(ByteArray(20))),
        )
        for (bundle in wrong) {
            val agreeingHandoff = handoffCopy(
                handoff, chainId = bundle.chainId, eventRegistry = bundle.eventRegistry,
                definitionRegistry = bundle.eventDefinitionRegistry, digest = bundle.bundleDigest,
            )
            expectFailure("deployment_mismatch", bundle, agreeingHandoff, read(bundle))
        }
    }

    @Test
    fun sourceChainReaderAndRequestedEventAreChecked() {
        val (bundle, handoff) = fixturePair()
        val wrong = listOf(
            key(bundle, chainId = 1),
            key(bundle, reader = "0x" + "11".repeat(20)),
            key(bundle, eventId = "0x" + "00".repeat(32)),
            key(bundle, blockHash = "0x" + "33".repeat(32)),
            key(bundle, blockNumber = 43),
            key(bundle, definitionHash = "0x" + "44".repeat(32)),
        )
        for (source in wrong) {
            expectFailure("registry_source_mismatch", bundle, handoff, read(bundle, readKey = source))
        }
    }

    @Test
    fun failedOrUnboundRegistryReadsNeverProduceAnIdentity() {
        val (bundle, handoff) = fixturePair()
        val wrong = listOf(
            read(bundle, success = false),
            read(bundle, context = null),
            read(bundle, readKey = null),
        )
        for (source in wrong) expectFailure("registry_unavailable", bundle, handoff, source)
    }

    @Test
    fun namedRecordNeedNotBeTheHighestSequenceOrCurrentSelection() {
        val (bundle, handoff) = fixturePair()
        val first = venueLeaseVector().venueDefinitionRecord()
        val later = recordCopy(
            first, sequence = 2, digest = "44".repeat(32),
            validFrom = first.validUntil + 1, validUntil = first.validUntil + 3_600,
            previousDigest = first.definitionDigestHex,
        )
        val context = context(listOf(first, later))
        assertEquals(2L, definitionForUseTime(context, first.validUntil + 1)?.sequence)
        val identity = assertNotNull(verifyVenueBundleIdentity(bundle, handoff, read(bundle, context)).identity)
        assertEquals(1L, identity.definition.sequence.value)
        assertEquals(later.definitionDigestHex, identity.readKey.definitionHashHex)
        // This import result has no claim that sequence 1 can serve at the time selecting 2.
    }

    @Test
    fun onlyTheNamedSequenceAndDigestCanBeImported() {
        val (bundle, handoff) = fixturePair()
        val record = venueLeaseVector().venueDefinitionRecord()
        val wrong = listOf(
            context(emptyList()),
            context(listOf(recordCopy(record, sequence = 2))),
            context(listOf(recordCopy(record, digest = "00".repeat(32)))),
        )
        for (source in wrong) expectFailure("definition_not_registered", bundle, handoff, read(bundle, source))
    }

    @Test
    fun alteredSignatureIsRejectedEvenWithAnUpdatedOuterDigestAndHandoff() {
        val (original, handoff) = fixturePair()
        val signed = original.signedEventDefinition.toByteArray()
        signed[signed.lastIndex] = (signed.last().toInt() xor 1).toByte()
        val definitionDigest = ByteString32(EventDefinitionCborCodec.eventDefinitionDigest(signed))
        val bundle = reencode(original, signedDefinition = signed, definitionDigest = definitionDigest)
        val record = recordCopy(
            venueLeaseVector().venueDefinitionRecord(),
            digest = definitionDigest.toByteArray().toPrefixedHex(),
        )
        val registry = context(listOf(record))
        // Align both digest layers AND the anchor, so digest rejection cannot
        // masquerade as signature verification. The bytes reach that check.
        val signatureFailure = assertFailsWith<DefinitionDecodeException> {
            EventDefinitionCborCodec.verify(
                signedBytes = signed,
                encodedKeySet = bundle.eventKeySet.toByteArray(),
                eventId = bundle.eventId.toByteArray(),
                registration = registry.registration,
                record = record,
                at = record.validFrom,
            )
        }
        assertEquals(DefinitionDecodeError.INVALID_SIGNATURE, signatureFailure.reason)
        expectFailure(
            "invalid_definition", bundle, handoffCopy(handoff, digest = bundle.bundleDigest),
            read(bundle, registry),
        )
    }

    @Test
    fun alteredKeySetIsRejectedEvenWithAnUpdatedOuterDigestAndHandoff() {
        val (original, handoff) = fixturePair()
        val keySet = original.eventKeySet.toByteArray()
        keySet[keySet.lastIndex] = (keySet.last().toInt() xor 1).toByte()
        val bundle = reencode(original, keySet = keySet)
        expectFailure("invalid_definition", bundle, handoffCopy(handoff, digest = bundle.bundleDigest), read(bundle))
    }

    @Test
    fun registrationAndAnchoredValidityMustMatchTheSignedDefinition() {
        val (bundle, handoff) = fixturePair()
        val original = venueLeaseVector().venueRegistration()
        val wrongRegistration = RegistryRegistration(
            original.registrarHex, original.operatorHex, "00".repeat(32), original.registeredAt,
        )
        val record = venueLeaseVector().venueDefinitionRecord()
        expectFailure("invalid_definition", bundle, handoff, read(bundle, context(listOf(record), wrongRegistration)))
        expectFailure("invalid_definition", bundle, handoff, read(bundle, context(listOf(recordCopy(record, validUntil = record.validUntil - 1)))))
    }

    private fun fixturePair(mode: String = "authorityDirect"): Pair<VenueBundle, VenueHandoff> {
        val case = venueLeaseVector().getValue(mode).jsonObject
        return requireNotNull(decodeVenueBundle(case.requiredString("bundleHex").decodeHex())) to
            requireNotNull(decodeVenueHandoff(case.requiredString("handoffHex").decodeHex()))
    }

    private fun key(
        bundle: VenueBundle,
        chainId: Long = 11_155_111,
        reader: String = "0x" + venueLeaseVector().requiredString("readerAddressHex"),
        eventId: String = bundle.eventId.toByteArray().toPrefixedHex(),
        blockHash: String = BLOCK_HASH,
        blockNumber: Long = 42,
        definitionHash: String = bundle.definitionDigest.toByteArray().toPrefixedHex(),
    ) = RegistryCacheKey(chainId, reader, eventId, definitionHash, blockNumber, blockHash)

    private fun read(
        bundle: VenueBundle,
        context: RegistryEventContext? = venueLeaseVector().venueRegistryContext(),
        readKey: RegistryCacheKey? = key(
            bundle, definitionHash = context?.latestDefinitionDigestHex
                ?: ZERO_DIGEST,
        ),
        success: Boolean = true,
    ) = RegistryResolution(success, context, 42, BLOCK_HASH, context?.latestDefinitionDigestHex ?: ZERO_DIGEST, null, null, readKey)

    private fun context(
        records: List<RegistryDefinitionRecord>,
        registration: RegistryRegistration = venueLeaseVector().venueRegistration(),
    ) = RegistryEventContext(1, registration, if (records.isEmpty()) 0 else 1, records.lastOrNull()?.sequence ?: 0, records)

    private fun recordCopy(
        record: RegistryDefinitionRecord,
        sequence: Long = record.sequence,
        digest: String = record.definitionDigestHex,
        validFrom: Long = record.validFrom,
        validUntil: Long = record.validUntil,
        previousDigest: String = record.previousDefinitionDigestHex,
    ) = RegistryDefinitionRecord(sequence, previousDigest, digest, validFrom, validUntil, record.anchoredAt)

    private fun handoffCopy(
        source: VenueHandoff,
        eventId: ByteString32 = source.eventId,
        chainId: Long = source.chainId,
        eventRegistry: Address20 = source.eventRegistry,
        definitionRegistry: Address20 = source.eventDefinitionRegistry,
        digest: ByteString32 = source.bundleDigest,
    ) = VenueHandoff(eventId, chainId, eventRegistry, definitionRegistry, digest, source.bundleUrl)

    private fun reencode(
        source: VenueBundle,
        chainId: Long = source.chainId,
        signedDefinition: ByteArray = source.signedEventDefinition.toByteArray(),
        keySet: ByteArray = source.eventKeySet.toByteArray(),
        definitionDigest: ByteString32 = source.definitionDigest,
        eventRegistry: Address20 = source.eventRegistry,
        definitionRegistry: Address20 = source.eventDefinitionRegistry,
    ): VenueBundle {
        fun uint(value: Long) = CanonicalCbor.uint(value)
        fun bytes(value: ByteArray) = CanonicalCbor.bytes(value)
        return requireNotNull(decodeVenueBundle(CanonicalCbor.encode(CanonicalCbor.map(
            uint(1) to uint(1), uint(2) to uint(chainId),
            uint(3) to bytes(eventRegistry.toByteArray()),
            uint(4) to bytes(definitionRegistry.toByteArray()),
            uint(5) to bytes(source.eventId.toByteArray()), uint(6) to uint(source.definitionSequence),
            uint(7) to bytes(definitionDigest.toByteArray()),
            uint(8) to bytes(signedDefinition), uint(9) to bytes(keySet),
            uint(10) to CanonicalCbor.array(List(source.envelopeCount) { bytes(requireNotNull(source.envelopeAt(it))) }),
        ))))
    }

    private fun expectFailure(code: String, bundle: VenueBundle, handoff: VenueHandoff, read: RegistryResolution) {
        val result = verifyVenueBundleIdentity(bundle, handoff, read)
        assertNull(result.identity)
        assertEquals(code, result.failureCode)
    }

    private companion object {
        const val BLOCK_HASH = "0x2222222222222222222222222222222222222222222222222222222222222222"
        const val ZERO_DIGEST = "0x0000000000000000000000000000000000000000000000000000000000000000"
    }
}
