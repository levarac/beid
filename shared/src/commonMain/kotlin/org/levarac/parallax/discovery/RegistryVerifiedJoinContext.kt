// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

package org.levarac.parallax.discovery

import org.levarac.parallax.registry.EventDefinitionContext
import org.levarac.parallax.registry.EventDefinitionResolution
import org.levarac.parallax.registry.EventJoinMode

/**
 * Why an event may or may not be joined by this device (spec 122 receiver
 * policy, beid#374 and beid#391).
 *
 * Named rather than collapsed into a single `false`, for the same reason
 * [NearbyEventRelayEligibility] names its refusals: each one is a different
 * operational story, and a host that cannot tell them apart cannot diagnose a
 * venue where nothing ever joins.
 */
public enum class NearbyEventJoinEligibility {
    /** Every check passed: this event may be joined, keyed and recorded. */
    ELIGIBLE,

    /**
     * The registry read did not succeed, or succeeded with no definition.
     * A read still in flight never reaches this function at all, which is the
     * point: there is nothing to issue a capability from until it answers.
     */
    READ_FAILED,

    /**
     * The evidence is incomplete: a read that did not carry its definition
     * digest or pinned block, or a promoted candidate that retained neither.
     * Without them a later reader cannot tell which definition this join stood
     * on, so the join does not stand.
     */
    INCOMPLETE_REGISTRY_EVIDENCE,

    /**
     * This host's own authenticated registry read has not raised the candidate
     * to [NearbyEventReceiverState.REGISTRY_VERIFIED]. `UNVERIFIED` and
     * `RADIO_SELF_VERIFIED` never issue a capability, whatever else agrees.
     */
    NOT_REGISTRY_VERIFIED,

    /**
     * The candidate is registry-verified, but its registration does not stand
     * as an operator-lookup registration any more, so there is nothing to
     * issue from.
     */
    EVIDENCE_MISMATCH,

    /** The definition is not valid at the moment this join is being decided. */
    DEFINITION_EXPIRED,

    /**
     * The definition does not declare open admission. A GATED event needs
     * admission evidence this function does not have and must not invent.
     */
    NOT_OPEN_ADMISSION,

    /**
     * The join code offered is not one this definition binds. Only reached on
     * the operator-lookup path, where a code is what the user typed rather
     * than something read off the radio.
     *
     * Two ways in: the code is empty, or — beid#463 — the code is a canonical
     * open code and the operator answered with a *different* event. See
     * [operatorLookupJoinEligibility] for why the second one is checkable
     * without trusting anybody.
     */
    CODE_NOT_BOUND,
}

