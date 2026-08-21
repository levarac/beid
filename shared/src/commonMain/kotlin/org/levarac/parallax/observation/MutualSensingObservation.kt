package org.levarac.parallax.observation

import kotlin.math.floor

public fun prepareMutualSensingObservation(
    evidence: MutualSensingWindowEvidence,
): ObservationPreparationResult {
    if (evidence.observedRpids == null) {
        return ObservationPreparationResult.Ineligible(
            if (evidence.legacyPeerCount != null) {
                ObservationIneligibilityCode.LEGACY_COUNT_ONLY
            } else {
                ObservationIneligibilityCode.MISSING_OBSERVED_RPID_SET
            },
        )
    }

    val participantCommitment = when (val source = evidence.participantCommitmentHex) {
        null -> null
        else -> parseParticipantCommitment(source)
            ?: return ObservationPreparationResult.Ineligible(
                ObservationIneligibilityCode.MALFORMED_PARTICIPANT_COMMITMENT,
            )
    }

    if (!hasRpidFormatVersion(evidence.reporterRpid)) {
        return ObservationPreparationResult.Ineligible(ObservationIneligibilityCode.MALFORMED_REPORTER_RPID)
    }
    if (!isValidUnixSeconds(evidence.finalizedAt) ||
        !Secp256k1.isValidCompressedPublicKey(evidence.observer.toByteArray())
    ) {
        return ObservationPreparationResult.Ineligible(ObservationIneligibilityCode.INVALID_WINDOW_INPUT)
    }

    val sortedRpids = ArrayList<BarnardRpid17>(evidence.observedRpids.size)
    val seen = HashSet<String>()
    for (rpid in evidence.observedRpids) {
        if (!hasRpidFormatVersion(rpid)) {
            return ObservationPreparationResult.Ineligible(ObservationIneligibilityCode.MALFORMED_OBSERVED_RPID)
        }
        val key = rpid.toByteArray().toHex()
        if (!seen.add(key)) {
            return ObservationPreparationResult.Ineligible(ObservationIneligibilityCode.DUPLICATE_OBSERVED_RPID)
        }
        sortedRpids += rpid
    }
    sortedRpids.sortWith { left, right -> compareBytes(left.toByteArray(), right.toByteArray()) }

    return try {
        val observedAt = ProtocolUInt(floor(evidence.finalizedAt).toLong())
        val payload = MutualSensingPayloadV1(
            eventDefinitionDigest = evidence.eventDefinitionDigest,
            enin = evidence.enin,
            observedRpids = sortedRpids,
            rpidClaim = evidence.rpidClaim,
            participantCommitment = participantCommitment,
        )
        val encodedPayload = CanonicalCbor.encode(
            CanonicalCbor.map(
                CanonicalCbor.uint(1) to CanonicalCbor.bytes(payload.eventDefinitionDigest.toByteArray()),
                CanonicalCbor.uint(2) to CanonicalCbor.uint(payload.enin.value),
                CanonicalCbor.uint(3) to CanonicalCbor.array(
                    payload.observedRpids.map { CanonicalCbor.bytes(it.toByteArray()) },
                ),
                CanonicalCbor.uint(4) to (payload.rpidClaim?.let { CanonicalCbor.bytes(it.toByteArray()) }
                    ?: CanonicalCbor.nullValue()),
                CanonicalCbor.uint(5) to (payload.participantCommitment?.let {
                    CanonicalCbor.bytes(it.toByteArray())
                } ?: CanonicalCbor.nullValue()),
            ),
        )
        val observation = ObservationV1(
            version = 1,
            id = evidence.id,
            profile = OBSERVATION_PROFILE,
            context = evidence.eventId,
            observer = evidence.observer,
            observedAt = observedAt,
            subject = evidence.reporterRpid,
            payload = ImmutableBytes(encodedPayload),
        )
        val observationCbor = CanonicalCbor.encode(
            CanonicalCbor.map(
                CanonicalCbor.uint(1) to CanonicalCbor.uint(observation.version.toLong()),
                CanonicalCbor.uint(2) to CanonicalCbor.bytes(observation.id.toByteArray()),
                CanonicalCbor.uint(3) to CanonicalCbor.text(observation.profile),
                CanonicalCbor.uint(4) to CanonicalCbor.bytes(observation.context.toByteArray()),
                CanonicalCbor.uint(5) to CanonicalCbor.bytes(observation.observer.toByteArray()),
                CanonicalCbor.uint(6) to CanonicalCbor.uint(observation.observedAt.value),
                CanonicalCbor.uint(7) to CanonicalCbor.bytes(observation.subject.toByteArray()),
                CanonicalCbor.uint(8) to CanonicalCbor.bytes(observation.payload.toByteArray()),
            ),
        )
        val protectedHeaders = CanonicalCbor.encode(
            CanonicalCbor.map(
                CanonicalCbor.uint(1) to CanonicalCbor.negative(-47),
                CanonicalCbor.uint(3) to CanonicalCbor.text(OBSERVATION_CONTENT_TYPE),
                CanonicalCbor.uint(4) to CanonicalCbor.bytes(coseKeyId(evidence.observer)),
            ),
        )
        val sigStructure = CanonicalCbor.encode(
            CanonicalCbor.array(
                CanonicalCbor.text("Signature1"),
                CanonicalCbor.bytes(protectedHeaders),
                CanonicalCbor.bytes(ByteArray(0)),
                CanonicalCbor.bytes(observationCbor),
            ),
        )
        ObservationPreparationResult.Eligible(
            PreparedObservationV1(
                observation = observation,
                observationPayload = payload,
                observationCbor = ObservationCborBytes(observationCbor),
                protectedHeaders = ImmutableBytes(protectedHeaders),
                sigStructure = SigStructureBytes(sigStructure),
                sha256Digest = Sha256Digest(Sha256.digest(sigStructure)),
            ),
        )
    } catch (_: IllegalArgumentException) {
        ObservationPreparationResult.Ineligible(ObservationIneligibilityCode.INVALID_WINDOW_INPUT)
    }
}

public fun prepareObservationV1(
    evidence: MutualSensingWindowEvidence,
): ObservationPreparationResult = prepareMutualSensingObservation(evidence)

private fun parseParticipantCommitment(value: String): ByteString32? {
    if (value.length != 64 || value.any { it.digitToIntOrNull(16) == null }) return null
    return ByteString32(ByteArray(32) { index -> value.substring(index * 2, index * 2 + 2).toInt(16).toByte() })
}

private fun hasRpidFormatVersion(rpid: BarnardRpid17): Boolean =
    rpid.toByteArray().firstOrNull()?.toInt()?.and(0xff) == 1

private fun isValidUnixSeconds(value: Double): Boolean =
    value.isFinite() && value >= 0.0 && value <= PROTOCOL_SAFE_UINT_MAX.toDouble()

private fun compareBytes(left: ByteArray, right: ByteArray): Int {
    val common = minOf(left.size, right.size)
    for (index in 0 until common) {
        val comparison = (left[index].toInt() and 0xff) - (right[index].toInt() and 0xff)
        if (comparison != 0) return comparison
    }
    return left.size - right.size
}

private fun coseKeyId(publicKey: CompressedSecp256k1PublicKey): ByteArray =
    Sha256.digest("levarac:cose-kid:v1".encodeToByteArray() + byteArrayOf(0) + publicKey.toByteArray())
        .copyOfRange(0, 8)
