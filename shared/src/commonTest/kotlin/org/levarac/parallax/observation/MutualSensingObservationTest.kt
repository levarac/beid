package org.levarac.parallax.observation

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.double
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

class MutualSensingObservationTest {
    @Test
    fun committedVectorsMatchThePinnedParallaxSourceChecksums() {
        assertEquals(
            "d3055460733fbb5f013775a2c7dff12611990a318866ebaa5ad17c30eaed99cc",
            Sha256.digest(
                readVectorResource("vectors/positive/mutual-sensing-window-v1.json").encodeToByteArray(),
            ).toHex(),
            "positive vector drifted from Parallax 6d64810",
        )
        assertEquals(
            "7d0a5d22a087bc14fc7f154088b920d3effca83795cf8a13993e70d1191d083d",
            Sha256.digest(
                readVectorResource("vectors/negative/mutual-sensing-window-v1.json").encodeToByteArray(),
            ).toHex(),
            "negative vector drifted from Parallax 6d64810",
        )
    }

    @Test
    fun positiveVectorsMatchTheCommittedTypeScriptObservationBytes() {
        val root = Json.parseToJsonElement(
            readVectorResource("vectors/positive/mutual-sensing-window-v1.json"),
        ).jsonObject

        root.getValue("cases").jsonArray.forEach { element ->
            val case = element.jsonObject
            val input = case.getValue("input").jsonObject
            val result = prepareMutualSensingObservation(input.toEvidence())
            val prepared = (result as ObservationPreparationResult.Eligible).prepared

            assertContentEquals(
                case.getValue("expectedObservationHex").jsonPrimitive.content.hexToBytes(),
                prepared.observationCbor.toByteArray(),
                case.getValue("name").jsonPrimitive.content,
            )
            assertEquals(1, prepared.observation.version)
            assertEquals(
                input.getValue("observedRpidsHex").jsonArray.size,
                prepared.observationPayload.observedRpids.size,
            )
            if (case.getValue("name").jsonPrimitive.content == "canonical-sorted-rpids") {
                assertContentEquals(
                    "846a5369676e6174757265315839a301382e0378286170706c69636174696f6e2f766e642e6c6576617261632e6f62736572766174696f6e2b63626f7204482e0268a2a205c3f040590109a80101025000112233445566778899aabbccddeeff0378196c6576617261632e6d757475616c2d73656e73696e672f76310458202121212121212121212121212121212121212121212121212121212121212121055821031428f3a3532ff4f1cac70f7292bfad06d1037f800ee8839b56ebba917a22e900061a6b49d20007510110101010101010101010101010101010085875a50158202222222222222222222222222222222222222222222222222222222222222222021a005b8d80038251011111111111111111111111111111111151012222222222222222222222222222222204f6055820abababababababababababababababababababababababababababababababab".hexToBytes(),
                    prepared.signatureStructure.toByteArray(),
                )
                assertEquals(
                    "2cbf616a81bc175ad3fb5f525bc45514894cedac1fe459af3318f9213a3bb03a",
                    prepared.sha256Digest.toByteArray().toHex(),
                )
            }
        }
    }

    @Test
    fun negativeVectorsRemainTypedIneligible() {
        val root = Json.parseToJsonElement(
            readVectorResource("vectors/negative/mutual-sensing-window-v1.json"),
        ).jsonObject

        root.getValue("cases").jsonArray.forEach { element ->
            val case = element.jsonObject
            val result = prepareMutualSensingObservation(case.getValue("input").jsonObject.toEvidence())

            assertEquals(false, result.eligible, case.getValue("name").jsonPrimitive.content)
            assertEquals(
                case.getValue("expectedCode").jsonPrimitive.content,
                (result as ObservationPreparationResult.Ineligible).code.wireName,
            )
        }
    }

    @Test
    fun canonicalizerRejectsLegacyCountOnlyEvidenceBeforeEncoding() {
        val root = Json.parseToJsonElement(
            readVectorResource("vectors/negative/mutual-sensing-window-v1.json"),
        ).jsonObject
        val input = root.getValue("cases").jsonArray
            .first { it.jsonObject.getValue("name").jsonPrimitive.content == "legacy-count-only" }
            .jsonObject.getValue("input").jsonObject

        val result = prepareMutualSensingObservation(input.toEvidence())

        assertEquals(ObservationIneligibilityCode.LEGACY_COUNT_ONLY, (result as ObservationPreparationResult.Ineligible).code)
    }