/**
 * Proof that one event passed this host's own authenticated registry read, and
 * the only argument the native join sequence accepts (beid#374, beid#391).
 *
 * ## Why a type and not a flag
 *
 * A flag is advisory: any caller can forget to read it, and a reviewer has to
 * check every call site to know whether it did. Before this type existed, both
 * hosts started `joinEvent` and `startAuto` while the registry read was still
 * in flight, and the read only *annotated* the session afterwards — so a
 * lookup that failed, or never answered, still produced a joined event, a
 * generated event signing key, and a recording session. The native engine no
 * longer exposes a string join at all; it exposes one entry that takes this
 * type. A caller holding only an event code cannot reach join, key use,
 * recording or relay, and that is a compile error rather than a runtime check.
 *
 * ## The two evidence shapes, and why their payloads differ
 *
 * - **(a) A nearby candidate already promoted to `REGISTRY_VERIFIED`.** The
 *   evidence is what the promotion retained: the definition digest, the pinned
 *   block, the resolved Event ID and the validity window. No second registry
 *   read happens at the tap.
 * - **(b) An operator-lookup registration verified at issue time.** The
 *   evidence is the live [EventDefinitionResolution], and [definition] carries
 *   the whole verified [EventDefinitionContext].
 *
 * Shape (a) deliberately carries retained evidence rather than an
 * [EventDefinitionContext]. That type has an `internal` constructor, so
 * requiring one would mean no promoted candidate could ever produce a
 * capability outside this module — including in the app-module tests that
 * assert everything downstream of a join. Choosing retention keeps the real
 * promotion path as the only way in. See the class doc on
 * [NearbyEventDiscoveryStore] for what promotion actually proves.
 *
 * ## Retained evidence versus a live re-check
 *
 * Retained evidence establishes **what was verified**. It does not establish
 * that it is **still true**, because the world moves between promotion and
 * tap. So the issuer re-checks, at issue time and on both shapes, that the
 * definition's window contains *now*, and on the nearby shape that the
 * candidate still stands at `REGISTRY_VERIFIED` with a registration behind it.
 * A capability is never handed out on the strength of a snapshot alone.
 *
 * Open admission is checked at issue time on the operator-lookup shape only.
 * On the nearby shape it was already enforced at PROMOTION — a candidate
 * cannot reach `REGISTERED_VIA_OPERATOR_LOOKUP` unless the definition declared
 * it — and the retained definition digest is what pins that the promotion and
 * this join are talking about the same definition. Harmless in effect, but the
 * distinction is stated because a reviewer reading "both shapes" would not go
 * looking for it.
 *
 * ## What this type does not protect
 *
 * Freshness after issue, revocation, and single use. A Kotlin reference can be
 * held and reused, so this says an event *was* verified a moment ago, not that
 * it still is at some later moment of use. Native hosts therefore carry a
 * request identity through permission waits and callbacks and re-check on
 * resume; a capability obtained before an await is not evidence after it. It
 * must never be serialized, persisted, or restored — a restorable capability
 * is a forgeable one. Physical presence, observation correctness, GATED
 * admission and per-envelope relay decisions are separate evidence and remain
 * so: [nearbyEventRelayEligibility] still runs its own gate, and deliberately
 * refuses a shape (b) join that this type permits.
 *
 * ## Swift Export
 *
 * A concrete final class on purpose. Swift Export erases generics to their
 * upper bound, so a `Context<Verified>` phantom-type version of this would
 * lose the guarantee the moment it crossed into Swift.
 */
