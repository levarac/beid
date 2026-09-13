package org.levarac.parallax.registry

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import org.levarac.parallax.observation.readVectorResource

/** Test-only view of the canonical Parallax JSON vector; no local schema builder is permitted. */
internal fun readEventDefinitionVector(path: String): JsonObject =
    Json.parseToJsonElement(readVectorResource(path)).jsonObject

internal fun JsonObject.requiredString(name: String): String =
    getValue(name).jsonPrimitive.content

internal fun JsonObject.requiredLong(name: String): Long =
    getValue(name).jsonPrimitive.long

internal fun String.vectorHexBytes(): ByteArray = decodeHex()

internal fun JsonObject.anchorRegistration(): RegistryRegistration {
    val value = getValue("anchorRegistration").jsonObject
    return RegistryRegistration(
        registrarHex = "0x" + value.requiredString("registrarHex"),
        operatorHex = "0x" + value.requiredString("operatorHex"),
        keySetDigestHex = "0x" + value.requiredString("keySetDigestHex"),
        registeredAt = value.requiredLong("registeredAt"),
    )
}

internal fun JsonObject.definitionRecord(name: String = "definitionAnchor"): RegistryDefinitionRecord {
    val value = getValue(name).jsonObject
    return RegistryDefinitionRecord(
        sequence = value.requiredLong("sequence"),
        previousDefinitionDigestHex = "0x" + value.requiredString("previousDefinitionDigestHex"),
        definitionDigestHex = "0x" + value.requiredString("definitionDigestHex"),
        validFrom = value.requiredLong("validFrom"),
        validUntil = value.requiredLong("validUntil"),
        anchoredAt = value.requiredLong("anchoredAt"),
    )
}

internal fun JsonObject.vectorEventId(): ByteArray =
    getValue("anchorRegistration").jsonObject.requiredString("eventIdHex").vectorHexBytes()

/**
 * The signed event-definition-v1 vectors that carry a join mode, and their anchored digests.
 *
 * These live here rather than inside one test class because two packages verify against the
 * same bytes: the codec's own decode tests, and the venue definition classification, which
 * must be exercised on real codec output rather than on a hand-built definition. One copy,
 * so a regenerated vector cannot update one caller and leave the other asserting the old
 * bytes.
 */
internal const val GATED_DEFINITION_DIGEST_HEX =
    "8c3cee30c9bdd2982d3c6a3e19e0c71543e7e558c9f2af066238b8e39e66c100"
internal const val GATED_SIGNED_DEFINITION_HEX =
    "d284583ea301382e03782d6170706c69636174696f6e2f766e642e6c6576617261632e6576656e742d646566696e6974696f6e2b63626f720448f5df3c6eefaf5217a059013dae01010258205d5891b92a9a6597aa2c58586fd2fdf3974f40f732b9a319ec9f3fc4d7ab319503541111111111111111111111111111111111111111045422222222222222222222222222222222222222220558203333333333333333333333333333333333333333333333333333333333333333065820cba59e50c7666ef2468a14f2e53f04decfd078933cd245a9a2d77532eb23b7000701085820000000000000000000000000000000000000000000000000000000000000000009582102c6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee50a582050d8f3689f95e95c30be32dc4e516460dff139c088ab1117af0c1041882529490b782868747470733a2f2f6f70657261746f722e6578616d706c652f76312f6f62736572766174696f6e730c1a6b49d19c0d1a6b4b23800e0158402fe1ac328efc01dfa6e728171d6aff971fee83be06a71b4a92496f3926cc741e30e805dd27f66640976d68367a0d638a53e7c32a8d4d32c6deb1016ac99332bb"
internal const val OPEN_DEFINITION_DIGEST_HEX =
    "534c58ee5752f3835863892eee4388ac99b2ecec8ef1287efb902d179e454026"
internal const val OPEN_SIGNED_DEFINITION_HEX =
    "d284583ea301382e03782d6170706c69636174696f6e2f766e642e6c6576617261632e6576656e742d646566696e6974696f6e2b63626f720448f5df3c6eefaf5217a0590147af01010258205d5891b92a9a6597aa2c58586fd2fdf3974f40f732b9a319ec9f3fc4d7ab319503541111111111111111111111111111111111111111045422222222222222222222222222222222222222220558203333333333333333333333333333333333333333333333333333333333333333065820cba59e50c7666ef2468a14f2e53f04decfd078933cd245a9a2d77532eb23b7000701085820000000000000000000000000000000000000000000000000000000000000000009582102c6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee50a582050d8f3689f95e95c30be32dc4e516460dff139c088ab1117af0c1041882529490b782868747470733a2f2f6f70657261746f722e6578616d706c652f76312f6f62736572766174696f6e730c1a6b49d19c0d1a6b4b23800e000f489adc61d60dda843e584057ed6756de81dd41140f2606dee0893c16aac6d8d6df90f29037a785641cb0c7385acd9190cf092af925865d6548601174a8f878d25e1b9b3b1f6f0f44d38c38"

internal fun verifyExtendedDefinition(
    vector: kotlinx.serialization.json.JsonObject,
    signedHex: String,
    digestHex: String,
): EventDefinitionCborCodec.VerifiedDefinition {
    val legacyRecord = vector.definitionRecord()
    val record = RegistryDefinitionRecord(
        sequence = legacyRecord.sequence,
        previousDefinitionDigestHex = legacyRecord.previousDefinitionDigestHex,
        definitionDigestHex = digestHex,
        validFrom = legacyRecord.validFrom,
        validUntil = legacyRecord.validUntil,
        anchoredAt = legacyRecord.anchoredAt,
    )
    return EventDefinitionCborCodec.verify(
        signedBytes = signedHex.vectorHexBytes(),
        encodedKeySet = vector.requiredString("eventKeySetHex").vectorHexBytes(),
        eventId = vector.vectorEventId(),
        registration = vector.anchorRegistration(),
        record = record,
        at = record.validFrom,
    )
}
