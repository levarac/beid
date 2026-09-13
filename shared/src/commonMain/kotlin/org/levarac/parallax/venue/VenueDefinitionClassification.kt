package org.levarac.parallax.venue

import org.levarac.parallax.registry.EventDefinition
import org.levarac.parallax.registry.EventJoinMode
import org.levarac.parallax.registry.decodeHex

/**
 * What a venue serving path has to work with, given one anchored Event
 * Definition's join declaration.
 *
 * Every case is named for the INPUT it describes, never for what some host
 * version happens to support today. "This build does not serve gated events"
 * is a fact about a phase and would have to be walked back when that phase
 * ends; "a gated definition carries no eventCodeHash" is a fact about the
 * protocol and stays true forever. Only the second kind belongs in a shared
 * contract. See [GATED_REQUIRES_EXTERNAL_HASH].
 *
 * This is deliberately NOT a seventh `VenueBundleIdentityCheck` failure code.
 * A gated bundle is identity-sound — its handoff, deployment, anchored record
 * and signature all verify — and `VenueCurrentLease` next door records why
 * published identity behaviour must not be changed inside a change that is
 * meant to add serving readiness. This is additive and separate.
 */
public enum class VenueDefinitionClassification {
    /**
     * An open event whose definition carries the canonical 8-byte
     * `eventCodeHash`. Everything a B005 envelope must be compared against is
     * present in the definition itself.
     */
    OPEN_WITH_EVENT_CODE_HASH,

    /**
     * A gated event. `EventDefinitionCborCodec` FORBIDS a gated definition
     * from carrying an `eventCodeHash` at all, so the hash a B005 envelope has
     * to be compared against cannot come from the definition and must be
     * supplied from outside it.
     *
     * This says where the input has to come from. It does not say that gated
     * events are unsupported: a host that gains an external-hash input serves
     * these, and this case stays exactly as true then as it is now.
     */
    GATED_REQUIRES_EXTERNAL_HASH,

    /**
     * No join declaration this version can act on.
     *
     * Reachable for legacy key-1-through-13 definitions, which carry no
     * `joinMode` at all by construction (see [EventDefinition.joinMode]). It
     * is also where an open definition with an absent or wrong-length hash
     * lands, fail-closed. That second shape is unreachable through the codec,
     * which rejects it before trust, but a classification that assumed so
     * would be asserting a cross-file invariant this function cannot enforce
     * on its own.
     */
    NO_USABLE_JOIN_DECLARATION,
}

/**
 * Classify one anchored definition's join declaration.
 *
 * Pure and clock-free: it reads only [EventDefinition.joinMode] and
 * [EventDefinition.eventCodeHashHex], both of which the codec has already
 * verified as covered by the definition's signature.
 */
public fun classifyVenueDefinition(definition: EventDefinition): VenueDefinitionClassification {
    return when (definition.joinMode) {
        EventJoinMode.GATED -> VenueDefinitionClassification.GATED_REQUIRES_EXTERNAL_HASH
        EventJoinMode.OPEN -> {
            val eventCodeHashHex = definition.eventCodeHashHex
            if (eventCodeHashHex != null && eventCodeHashHex.isEventCodeHash()) {
                VenueDefinitionClassification.OPEN_WITH_EVENT_CODE_HASH
            } else {
                // The codec requires an open definition to carry the canonical
                // 8-byte hash and rejects any other shape before trust, so this
                // is not expected to be reachable. It is still written rather
                // than assumed away: that requirement lives in another file and
                // this function cannot enforce it.
                VenueDefinitionClassification.NO_USABLE_JOIN_DECLARATION
            }
        }
        null -> VenueDefinitionClassification.NO_USABLE_JOIN_DECLARATION
    }
}

/**
 * The hash is 8 bytes, checked by decoding rather than by counting characters,
 * so a non-hex string is rejected too. Same shape as the private helpers in
 * [verifyVenueBundleIdentity], which also decode-to-compare rather than trust
 * a string's length.
 */
private fun String.isEventCodeHash(): Boolean = try {
    decodeHex(EVENT_CODE_HASH_BYTES)
    true
} catch (_: IllegalArgumentException) {
    false
}

private const val EVENT_CODE_HASH_BYTES: Int = 8