public class RegistryVerifiedJoinContext private constructor(
    /**
     * The exact string the native adapter hands `BarnardEngine.joinEvent`.
     *
     * Fixed at issue time and carried inside the capability so no caller can
     * pair a verified event with some other string — an API shaped like
     * `join(context, someCode)` would put that hole straight back. Both
     * evidence paths carry the canonical Event ID here; the operator's human
     * code remains a lookup/UI input only.
     */
    public val joinCode: String,
    /** The canonical Event ID this join was granted for. */
    public val eventIdHex: String,
    /** The digest of the definition this join stands on. */
    public val definitionHashHex: String,
    /** The pinned registry block that definition was read at. */
    public val registryBlockHashHex: String,
    /**
     * The whole verified definition, present only for evidence shape (b),
     * where a live read produced it. Null on the nearby path — see the class
     * doc for why that is a deliberate difference and not an omission.
     */
    public val definition: EventDefinitionContext?,
) {
    public companion object {
        /**
         * Evidence shape (a): a candidate this host's own registry read
         * already promoted to [NearbyEventReceiverState.REGISTRY_VERIFIED].
         *
         * Takes no resolution because none is needed: the promotion already
         * performed the read, and repeating it at the tap would ask the
         * network again for an answer this device has. What it does instead is
         * re-check, now, that the retained answer still holds.
         */
        public fun fromNearbyCandidate(
            candidates: NearbyEventCandidates,
            eventCodeHashHex: String,
            nowEpochSeconds: Long,
        ): RegistryVerifiedJoinContext? {
            val candidate = candidates.candidateForHashHex(
                eventCodeHashHex.normalizedHexOrNull() ?: return null,
            ) ?: return null
            if (nearbyCandidateJoinEligibility(candidates, eventCodeHashHex, nowEpochSeconds) !=
                NearbyEventJoinEligibility.ELIGIBLE
            ) {
                return null
            }
            val eventIdHex = candidate.resolvedEventIdHex ?: return null
            return RegistryVerifiedJoinContext(
                joinCode = eventIdHex,
                eventIdHex = eventIdHex,
                definitionHashHex = candidate.verifiedDefinitionHashHex ?: return null,
                registryBlockHashHex = candidate.registryBlockHashHex ?: return null,
                definition = null,
            )
        }

        /**
         * Evidence shape (b): an operator-lookup registration whose definition
         * was verified at issue time — the path a typed event code takes
         * (code, then Event ID, then verified definition).
         *
         * Kept for v1.0 by maintainer decision: code-entry join depends on it,
         * and a strict `REGISTRY_VERIFIED`-only gate would remove the only way
         * into an event a user was told the code for. It is a registry answer
         * obtained through the operator, not a weaker kind of evidence — but it
         * is a *different* kind, and it deliberately does not satisfy the relay
         * gate, which continues to require a promoted candidate and the exact
         * envelope bytes.
         */
        public fun fromOperatorLookup(
            joinCode: String,
            resolution: EventDefinitionResolution,
            nowEpochSeconds: Long,
        ): RegistryVerifiedJoinContext? {
            if (operatorLookupJoinEligibility(joinCode, resolution, nowEpochSeconds) !=
                NearbyEventJoinEligibility.ELIGIBLE
            ) {
                return null
            }
            val definition = resolution.context ?: return null
            val canonicalEventIdHex = definition.eventIdHex.normalizedHexOrNull() ?: return null
            return RegistryVerifiedJoinContext(
                // The operator code is only a lookup/UI hint. The engine wire
                // contract is the verified definition's canonical Event ID.
                joinCode = canonicalEventIdHex,
                eventIdHex = canonicalEventIdHex,
                definitionHashHex = resolution.definitionHashHex ?: return null,
                registryBlockHashHex = resolution.blockHashHex ?: return null,
                definition = definition,
            )
        }
    }
}

/**
 * The shared decision behind [RegistryVerifiedJoinContext.fromNearbyCandidate].
 *
 * Exposed separately so a host can show *why* a card refused without holding a
 * capability it was not granted, and so both platforms answer identically.
 */
public fun nearbyCandidateJoinEligibility(
    candidates: NearbyEventCandidates,
    eventCodeHashHex: String,
    nowEpochSeconds: Long,
): NearbyEventJoinEligibility {
    val hash = eventCodeHashHex.normalizedHexOrNull()
        ?: return NearbyEventJoinEligibility.NOT_REGISTRY_VERIFIED
    val candidate = candidates.candidateForHashHex(hash)
        ?: return NearbyEventJoinEligibility.NOT_REGISTRY_VERIFIED
    // Exhaustive on purpose, with no `else`: a fourth receiver state must not
    // silently inherit permission to join.
    when (candidate.receiverState) {
        NearbyEventReceiverState.UNVERIFIED,
        NearbyEventReceiverState.RADIO_SELF_VERIFIED,
        -> return NearbyEventJoinEligibility.NOT_REGISTRY_VERIFIED
        NearbyEventReceiverState.REGISTRY_VERIFIED -> Unit
    }
    // The tier alone is not the registration. A hash can hold a promoted tier
    // while its registration has since been downgraded, and the retained
    // evidence is cleared in exactly that case.
    if (candidate.registryStatus != NearbyEventRegistryStatus.REGISTERED_VIA_OPERATOR_LOOKUP) {
        return NearbyEventJoinEligibility.EVIDENCE_MISMATCH
    }
    if (candidate.resolvedEventIdHex.normalizedHexOrNull() == null) {
        return NearbyEventJoinEligibility.EVIDENCE_MISMATCH
    }
    if (candidate.verifiedDefinitionHashHex.normalizedHexOrNull() == null ||
        candidate.registryBlockHashHex.normalizedHexOrNull() == null
    ) {
        return NearbyEventJoinEligibility.INCOMPLETE_REGISTRY_EVIDENCE
    }
    val validFrom = candidate.definitionValidFromEpochSeconds
        ?: return NearbyEventJoinEligibility.INCOMPLETE_REGISTRY_EVIDENCE
    val validUntil = candidate.definitionValidUntilEpochSeconds
        ?: return NearbyEventJoinEligibility.INCOMPLETE_REGISTRY_EVIDENCE
    // Re-checked here, not at promotion. Retained evidence says what was
    // verified; this says it is still true.
    if (nowEpochSeconds < validFrom || nowEpochSeconds > validUntil) {
        return NearbyEventJoinEligibility.DEFINITION_EXPIRED
    }
    return NearbyEventJoinEligibility.ELIGIBLE
}