    @Test
    fun signerPortRejectsAByteThatDoesNotVerifyBeforeEmittingCose() {
        val root = Json.parseToJsonElement(
            readVectorResource("vectors/positive/mutual-sensing-window-v1.json"),
        ).jsonObject
        val evidence = root.getValue("cases").jsonArray.first().jsonObject
            .getValue("input").jsonObject.toEvidence()
        val prepared = (prepareMutualSensingObservation(evidence) as ObservationPreparationResult.Eligible).prepared
        val signer = object : SignerPort {
            override val publicKey = evidence.observer
            override val inputMode = SignerInputMode.SIG_STRUCTURE

            override fun sign(request: SigningRequest): CompactEs256kSignature {
                assertTrue(request is SigningRequest.SigStructure)
                assertContentEquals(
                    prepared.signatureStructure.toByteArray(),
                    request.bytes.toByteArray(),
                )
                return CompactEs256kSignature(ByteArray(32), ByteArray(32))
            }
        }

        assertFailsWith<InvalidObservationSignatureException> {
            prepared.sign(signer)
        }
    }

    @Test
    fun signerPortReceivesTheTypedDigestAndEmitsTheReferenceCoseBytes() {
        val root = Json.parseToJsonElement(
            readVectorResource("vectors/positive/mutual-sensing-window-v1.json"),
        ).jsonObject
        val evidence = root.getValue("cases").jsonArray.first().jsonObject
            .getValue("input").jsonObject.toEvidence()
            .copy(
                observer = CompressedSecp256k1PublicKey(
                    "0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798".hexToBytes(),
                ),
            )
        val prepared = (prepareMutualSensingObservation(evidence) as ObservationPreparationResult.Eligible).prepared
        val signer = object : SignerPort {
            override val publicKey = evidence.observer
            override val inputMode = SignerInputMode.SHA256_DIGEST

            override fun sign(request: SigningRequest): CompactEs256kSignature {
                val digest = (request as SigningRequest.Digest).digest.toByteArray()
                assertContentEquals(
                    "d3e1f56f1739138cf5970b91f65bd47ccc8352c56f2453348718eb6d879d2992".hexToBytes(),
                    digest,
                )
                return CompactEs256kSignature(
                    "d9b39668ed2e92db7226461f059a1ecd06a732bd5bfdae0b23d43390a8025349".hexToBytes(),
                    "462b3ecfaa8305881ad1a8b8960e9f3f1e6770683e0c178543613de942c8b765".hexToBytes(),
                )
            }
        }

        val signed = prepared.sign(signer)

        assertContentEquals(
            "d2845839a301382e0378286170706c69636174696f6e2f766e642e6c6576617261632e6f62736572766174696f6e2b63626f7204485ef036280edf16eba0590109a80101025000112233445566778899aabbccddeeff0378196c6576617261632e6d757475616c2d73656e73696e672f763104582021212121212121212121212121212121212121212121212121212121212121210558210279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798061a6b49d20007510110101010101010101010101010101010085875a50158202222222222222222222222222222222222222222222222222222222222222222021a005b8d80038251011111111111111111111111111111111151012222222222222222222222222222222204f6055820abababababababababababababababababababababababababababababababab5840d9b39668ed2e92db7226461f059a1ecd06a732bd5bfdae0b23d43390a8025349462b3ecfaa8305881ad1a8b8960e9f3f1e6770683e0c178543613de942c8b765".hexToBytes(),
            signed.cose.toByteArray(),
        )
    }

    @Test
    fun capturedEvidenceDoesNotChangeWhenCallerMutatesItsInputs() {
        val root = Json.parseToJsonElement(
            readVectorResource("vectors/positive/mutual-sensing-window-v1.json"),
        ).jsonObject
        val source = root.getValue("cases").jsonArray.first().jsonObject
            .getValue("input").jsonObject.toEvidence()
        val callerRpidBytes = source.observedRpids!!.first().toByteArray()
        val callerRpids = mutableListOf<ImmutableBytes>(ImmutableBytes(callerRpidBytes))
        val captured = source.copy(observedRpids = callerRpids)
        val before = (prepareMutualSensingObservation(captured) as ObservationPreparationResult.Eligible)
            .prepared.observationCbor.toByteArray()

        callerRpids.clear()
        callerRpidBytes[0] = 0

        val after = (prepareMutualSensingObservation(captured) as ObservationPreparationResult.Eligible)
            .prepared.observationCbor.toByteArray()
        assertContentEquals(before, after)
    }

    @Test
    fun payloadEncodedBytesDoNotChangeWhenCallerMutatesItsObservedRpidList() {
        val root = Json.parseToJsonElement(
            readVectorResource("vectors/positive/mutual-sensing-window-v1.json"),
        ).jsonObject
        val source = root.getValue("cases").jsonArray.first().jsonObject
            .getValue("input").jsonObject.toEvidence()
        val callerRpids = mutableListOf(
            BarnardRpid17(source.observedRpids!!.first().toByteArray()),
        )
        val payload = MutualSensingPayloadV1(
            eventDefinitionDigest = source.eventDefinitionDigest,
            enin = source.enin,
            observedRpids = callerRpids,
            rpidClaim = source.rpidClaim,
            participantCommitment = null,
        )
        val before = payload.encodeCanonicalBytesForTest()

        callerRpids.clear()

        assertContentEquals(before, payload.encodeCanonicalBytesForTest())
    }

