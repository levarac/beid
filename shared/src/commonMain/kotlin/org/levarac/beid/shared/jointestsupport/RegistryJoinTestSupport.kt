package org.levarac.beid.shared.jointestsupport

import org.levarac.parallax.observation.ByteString32
import org.levarac.parallax.observation.CompressedSecp256k1PublicKey
import org.levarac.parallax.observation.ProtocolUInt
import org.levarac.parallax.registry.Address20
import org.levarac.parallax.registry.EventDefinition
import org.levarac.parallax.registry.EventDefinitionContext
import org.levarac.parallax.registry.EventDefinitionResolution
import org.levarac.parallax.registry.EventJoinMode
import org.levarac.parallax.registry.RegistryDefinitionRecord

/**
 * A registry answer that the beid#410 join gate accepts, for tests only.
 *
 * ## Why this exists
 *
 * Until this function, **no test in this repository could drive the join gate
 * to admit.** Every gate test asserted the refusing half (`didJoin == false`),
 * because the admitting half was unreachable: `EventDefinitionResolution`,
 * `EventDefinitionContext`, `EventDefinition` and `RegistryDefinitionRecord`
 * all have `internal` constructors, so a Swift test could not build one, and
 * the only other source of a resolution is a live registry read over the
 * network. The gate that decides *when a device may switch its radio on* was
 * therefore tested exclusively on the paths where it says no.
 *
 * It surfaced from the other direction (beid#473): five
 * `ReportSubmissionOperatorIntegrationTests` were entering a sensing session
 * through a defect — the Simulator has no BLE radio, refuses the permission
 * grant, and `startSensing` did not undo its optimistic `.sensing` phase — so
 * the defect could not be fixed without first making a legitimate session
 * reachable from a test.
 *
 * ## What it is not
 *
 * This does not sign, verify, or decode anything, and it is not a second
 * implementation of the gate: it assembles the *input* the gate reads and
 * leaves every decision to [org.levarac.parallax.discovery.
 * operatorLookupJoinEligibility]. A test that wants a refusal should pass
 * values the gate rejects (a validity window that excludes `now`, a
 * [EventJoinMode.GATED] definition, a blank hash) rather than reaching for a
 * different builder — that is the point of routing through the real decision.
 *
 * The cryptographic fields are fixed filler. Nothing in the join decision
 * inspects them, and a test that needs a real key, a real digest or real
 * signed bytes must not use this function.
 *
 * @param eventIdHex 32-byte event id, with or without the `0x` prefix.
 * @param definitionHashHex 32-byte definition digest the resolution reports.
 * @param blockHashHex 32-byte registry block hash the resolution reports.
 * @param validFromEpochSeconds inclusive start of the definition's validity.
 * @param validUntilEpochSeconds inclusive end of the definition's validity.
 * @param joinMode [EventJoinMode.OPEN] admits; [EventJoinMode.GATED] is
 *   refused by the gate, which is how a test covers that branch.
 */
public fun createEventDefinitionResolutionForTesting(
    eventIdHex: String,
    definitionHashHex: String,
    blockHashHex: String,
    validFromEpochSeconds: Long,
    validUntilEpochSeconds: Long,
    joinMode: EventJoinMode = EventJoinMode.OPEN,
): EventDefinitionResolution {
    val eventId = ByteString32(eventIdHex.testSupportHexBytes(expectedBytes = 32))
    val definition = EventDefinition(
        version = 1,
        eventId = eventId,
        registrar = Address20(ByteArray(20)),
        anchorOperator = Address20(ByteArray(20)),
        nonce = ByteString32(ByteArray(32)),
        keySetDigest = ByteString32(ByteArray(32)),
        sequence = ProtocolUInt(1L),
        previousDefinitionDigest = ByteString32(ByteArray(32)),
        receiptPublicKey = CompressedSecp256k1PublicKey(filler33Bytes()),
        operatorId = ByteString32(ByteArray(32)),
        submissionEndpoint = "https://example.invalid/submit",
        validFrom = ProtocolUInt(validFromEpochSeconds),
        validUntil = ProtocolUInt(validUntilEpochSeconds),
        authorityPublicKey = CompressedSecp256k1PublicKey(filler33Bytes()),
        joinMode = joinMode,
    )
    val record = RegistryDefinitionRecord(
        sequence = 1L,
        previousDefinitionDigestHex = ZERO_32_HEX,
        definitionDigestHex = definitionHashHex,
        validFrom = validFromEpochSeconds,
        validUntil = validUntilEpochSeconds,
        anchoredAt = validFromEpochSeconds,
    )
    return EventDefinitionResolution(
        isSuccess = true,
        context = EventDefinitionContext(
            eventIdHex = eventIdHex,
            definitionHashHex = definitionHashHex,
            selectedAt = validFromEpochSeconds,
            record = record,
            definition = definition,
        ),
        blockNumber = 1L,
        blockHashHex = blockHashHex,
        definitionHashHex = definitionHashHex,
        errorCode = null,
        errorMessage = null,
    )
}

private const val ZERO_32_HEX = "0x0000000000000000000000000000000000000000000000000000000000000000"

/**
 * A well-formed compressed secp256k1 key *shape*. `0x02` is a real prefix and
 * the remaining bytes are filler; this is never used as a key.
 */
private fun filler33Bytes(): ByteArray = ByteArray(33).also { it[0] = 0x02 }

/**
 * Local hex decoder. The registry module's own `decodeHex` is `internal` to
 * that package's file set, and reaching for it here would tie this test seam
 * to a private helper it does not own.
 */
private fun String.testSupportHexBytes(expectedBytes: Int): ByteArray {
    val body = removePrefix("0x").removePrefix("0X")
    require(body.length == expectedBytes * 2) {
        "expected $expectedBytes bytes of hex, got ${body.length} characters"
    }
    return ByteArray(expectedBytes) { index ->
        val high = body[index * 2].hexDigitValue()
        val low = body[index * 2 + 1].hexDigitValue()
        ((high shl 4) or low).toByte()
    }
}

private fun Char.hexDigitValue(): Int = when (this) {
    in '0'..'9' -> this - '0'
    in 'a'..'f' -> this - 'a' + 10
    in 'A'..'F' -> this - 'A' + 10
    else -> throw IllegalArgumentException("not a hex digit: $this")
}