/** The shared decision behind [RegistryVerifiedJoinContext.fromOperatorLookup]. */
public fun operatorLookupJoinEligibility(
    joinCode: String,
    resolution: EventDefinitionResolution,
    nowEpochSeconds: Long,
): NearbyEventJoinEligibility {
    val definition = (if (resolution.isSuccess) resolution.context else null)
        ?: return NearbyEventJoinEligibility.READ_FAILED
    resolution.definitionHashHex.normalizedHexOrNull()
        ?: return NearbyEventJoinEligibility.INCOMPLETE_REGISTRY_EVIDENCE
    resolution.blockHashHex.normalizedHexOrNull()
        ?: return NearbyEventJoinEligibility.INCOMPLETE_REGISTRY_EVIDENCE
    if (joinCode.isEmpty()) return NearbyEventJoinEligibility.CODE_NOT_BOUND
    // beid#463. The operator lookup is a routing hint and nothing more: it can
    // answer with a different real event than the one whose code was entered,
    // by mistake or on purpose, and everything downstream would then verify
    // perfectly — the wrong event's definition really is signed, really is
    // open, really is inside its window. What makes the answer checkable is
    // that a canonical open code IS the Event ID (`canonicalOpenCodeV1` is the
    // lowercase hex of all 32 bytes), so this device already holds the value
    // the answer has to match and needs to ask no one for it.
    //
    // Recognized through `normalizedHexOrNull`, never by raw length: a code
    // pasted from a wallet or an explorer arrives `0x`-prefixed and 66
    // characters long, because `normalizedEventCodeOrNull` trims and case-
    // folds but deliberately does not strip the prefix. Matching on raw length
    // would classify exactly that input as "not canonical" and skip the check
    // on the paths most likely to carry one.
    //
    // A code that is not a canonical open code has nothing here to compare
    // against — a deployment's human-readable code is bound to its event only
    // by the operator's own table — so it is admitted as before. Binding those
    // needs an expected Event ID carried alongside the code in the handoff,
    // which v1.0's paste route does not have.
    val canonicalOpenCode = joinCode.normalizedHexOrNull()
        ?.takeIf { it.length == CANONICAL_OPEN_CODE_HEX_LENGTH }
    if (canonicalOpenCode != null &&
        canonicalOpenCode != definition.eventIdHex.normalizedHexOrNull()
    ) {
        return NearbyEventJoinEligibility.CODE_NOT_BOUND
    }
    if (definition.joinMode != EventJoinMode.OPEN) return NearbyEventJoinEligibility.NOT_OPEN_ADMISSION
    val validFrom = definition.validFrom.value
    val validUntil = definition.validUntil.value
    if (nowEpochSeconds < validFrom || nowEpochSeconds > validUntil) {
        return NearbyEventJoinEligibility.DEFINITION_EXPIRED
    }
    return NearbyEventJoinEligibility.ELIGIBLE
}

/**
 * Length of a canonical open join code in normalized (unprefixed, lowercase)
 * hex characters — a whole 32-byte Event ID, which is what
 * `canonicalOpenCodeV1` renders.
 */
private const val CANONICAL_OPEN_CODE_HEX_LENGTH: Int = 64