    @Test
    fun observationEncodedBytesDoNotChangeWhenCallerMutatesItsPayloadBytes() {
        val payloadBytes = byteArrayOf(1, 2, 3)
        val observation = ObservationV1(
            version = 1,
            id = UuidBytes16(ByteArray(16) { it.toByte() }),
            profile = "levarac.mutual-sensing/v1",
            context = ByteString32(ByteArray(32) { 0x21 }),
            observer = CompressedSecp256k1PublicKey(
                "031428f3a3532ff4f1cac70f7292bfad06d1037f800ee8839b56ebba917a22e900".hexToBytes(),
            ),
            observedAt = ProtocolUInt(1),
            subject = BarnardRpid17(byteArrayOf(1) + ByteArray(16) { 0x10 }),
            payload = ImmutableBytes(payloadBytes),
        )
        val before = observation.encodeCanonicalBytesForTest()

        payloadBytes[0] = 0x7f

        assertContentEquals(before, observation.encodeCanonicalBytesForTest())
    }

    @Test
    fun publicByteBoundariesKeepEncodedBytesWhenCallerMutatesInputArrays() {
        val idInput = ByteArray(16) { it.toByte() }
        val id = UuidBytes16(idInput)
        val idBefore = id.toByteArray()
        idInput[0] = 0x7f
        assertContentEquals(idBefore, id.toByteArray())

        val bytes32Input = ByteArray(32) { it.toByte() }
        val bytes32 = ByteString32(bytes32Input)
        val bytes32Before = bytes32.toByteArray()
        bytes32Input[0] = 0x7f
        assertContentEquals(bytes32Before, bytes32.toByteArray())

        val rpidInput = byteArrayOf(1) + ByteArray(16) { it.toByte() }
        val rpid = BarnardRpid17(rpidInput)
        val rpidBefore = rpid.toByteArray()
        rpidInput[0] = 0x7f
        assertContentEquals(rpidBefore, rpid.toByteArray())

        val publicKeyInput =
            "031428f3a3532ff4f1cac70f7292bfad06d1037f800ee8839b56ebba917a22e900".hexToBytes()
        val publicKey = CompressedSecp256k1PublicKey(publicKeyInput)
        val publicKeyBefore = publicKey.toByteArray()
        publicKeyInput[0] = 0x02
        assertContentEquals(publicKeyBefore, publicKey.toByteArray())

        val observationCborInput = byteArrayOf(1, 2, 3)
        val observationCbor = ObservationCborBytes(observationCborInput)
        val observationCborBefore = observationCbor.toByteArray()
        observationCborInput[0] = 0x7f
        assertContentEquals(observationCborBefore, observationCbor.toByteArray())

        val sigStructureInput = byteArrayOf(4, 5, 6)
        val sigStructure = SigStructureBytes(sigStructureInput)
        val sigStructureBefore = sigStructure.toByteArray()
        sigStructureInput[0] = 0x7f
        assertContentEquals(sigStructureBefore, sigStructure.toByteArray())

        val digestInput = ByteArray(32) { (it + 1).toByte() }
        val digest = Sha256Digest(digestInput)
        val digestBefore = digest.toByteArray()
        digestInput[0] = 0x7f
        assertContentEquals(digestBefore, digest.toByteArray())
    }

    @Test
    fun signerInputsAndOutputsKeepEncodedBytesWhenCallerMutatesInputArrays() {
        val sigStructureInput = byteArrayOf(1, 2, 3)
        val sigStructureRequest = SigningRequest.SigStructure(SigStructureBytes(sigStructureInput))
        val sigStructureBefore = sigStructureRequest.bytes.toByteArray()
        sigStructureInput[0] = 0x7f
        assertContentEquals(sigStructureBefore, sigStructureRequest.bytes.toByteArray())

        val digestInput = ByteArray(32) { it.toByte() }
        val digestRequest = SigningRequest.Digest(Sha256Digest(digestInput))
        val digestBefore = digestRequest.digest.toByteArray()
        digestInput[0] = 0x7f
        assertContentEquals(digestBefore, digestRequest.digest.toByteArray())

        val rInput = ByteArray(32) { it.toByte() }
        val sInput = ByteArray(32) { (it + 1).toByte() }
        val signature = CompactEs256kSignature(rInput, sInput)
        val signatureBefore = signature.toByteArray()
        rInput[0] = 0x7f
        sInput[0] = 0x7f
        assertContentEquals(signatureBefore, signature.toByteArray())
    }

