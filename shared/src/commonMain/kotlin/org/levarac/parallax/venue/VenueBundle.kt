package org.levarac.parallax.venue

import org.levarac.parallax.observation.ByteString32
import org.levarac.parallax.observation.ImmutableBytes
import org.levarac.parallax.registry.Address20

/**
 * Shape-checked venue artifacts (Parallax venue-bundle v0.1).
 * Decoding does not authenticate an artifact or authorize serving it.
 * Constructors are internal; byte values crossing a native boundary are defensive copies.
 */
public class VenueBundle internal constructor(
    public val chainId: Long,
    public val eventRegistry: Address20,
    public val eventDefinitionRegistry: Address20,
    public val eventId: ByteString32,
    public val definitionSequence: Long,
    public val definitionDigest: ByteString32,
    public val signedEventDefinition: ImmutableBytes,
    public val eventKeySet: ImmutableBytes,
    envelopes: List<ByteArray>,
    public val bundleDigest: ByteString32,
) {
    init {
        require(envelopes.size in 1..MAX_VENUE_ENVELOPES)
        require(envelopes.all { it.size in MIN_VENUE_ENVELOPE_BYTES..MAX_VENUE_ENVELOPE_BYTES })
    }

    private val envelopeBytes = envelopes.map { it.copyOf() }

    public val envelopeCount: Int
        get() = envelopeBytes.size

    public fun envelopeAt(index: Int): ByteArray? = envelopeBytes.getOrNull(index)?.copyOf()
}

/** Expected coordinates supplied independently of the bundle and its hosting server. */
public class VenueHandoff internal constructor(
    public val eventId: ByteString32,
    public val chainId: Long,
    public val eventRegistry: Address20,
    public val eventDefinitionRegistry: Address20,
    public val bundleDigest: ByteString32,
    public val bundleUrl: String?,
)

internal const val MAX_VENUE_ENVELOPES: Int = 512
internal const val MIN_VENUE_ENVELOPE_BYTES: Int = 199
internal const val MAX_VENUE_ENVELOPE_BYTES: Int = 508
