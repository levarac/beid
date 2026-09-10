package org.levarac.parallax.venue

import org.levarac.parallax.registry.EventDefinition
import org.levarac.parallax.registry.EventDefinitionCborCodec
import org.levarac.parallax.registry.DefinitionDecodeException
import org.levarac.parallax.registry.RegistryCacheKey
import org.levarac.parallax.registry.RegistryEventContext
import org.levarac.parallax.registry.RegistryResolution
import org.levarac.parallax.registry.SEPOLIA_CHAIN_ID
import org.levarac.parallax.registry.decodeHex

/**
 * The handoff, configured chain source and signed definition agree.
 * This does not verify B005 envelopes, schedule coverage or permission to serve.
 * Import has no clock input; current-definition selection belongs to lease eligibility.
 */
public class VenueBundleIdentity internal constructor(
    public val bundle: VenueBundle,
    public val definition: EventDefinition,
    public val readKey: RegistryCacheKey,
    internal val registryContext: RegistryEventContext,
)

public class VenueBundleIdentityCheck internal constructor(
    public val identity: VenueBundleIdentity?,
    public val failureCode: String?,
)

/** No signature work is reachable without the decoder's bounded [VenueBundle]. */
public fun verifyVenueBundleIdentity(
    bundle: VenueBundle,
    handoff: VenueHandoff,
    registry: RegistryResolution,
): VenueBundleIdentityCheck {
    if (bundle.chainId != handoff.chainId ||
        bundle.eventId != handoff.eventId ||
        bundle.eventRegistry != handoff.eventRegistry ||
        bundle.eventDefinitionRegistry != handoff.eventDefinitionRegistry ||
        bundle.bundleDigest != handoff.bundleDigest
    ) return VenueBundleIdentityCheck(null, "handoff_mismatch")

    // Agreement between two untrusted artifacts does not choose a deployment.
    // This reader's immutable registry pair is the configured Sepolia deployment
    // documented at Parallax 6fe165f, contracts/docs/sepolia-deploy.md.
    if (bundle.chainId != SEPOLIA_CHAIN_ID ||
        !SEPOLIA_EVENT_REGISTRY.matchesBytes(bundle.eventRegistry.toByteArray()) ||
        !SEPOLIA_DEFINITION_REGISTRY.matchesBytes(bundle.eventDefinitionRegistry.toByteArray())
    ) return VenueBundleIdentityCheck(null, "deployment_mismatch")

    val context = registry.context
    val source = registry.readKey
    if (!registry.isSuccess || context == null || source == null) {
        return VenueBundleIdentityCheck(null, "registry_unavailable")
    }
    if (source.chainId != bundle.chainId ||
        !SEPOLIA_READER.sameHex(source.registryAddressHex, 20) ||
        !source.eventIdHex.matchesBytes(bundle.eventId.toByteArray()) ||
        source.blockNumber != registry.blockNumber ||
        !source.blockHashHex.sameHex(registry.blockHashHex, 32) ||
        !source.definitionHashHex.sameHex(registry.definitionHashHex, 32)
    ) return VenueBundleIdentityCheck(null, "registry_source_mismatch")

    // The cache key describes the latest record in the read. It is deliberately
    // NOT compared to this bundle's digest: an import may name an older record.
    val record = context.definitions.firstOrNull {
        it.sequence == bundle.definitionSequence &&
            it.definitionDigestHex.matchesBytes(bundle.definitionDigest.toByteArray())
    } ?: return VenueBundleIdentityCheck(null, "definition_not_registered")

    val verified = try {
        EventDefinitionCborCodec.verify(
            signedBytes = bundle.signedEventDefinition.toByteArray(),
            encodedKeySet = bundle.eventKeySet.toByteArray(),
            eventId = bundle.eventId.toByteArray(),
            registration = context.registration,
            record = record,
            // Validate the named definition at its own start, not the device
            // clock. Current-time selection is a separate serving decision.
            at = record.validFrom,
        )
    } catch (_: DefinitionDecodeException) {
        return VenueBundleIdentityCheck(null, "invalid_definition")
    }
    return VenueBundleIdentityCheck(VenueBundleIdentity(bundle, verified.definition, source, context), null)
}

private fun String.matchesBytes(expected: ByteArray): Boolean = try {
    decodeHex(expected.size).contentEquals(expected)
} catch (_: IllegalArgumentException) {
    false
}

private fun String.sameHex(other: String?, byteCount: Int): Boolean = try {
    other != null && decodeHex(byteCount).contentEquals(other.decodeHex(byteCount))
} catch (_: IllegalArgumentException) {
    false
}

private const val SEPOLIA_READER: String = "0xd4852f8526a1555a1b2c34145f0ecda412a53c51"
private const val SEPOLIA_EVENT_REGISTRY: String = "0x1284a559ce2e4ba7551a87a4fb66f34dcf9b0170"
private const val SEPOLIA_DEFINITION_REGISTRY: String = "0x1f2eb14790f1108a3e54d8eb3f65b89ad08ec400"
