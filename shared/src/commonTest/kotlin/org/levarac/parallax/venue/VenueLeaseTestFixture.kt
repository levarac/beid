package org.levarac.parallax.venue

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import org.levarac.parallax.registry.RegistryDefinitionRecord
import org.levarac.parallax.registry.RegistryEventContext
import org.levarac.parallax.registry.RegistryRegistration
import org.levarac.parallax.registry.readEventDefinitionVector
import org.levarac.parallax.registry.requiredLong
import org.levarac.parallax.registry.requiredString

internal fun venueLeaseVector(): JsonObject =
    readEventDefinitionVector("vectors/positive/venue-current-lease-v1.json")

internal fun JsonObject.venueRegistration(): RegistryRegistration = getValue("registration").jsonObject.let {
    RegistryRegistration(
        registrarHex = it.requiredString("registrarHex"),
        operatorHex = it.requiredString("operatorHex"),
        keySetDigestHex = it.requiredString("keySetDigestHex"),
        registeredAt = it.requiredLong("registeredAt"),
    )
}

internal fun JsonObject.venueDefinitionRecord(): RegistryDefinitionRecord =
    getValue("definitionRecord").jsonObject.let {
        RegistryDefinitionRecord(
            sequence = it.requiredLong("sequence"),
            previousDefinitionDigestHex = it.requiredString("previousDefinitionDigestHex"),
            definitionDigestHex = it.requiredString("definitionDigestHex"),
            validFrom = it.requiredLong("validFrom"),
            validUntil = it.requiredLong("validUntil"),
            anchoredAt = it.requiredLong("anchoredAt"),
        )
    }

internal fun JsonObject.venueRegistryContext(): RegistryEventContext = RegistryEventContext(
    schemaVersion = 1,
    registration = venueRegistration(),
    definitionState = 1,
    latestSequence = 1,
    definitions = listOf(venueDefinitionRecord()),
)
