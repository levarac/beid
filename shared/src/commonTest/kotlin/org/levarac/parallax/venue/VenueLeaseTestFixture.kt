package org.levarac.parallax.venue

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import org.levarac.parallax.registry.RegistryCacheKey
import org.levarac.parallax.registry.RegistryDefinitionRecord
import org.levarac.parallax.registry.RegistryEventContext
import org.levarac.parallax.registry.RegistryRegistration
import org.levarac.parallax.registry.RegistryResolution
import org.levarac.parallax.registry.decodeHex
import org.levarac.parallax.registry.readEventDefinitionVector
import org.levarac.parallax.registry.requiredLong
import org.levarac.parallax.registry.requiredString
import org.levarac.parallax.registry.toPrefixedHex

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

// Current-lease helpers. These deliberately duplicate the private helpers in
// VenueBundleIdentityTest rather than moving them: relocating those would edit
// an existing test file during a RED, which shifts the measured baseline the
// RED's pre-registered totals are stated against.

internal const val VENUE_LEASE_BLOCK_HASH: String =
    "0x2222222222222222222222222222222222222222222222222222222222222222"

internal const val VENUE_LEASE_ZERO_DIGEST: String =
    "0x0000000000000000000000000000000000000000000000000000000000000000"

internal fun venueLeasePair(mode: String = "authorityDirect"): Pair<VenueBundle, VenueHandoff> {
    val case = venueLeaseVector().getValue(mode).jsonObject
    return requireNotNull(decodeVenueBundle(case.requiredString("bundleHex").decodeHex())) to
        requireNotNull(decodeVenueHandoff(case.requiredString("handoffHex").decodeHex()))
}

internal fun venueLeaseResolution(
    bundle: VenueBundle,
    context: RegistryEventContext = venueLeaseVector().venueRegistryContext(),
): RegistryResolution {
    val digest = context.latestDefinitionDigestHex ?: VENUE_LEASE_ZERO_DIGEST
    val key = RegistryCacheKey(
        chainId = 11_155_111,
        registryAddressHex = "0x" + venueLeaseVector().requiredString("readerAddressHex"),
        eventIdHex = bundle.eventId.toByteArray().toPrefixedHex(),
        definitionHashHex = digest,
        blockNumber = 42,
        blockHashHex = VENUE_LEASE_BLOCK_HASH,
    )
    return RegistryResolution(true, context, 42, VENUE_LEASE_BLOCK_HASH, digest, null, null, key)
}

/** A really-verified identity, built through the production entrypoint rather than hand-assembled. */
internal fun venueLeaseIdentity(
    mode: String = "authorityDirect",
    context: RegistryEventContext = venueLeaseVector().venueRegistryContext(),
): VenueBundleIdentity {
    val (bundle, handoff) = venueLeasePair(mode)
    val check = verifyVenueBundleIdentity(bundle, handoff, venueLeaseResolution(bundle, context))
    return requireNotNull(check.identity) { "fixture identity must verify, got ${check.failureCode}" }
}

/** Scheduling exactly as the fixture's signed envelope declares it. */
internal fun venueLeaseScheduling(
    validFromEnin: Long = venueLeaseVector().requiredLong("signedValidFromEnin"),
    validThroughEnin: Long = venueLeaseVector().requiredLong("signedValidThroughEnin"),
    relayExpiresAtEnin: Long = venueLeaseVector().requiredLong("signedRelayExpiresAtEnin"),
    eninSeconds: Int = venueLeaseVector().requiredLong("eninSeconds").toInt(),
    verifiedAtEnin: Long = venueLeaseVector().requiredLong("currentEnin"),
): VenueVerifiedScheduling = VenueVerifiedScheduling(
    validFromEnin, validThroughEnin, relayExpiresAtEnin, eninSeconds, verifiedAtEnin,
)

internal fun venueLeaseCurrentEnin(): Long = venueLeaseVector().requiredLong("currentEnin")

internal fun venueLeaseClockSeconds(): Long = venueLeaseVector().requiredLong("currentEpochSeconds")
