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