    @Test
    fun malformedObservedRpidBytesReachTypedIneligibility() {
        val root = Json.parseToJsonElement(
            readVectorResource("vectors/positive/mutual-sensing-window-v1.json"),
        ).jsonObject
        val source = root.getValue("cases").jsonArray.first().jsonObject
            .getValue("input").jsonObject.toEvidence()
        val malformed = listOf(ImmutableBytes(ByteArray(16) { 1 }))
        val result = prepareMutualSensingObservation(source.copy(observedRpids = malformed))

        assertEquals(
            ObservationIneligibilityCode.MALFORMED_OBSERVED_RPID,
            (result as ObservationPreparationResult.Ineligible).code,
        )
    }

    @Test
    fun nonAsciiParticipantCommitmentIsMalformed() {
        val root = Json.parseToJsonElement(
            readVectorResource("vectors/positive/mutual-sensing-window-v1.json"),
        ).jsonObject
        val source = root.getValue("cases").jsonArray.first().jsonObject
            .getValue("input").jsonObject.toEvidence()
        val result = prepareMutualSensingObservation(
            source.copy(participantCommitmentHex = "١".repeat(64)),
        )

        assertEquals(
            ObservationIneligibilityCode.MALFORMED_PARTICIPANT_COMMITMENT,
            (result as ObservationPreparationResult.Ineligible).code,
        )
    }
}

private fun JsonObject.toEvidence(): MutualSensingWindowEvidence = MutualSensingWindowEvidence(
    id = UuidBytes16(getValue("idHex").jsonPrimitive.content.hexToBytes()),
    eventId = ByteString32(getValue("eventIdHex").jsonPrimitive.content.hexToBytes()),
    eventDefinitionDigest = ByteString32(
        getValue("eventDefinitionDigestHex").jsonPrimitive.content.hexToBytes(),
    ),
    observer = CompressedSecp256k1PublicKey(
        getValue("observerHex").jsonPrimitive.content.hexToBytes(),
    ),
    finalizedAt = getValue("finalizedAt").jsonPrimitive.double,
    reporterRpid = BarnardRpid17(getValue("reporterRpidHex").jsonPrimitive.content.hexToBytes()),
    enin = ProtocolUInt(getValue("enin").jsonPrimitive.long),
    observedRpids = get("observedRpidsHex")?.jsonArray?.map {
        ImmutableBytes(it.jsonPrimitive.content.hexToBytes())
    },
    rpidClaim = getValue("rpidClaimHex").jsonPrimitive.contentOrNull?.hexToBytes()?.let(::ImmutableBytes),
    participantCommitmentHex = getValue("participantCommitmentHex").jsonPrimitive.contentOrNull,
    legacyPeerCount = get("legacyPeerCount")?.jsonPrimitive?.long,
)

private fun MutualSensingPayloadV1.encodeCanonicalBytesForTest(): ByteArray = CanonicalCbor.encode(
    CanonicalCbor.map(
        CanonicalCbor.uint(1) to CanonicalCbor.bytes(eventDefinitionDigest.toByteArray()),
        CanonicalCbor.uint(2) to CanonicalCbor.uint(enin.value),
        CanonicalCbor.uint(3) to CanonicalCbor.array(
            observedRpids.map { CanonicalCbor.bytes(it.toByteArray()) },
        ),
        CanonicalCbor.uint(4) to (rpidClaim?.let { CanonicalCbor.bytes(it.toByteArray()) }
            ?: CanonicalCbor.nullValue()),
        CanonicalCbor.uint(5) to (participantCommitment?.let { CanonicalCbor.bytes(it.toByteArray()) }
            ?: CanonicalCbor.nullValue()),
    ),
)

private fun ObservationV1.encodeCanonicalBytesForTest(): ByteArray = CanonicalCbor.encode(
    CanonicalCbor.map(
        CanonicalCbor.uint(1) to CanonicalCbor.uint(version.toLong()),
        CanonicalCbor.uint(2) to CanonicalCbor.bytes(id.toByteArray()),
        CanonicalCbor.uint(3) to CanonicalCbor.text(profile),
        CanonicalCbor.uint(4) to CanonicalCbor.bytes(context.toByteArray()),
        CanonicalCbor.uint(5) to CanonicalCbor.bytes(observer.toByteArray()),
        CanonicalCbor.uint(6) to CanonicalCbor.uint(observedAt.value),
        CanonicalCbor.uint(7) to CanonicalCbor.bytes(subject.toByteArray()),
        CanonicalCbor.uint(8) to CanonicalCbor.bytes(payload.toByteArray()),
    ),
)

private fun String.hexToBytes(): ByteArray {
    require(length % 2 == 0) { "hex must have an even number of digits" }
    return ByteArray(length / 2) { index ->
        substring(index * 2, index * 2 + 2).toInt(16).toByte()
    }
}
