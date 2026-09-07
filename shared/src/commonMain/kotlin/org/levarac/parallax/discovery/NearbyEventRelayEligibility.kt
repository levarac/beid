// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

package org.levarac.parallax.discovery

/**
 * Why a signed envelope may or may not be re-broadcast by this device
 * (barnard spec 134 step 3, beid#367).
 *
 * The rejection cases are named rather than collapsed into a single `false`
 * because each one is a different operational story — an event this device is
 * not part of, an event whose registration this host could not confirm, or
 * bytes that are not the ones the confirmation was about — and a host that
 * cannot tell them apart cannot diagnose a venue where nothing ever relays.
 */
public enum class NearbyEventRelayEligibility {
    /** Every check passed: these exact bytes may be served back at hop + 1. */
    ELIGIBLE,

    /** This device is not joined to an event, so it relays nothing at all. */
    NOT_JOINED,

    /** Joined, but to a different event. One device relays one event. */
    OTHER_EVENT,

    /**
     * This host's own authenticated registry read has not (yet) confirmed the
     * event behind these bytes. `RADIO_SELF_VERIFIED` alone never relays.
     */
    NOT_REGISTRY_VERIFIED,

    /**
     * The hash is registry-verified, but the retained container for it is not
     * the envelope offered here. The confirmation is about specific bytes, and
     * it does not carry over to different ones sharing an event-code hash.
     */
    CONTAINER_MISMATCH,
}

/**
 * Decides whether one signed envelope is eligible for spec 134 re-broadcast.
 *
 * Pure and shared so both hosts answer identically. It reads only the
 * discovery snapshot beid#376 already builds — the three-state receiver tier
 * and the raw container retained alongside it — so relay adds no second
 * registry lookup and no second notion of "verified".
 *
 * [signedEnvelopeHex] is the envelope barnard hands a relay verifier: the B005
 * v2 container minus its four-byte delivery header. The retained container in
 * the snapshot is the whole container, so the comparison drops those four
 * bytes. That is exactly the right comparison for relay: the header carries
 * the hop count, which changes at every hop, while the envelope is the part a
 * signature was computed over and that every hop copies unchanged.
 *
 * @param joinedEventIdHex the canonical event id this device is joined to, as
 *   resolved by this host's own registry read, or null while not joined or
 *   while that resolution has not succeeded. Null fails closed, which has a
 *   consequence worth stating plainly: an event joined by typing its code does
 *   not relay until that host's registry lookup resolves the canonical id. The
 *   alternative would be relaying on the strength of a code the user typed,
 *   and spec 134 requires the authoritative definition before re-broadcast.
 * @param envelopeEventIdHex the canonical event id carried by the envelope
 *   offered here, as parsed by barnard's own verification.
 */
public fun nearbyEventRelayEligibility(
    candidates: NearbyEventCandidates,
    signedEnvelopeHex: String,
    eventCodeHashHex: String,
    envelopeEventIdHex: String,
    joinedEventIdHex: String?,
): NearbyEventRelayEligibility {
    val joined = joinedEventIdHex.normalizedHexOrNull() ?: return NearbyEventRelayEligibility.NOT_JOINED
    val envelopeEventId = envelopeEventIdHex.normalizedHexOrNull()
        ?: return NearbyEventRelayEligibility.OTHER_EVENT
    if (joined != envelopeEventId) return NearbyEventRelayEligibility.OTHER_EVENT

    val hash = eventCodeHashHex.normalizedHexOrNull() ?: return NearbyEventRelayEligibility.NOT_REGISTRY_VERIFIED
    val candidate = candidates.candidateForHashHex(hash) ?: return NearbyEventRelayEligibility.NOT_REGISTRY_VERIFIED
    if (candidate.receiverState != NearbyEventReceiverState.REGISTRY_VERIFIED) {
        return NearbyEventRelayEligibility.NOT_REGISTRY_VERIFIED
    }
    // The registry resolution that raised this hash must have resolved the
    // same event id the envelope claims. Without this, an envelope could
    // borrow the tier earned by a different event that happens to share an
    // event-code hash prefix collision.
    if (candidate.resolvedEventIdHex.normalizedHexOrNull() != envelopeEventId) {
        return NearbyEventRelayEligibility.NOT_REGISTRY_VERIFIED
    }

    val retained = candidate.rawEnvelopeContainerHex.normalizedHexOrNull()
        ?: return NearbyEventRelayEligibility.CONTAINER_MISMATCH
    val offered = signedEnvelopeHex.normalizedHexOrNull()
        ?: return NearbyEventRelayEligibility.CONTAINER_MISMATCH
    // Eight hex characters are the four-byte delivery header.
    if (retained.length <= 8) return NearbyEventRelayEligibility.CONTAINER_MISMATCH
    if (retained.substring(8) != offered) return NearbyEventRelayEligibility.CONTAINER_MISMATCH

    return NearbyEventRelayEligibility.ELIGIBLE
}

/** Convenience for native callers that only need the yes/no answer. */
public fun isNearbyEventRelayEligible(
    candidates: NearbyEventCandidates,
    signedEnvelopeHex: String,
    eventCodeHashHex: String,
    envelopeEventIdHex: String,
    joinedEventIdHex: String?,
): Boolean =
    nearbyEventRelayEligibility(
        candidates = candidates,
        signedEnvelopeHex = signedEnvelopeHex,
        eventCodeHashHex = eventCodeHashHex,
        envelopeEventIdHex = envelopeEventIdHex,
        joinedEventIdHex = joinedEventIdHex,
    ) == NearbyEventRelayEligibility.ELIGIBLE

/**
 * Finds the candidate for one event-code hash, comparing normalized forms on
 * both sides.
 *
 * The snapshot's own hashes are lowercase today, so normalizing them changes
 * nothing right now. It is done anyway because the failure it guards against
 * is silent: a hash that differs only in case or an `0x` prefix would simply
 * find no candidate, and the gate would refuse to relay with no signal that a
 * spelling, rather than a policy, made the decision.
 */
private fun NearbyEventCandidates.candidateForHashHex(hashHex: String): NearbyEventCandidate? {
    for (index in 0 until candidateCount) {
        val candidate = candidateAt(index) ?: continue
        if (candidate.eventCodeHashHex.normalizedHexOrNull() == hashHex) return candidate
    }
    return null
}

/**
 * Lowercases and strips an optional `0x`, rejecting anything that is not an
 * even-length run of hex digits. Comparison is on the normalized form so a
 * case or prefix difference between two sources of the same value can never
 * read as a mismatch, and a malformed value can never read as a match.
 */
private fun String?.normalizedHexOrNull(): String? {
    val value = this ?: return null
    val body = if (value.startsWith("0x") || value.startsWith("0X")) value.substring(2) else value
    if (body.isEmpty() || body.length % 2 != 0) return null
    val lowercase = body.lowercase()
    if (!lowercase.all { it in '0'..'9' || it in 'a'..'f' }) return null
    return lowercase
}
