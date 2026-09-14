package org.levarac.parallax.discovery

import org.levarac.parallax.registry.EventDefinition
import org.levarac.parallax.registry.EventDefinitionCborCodec
import org.levarac.parallax.registry.EventDefinitionContext
import org.levarac.parallax.registry.EventDefinitionResolution
import org.levarac.parallax.registry.EventJoinMode
import org.levarac.parallax.registry.anchorRegistration
import org.levarac.parallax.registry.definitionRecord
import org.levarac.parallax.registry.readEventDefinitionVector
import org.levarac.parallax.registry.requiredString
import org.levarac.parallax.registry.vectorEventId
import org.levarac.parallax.registry.vectorHexBytes
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull

/**
 * The issuer half of beid#374's join gate: what does and does not produce a
 * [RegistryVerifiedJoinContext], on both evidence shapes — (b), the
 * operator-lookup path a typed event code takes, and (a), a nearby candidate
 * this host's own registry read already promoted.
 *
 * These prove the property the type exists for — that a capability is never
 * issued for a read that failed or that cannot be verified. The other half of
 * the acceptance criterion, that a *pending* read starts neither join nor
 * sensing, cannot be expressed here and is not meant to be: a read still in
 * flight never reaches the issuer at all. That half is proven on the native
 * side, where the waiting actually happens.
 *
 * Everything is built from the same conformance vector the codec tests use, so
 * a definition here is one that really verified rather than a hand-shaped
 * stand-in.
 */
class RegistryVerifiedJoinContextTest {
    @Test
    fun aVerifiedOpenDefinitionInsideItsWindowIssuesTheCapability() {
        val resolution = resolution()

        val context = RegistryVerifiedJoinContext.fromOperatorLookup(
            joinCode = JOIN_CODE,
            resolution = resolution,
            nowEpochSeconds = vectorValidFrom(),
        )

        val issued = assertNotNull(context)
        assertEquals(CANONICAL_OPEN_CODE, issued.joinCode)
        assertEquals(CANONICAL_OPEN_CODE, issued.eventIdHex)
        assertEquals(DEFINITION_HASH_HEX, issued.definitionHashHex)
        assertEquals(BLOCK_HASH_HEX, issued.registryBlockHashHex)
    }

    @Test
    fun aPrefixedDefinitionDigestIsCanonicalizedForTheWireContext() {
        val context = assertNotNull(
            RegistryVerifiedJoinContext.fromOperatorLookup(
                joinCode = JOIN_CODE,
                resolution = resolution(definitionHashHex = "0x${DEFINITION_HASH_HEX.uppercase()}"),
                nowEpochSeconds = vectorValidFrom(),
            ),
        )

        assertEquals(DEFINITION_HASH_HEX, context.definitionHashHex)
    }

    @Test
    fun aFailedReadIssuesNothing() {
        val resolution = resolution(isSuccess = false)

        assertEquals(
            NearbyEventJoinEligibility.READ_FAILED,
            operatorLookupJoinEligibility(JOIN_CODE, resolution, vectorValidFrom()),
        )
        assertNull(RegistryVerifiedJoinContext.fromOperatorLookup(JOIN_CODE, resolution, vectorValidFrom()))
    }

    /**
     * A read can report success and still carry no definition. Treating that
     * as a join would be the original defect in a new place.
     */
    @Test
    fun aSuccessfulReadWithNoDefinitionIssuesNothing() {
        val resolution = resolution(context = null)

        assertEquals(
            NearbyEventJoinEligibility.READ_FAILED,
            operatorLookupJoinEligibility(JOIN_CODE, resolution, vectorValidFrom()),
        )
        assertNull(RegistryVerifiedJoinContext.fromOperatorLookup(JOIN_CODE, resolution, vectorValidFrom()))
    }

    @Test
    fun aReadMissingItsDefinitionDigestIssuesNothing() {
        val resolution = resolution(definitionHashHex = null)

        assertEquals(
            NearbyEventJoinEligibility.INCOMPLETE_REGISTRY_EVIDENCE,
            operatorLookupJoinEligibility(JOIN_CODE, resolution, vectorValidFrom()),
        )
        assertNull(RegistryVerifiedJoinContext.fromOperatorLookup(JOIN_CODE, resolution, vectorValidFrom()))
    }

    @Test
    fun aReadMissingItsPinnedBlockIssuesNothing() {
        val resolution = resolution(blockHashHex = null)

        assertEquals(
            NearbyEventJoinEligibility.INCOMPLETE_REGISTRY_EVIDENCE,
            operatorLookupJoinEligibility(JOIN_CODE, resolution, vectorValidFrom()),
        )
        assertNull(RegistryVerifiedJoinContext.fromOperatorLookup(JOIN_CODE, resolution, vectorValidFrom()))
    }

    @Test
    fun aDefinitionOutsideItsValidityWindowIssuesNothing() {
        val resolution = resolution()

        assertEquals(
            NearbyEventJoinEligibility.DEFINITION_EXPIRED,
            operatorLookupJoinEligibility(JOIN_CODE, resolution, vectorValidUntil() + 1),
        )
        assertEquals(
            NearbyEventJoinEligibility.DEFINITION_EXPIRED,
            operatorLookupJoinEligibility(JOIN_CODE, resolution, vectorValidFrom() - 1),
        )
        assertNull(RegistryVerifiedJoinContext.fromOperatorLookup(JOIN_CODE, resolution, vectorValidUntil() + 1))
    }

    /**
     * A gated event needs admission evidence this function does not have. It
     * refuses rather than inventing one.
     */
    @Test
    fun aGatedDefinitionIssuesNothing() {
        val resolution = resolution(joinMode = EventJoinMode.GATED)

        assertEquals(
            NearbyEventJoinEligibility.NOT_OPEN_ADMISSION,
            operatorLookupJoinEligibility(JOIN_CODE, resolution, vectorValidFrom()),
        )
        assertNull(RegistryVerifiedJoinContext.fromOperatorLookup(JOIN_CODE, resolution, vectorValidFrom()))
    }

    @Test
    fun anEmptyJoinCodeIssuesNothing() {
        val resolution = resolution()

        assertEquals(
            NearbyEventJoinEligibility.CODE_NOT_BOUND,
            operatorLookupJoinEligibility("", resolution, vectorValidFrom()),
        )
        assertNull(RegistryVerifiedJoinContext.fromOperatorLookup("", resolution, vectorValidFrom()))
    }

    /**
     * beid#463. The operator lookup is a routing hint, and an operator can
     * answer with a different real event than the one whose code was entered
     * — by mistake or on purpose. For an open canonical code the entered code
     * *is* the Event ID, so the answer is checkable without asking anyone: the
     * definition that came back must be the one the code names.
     *
     * This is the positive control for the three refusals below. Without it a
     * binding check that refused everything would still pass them.
     */
    /**
     * The guard on the fixture itself. Everything below compares a literal
     * against the definition the vector produces, so if the vector's Event ID
     * ever changes, the positive control silently becomes a fourth
     * mismatch test — passing, meaningless, and indistinguishable from the
     * real thing. This fails first and says so.
     */
    @Test
    fun theCanonicalOpenCodeFixtureIsTheVectorsOwnEventId() {
        assertEquals(
            "0x$CANONICAL_OPEN_CODE",
            definitionContext(EventJoinMode.OPEN).eventIdHex,
            "the canonical open code fixture has drifted from the event-definition vector",
        )
    }

    @Test
    fun aCanonicalOpenCodeMatchingTheResolvedEventIdIssuesTheCapability() {
        val resolution = resolution()

        assertEquals(
            NearbyEventJoinEligibility.ELIGIBLE,
            operatorLookupJoinEligibility(CANONICAL_OPEN_CODE, resolution, vectorValidFrom()),
        )
        val issued = assertNotNull(
            RegistryVerifiedJoinContext.fromOperatorLookup(
                CANONICAL_OPEN_CODE,
                resolution,
                vectorValidFrom(),
            ),
        )
        assertEquals(CANONICAL_OPEN_CODE, issued.joinCode)
    }

    /**
     * The refusal beid#463 exists for. The definition here is genuinely
     * verified — it passed the codec, it declares open admission and the clock
     * is inside its window — so every check that ran before this one says yes.
     * Obtaining a definition is not permission to join it.
     */
    @Test
    fun aCanonicalOpenCodeNamingADifferentEventIssuesNothing() {
        val resolution = resolution()

        assertEquals(
            NearbyEventJoinEligibility.CODE_NOT_BOUND,
            operatorLookupJoinEligibility(OTHER_CANONICAL_OPEN_CODE, resolution, vectorValidFrom()),
        )
        assertNull(
            RegistryVerifiedJoinContext.fromOperatorLookup(
                OTHER_CANONICAL_OPEN_CODE,
                resolution,
                vectorValidFrom(),
            ),
        )
    }

    /**
     * The same refusal, reached through the spelling a user is most likely to
     * paste: `normalizedEventCodeOrNull` trims and case-folds but does not
     * strip `0x`, so a code copied from a wallet or an explorer arrives 66
     * characters long. An implementation that recognized a canonical code by
     * raw length alone would classify this as "not canonical", skip the
     * binding entirely, and admit the wrong event — while every other test in
     * this class still passed.
     */
    @Test
    fun aPrefixedCanonicalOpenCodeNamingADifferentEventIssuesNothing() {
        val resolution = resolution()
        val prefixed = "0x" + OTHER_CANONICAL_OPEN_CODE

        assertEquals(
            NearbyEventJoinEligibility.CODE_NOT_BOUND,
            operatorLookupJoinEligibility(prefixed, resolution, vectorValidFrom()),
        )
        assertNull(RegistryVerifiedJoinContext.fromOperatorLookup(prefixed, resolution, vectorValidFrom()))
    }

    /**
     * And the boundary in the other direction: a deployment's human-readable
     * code is not an Event ID and there is nothing on the device to compare it
     * against, so it is admitted exactly as before. Stated as a test because
     * the cheapest wrong version of the binding — refuse anything that is not
     * the Event ID — would break every code-entry join in the product and pass
     * all three tests above.
     */
    @Test
    fun aHumanReadableEventCodeIsAdmittedWithNoBindingToCompareAgainst() {
        val resolution = resolution()

        assertEquals(
            NearbyEventJoinEligibility.ELIGIBLE,
            operatorLookupJoinEligibility(JOIN_CODE, resolution, vectorValidFrom()),
        )
        assertNotNull(RegistryVerifiedJoinContext.fromOperatorLookup(JOIN_CODE, resolution, vectorValidFrom()))
    }

    /**
     * The join code travels inside the capability, fixed at issue time. This
     * is what stops a later caller pairing a verified event with some other
     * string, which is the shape the whole gate exists to make impossible.
     */
    @Test
    fun theCapabilityCarriesTheCodeItWasIssuedFor() {
        val issued = assertNotNull(
            RegistryVerifiedJoinContext.fromOperatorLookup(JOIN_CODE, resolution(), vectorValidFrom()),
        )

        assertEquals(CANONICAL_OPEN_CODE, issued.joinCode)
        assertEquals(CANONICAL_OPEN_CODE, issued.eventIdHex)
    }

    private fun verifiedDefinition(): EventDefinition {
        val vector = readEventDefinitionVector(VECTOR_PATH)
        return EventDefinitionCborCodec.verify(
            signedBytes = vector.requiredString("signedEventDefinitionHex").vectorHexBytes(),
            encodedKeySet = vector.requiredString("eventKeySetHex").vectorHexBytes(),
            eventId = vector.vectorEventId(),
            registration = vector.anchorRegistration(),
            record = vector.definitionRecord(),
            at = vector.definitionRecord().validFrom,
        ).definition
    }

    // ---- Evidence shape (a): a REGISTRY_VERIFIED nearby candidate ----

    @Test
    fun aPromotedCandidateInsideItsWindowIssuesTheCapability() {
        val candidates = promotedCandidates()

        // Asked inside the window the PROMOTION retained, which is the only
        // window shape (a) knows about. The conformance vector's own window
        // belongs to shape (b) and has nothing to do with this candidate.
        val issued = assertNotNull(
            RegistryVerifiedJoinContext.fromNearbyCandidate(candidates, HASH, VALID_FROM),
        )

        assertEquals(
            NearbyEventJoinEligibility.ELIGIBLE,
            nearbyCandidateJoinEligibility(candidates, HASH, VALID_FROM),
        )
        assertEquals(EVENT_ID, issued.joinCode, "the nearby path joins the canonical Event ID")
        assertEquals(EVENT_ID, issued.eventIdHex)
        assertEquals(DEFINITION_HASH_HEX, issued.definitionHashHex)
        assertEquals(BLOCK_HASH_HEX, issued.registryBlockHashHex)
        assertNull(
            issued.definition,
            "shape (a) stands on retained promotion evidence, not on a live definition read",
        )
    }

    @Test
    fun aPromotedCandidateCanonicalizesTheResolvedEventIdForTheWireContext() {
        val candidates = promotedCandidates(resolvedEventIdHex = "0x${EVENT_ID.uppercase()}")

        val issued = assertNotNull(
            RegistryVerifiedJoinContext.fromNearbyCandidate(candidates, HASH, VALID_FROM),
        )

        assertEquals(EVENT_ID, issued.joinCode)
        assertEquals(EVENT_ID, issued.eventIdHex)
    }

    @Test
    fun aNearbyCandidateCanonicalizesAPrefixedDefinitionDigestForTheWireContext() {
        val candidates = promotedCandidates(
            definitionHashHex = "0x${DEFINITION_HASH_HEX.uppercase()}",
        )

        val issued = assertNotNull(
            RegistryVerifiedJoinContext.fromNearbyCandidate(candidates, HASH, VALID_FROM),
        )

        assertEquals(DEFINITION_HASH_HEX, issued.definitionHashHex)
    }

    /**
     * The tier is the whole point. A candidate barnard verified on the radio
     * but that this host's own registry read never confirmed must not join,
     * whatever else agrees.
     */
    @Test
    fun aRadioSelfVerifiedCandidateIssuesNothing() {
        val store = createNearbyEventDiscoveryStore()
        recordEnvelope(store)
        val candidates = store.snapshot

        assertEquals(
            NearbyEventJoinEligibility.NOT_REGISTRY_VERIFIED,
            nearbyCandidateJoinEligibility(candidates, HASH, VALID_FROM),
        )
        assertNull(RegistryVerifiedJoinContext.fromNearbyCandidate(candidates, HASH, VALID_FROM))
    }

    @Test
    fun aCandidateFromV1HintsAloneIssuesNothing() {
        val store = createNearbyEventDiscoveryStore()
        recordNearbyEventHint(store, "p", "Event", HASH.hexBytes(), null, false, false, 1L)

        assertEquals(
            NearbyEventJoinEligibility.NOT_REGISTRY_VERIFIED,
            nearbyCandidateJoinEligibility(store.snapshot, HASH, VALID_FROM),
        )
    }

    @Test
    fun anUnknownEventCodeHashIssuesNothing() {
        val candidates = promotedCandidates()

        assertEquals(
            NearbyEventJoinEligibility.NOT_REGISTRY_VERIFIED,
            nearbyCandidateJoinEligibility(candidates, OTHER_HASH, VALID_FROM),
        )
    }

    /**
     * A promotion made by a host that did not retain the digest and block --
     * every caller before beid#374 -- establishes which event was verified but
     * not which definition. The issuer refuses rather than joining on the
     * weaker evidence, which is what makes the new parameters fail closed.
     */
    @Test
    fun aPromotedCandidateWithNoRetainedEvidenceIssuesNothing() {
        val candidates = promotedCandidates(retainEvidence = false)

        assertEquals(
            NearbyEventJoinEligibility.INCOMPLETE_REGISTRY_EVIDENCE,
            nearbyCandidateJoinEligibility(candidates, HASH, VALID_FROM),
        )
        assertNull(RegistryVerifiedJoinContext.fromNearbyCandidate(candidates, HASH, VALID_FROM))
    }

    /**
     * The re-check that makes retained evidence safe to issue from. The
     * promotion stands and its evidence is complete; the definition has simply
     * stopped being valid since. Retained evidence says what was verified,
     * this says whether it is still true.
     */
    @Test
    fun aPromotedCandidateWhoseDefinitionHasSinceExpiredIssuesNothing() {
        val candidates = promotedCandidates()

        assertEquals(
            NearbyEventJoinEligibility.DEFINITION_EXPIRED,
            nearbyCandidateJoinEligibility(candidates, HASH, VALID_UNTIL + 1),
        )
        assertNull(RegistryVerifiedJoinContext.fromNearbyCandidate(candidates, HASH, VALID_UNTIL + 1))
    }

    @Test
    fun aPromotedCandidateAskedBeforeItsWindowOpensIssuesNothing() {
        val candidates = promotedCandidates()

        assertEquals(
            NearbyEventJoinEligibility.DEFINITION_EXPIRED,
            nearbyCandidateJoinEligibility(candidates, HASH, VALID_FROM - 1),
        )
    }

    /** A promoted candidate whose registration was established with the digest and block retained. */
    private fun promotedCandidates(
        retainEvidence: Boolean = true,
        definitionHashHex: String = DEFINITION_HASH_HEX,
        resolvedEventIdHex: String = EVENT_ID,
    ): NearbyEventCandidates {
        val store = createNearbyEventDiscoveryStore()
        recordEnvelope(store)
        val attempt = assertNotNull(beginNearbyEventRegistryResolutionFromHex(store, HASH))
        return completeNearbyEventRegistryResolutionFromHex(
            store = store,
            attempt = attempt,
            result = NearbyEventRegistryResolutionResult.VERIFIED,
            resolvedEventIdHex = resolvedEventIdHex,
            verifiedDefinitionJoinMode = EventJoinMode.OPEN,
            verifiedDefinitionEventIdHex = EVENT_ID,
            verifiedDefinitionEventCodeHashHex = HASH,
            envelopeAgreesWithRegistry = true,
            verifiedDefinitionHashHex = if (retainEvidence) definitionHashHex else null,
            registryBlockHashHex = if (retainEvidence) BLOCK_HASH_HEX else null,
            verifiedDefinitionValidFromEpochSeconds = if (retainEvidence) VALID_FROM else null,
            verifiedDefinitionValidUntilEpochSeconds = if (retainEvidence) VALID_UNTIL else null,
        ).snapshot
    }

    private fun recordEnvelope(store: NearbyEventDiscoveryStore) {
        recordNearbyEventRadioSelfVerifiedEnvelope(
            store = store,
            peripheralId = "p",
            eventDisplayName = "Event",
            eventCodeHash = HASH.hexBytes(),
            rawContainer = CONTAINER,
            agreesWithRegistry = false,
            additionalNamesOmitted = false,
            additionalEventsOmitted = false,
            observedAtEpochMillis = 1L,
        )
    }

    private fun definitionContext(joinMode: EventJoinMode): EventDefinitionContext {
        val vector = readEventDefinitionVector(VECTOR_PATH)
        val base = verifiedDefinition()
        val definition = EventDefinition(
            version = base.version,
            eventId = base.eventId,
            registrar = base.registrar,
            anchorOperator = base.anchorOperator,
            nonce = base.nonce,
            keySetDigest = base.keySetDigest,
            sequence = base.sequence,
            previousDefinitionDigest = base.previousDefinitionDigest,
            receiptPublicKey = base.receiptPublicKey,
            operatorId = base.operatorId,
            submissionEndpoint = base.submissionEndpoint,
            validFrom = base.validFrom,
            validUntil = base.validUntil,
            authorityPublicKey = base.authorityPublicKey,
            joinMode = joinMode,
        )
        return EventDefinitionContext(
            // Match EventDefinitionFetcher, which exposes the verified ID with
            // an optional 0x prefix; the issuer must normalize it for the wire.
            eventIdHex = "0x" + vector.vectorEventId().toLowercaseHex(),
            definitionHashHex = DEFINITION_HASH_HEX,
            selectedAt = vector.definitionRecord().validFrom,
            record = vector.definitionRecord(),
            definition = definition,
        )
    }

    private fun resolution(
        isSuccess: Boolean = true,
        context: EventDefinitionContext? = definitionContext(EventJoinMode.OPEN),
        joinMode: EventJoinMode? = null,
        definitionHashHex: String? = DEFINITION_HASH_HEX,
        blockHashHex: String? = BLOCK_HASH_HEX,
    ): EventDefinitionResolution = EventDefinitionResolution(
        isSuccess = isSuccess,
        context = joinMode?.let { definitionContext(it) } ?: context,
        blockNumber = 1L,
        blockHashHex = blockHashHex,
        definitionHashHex = definitionHashHex,
        errorCode = null,
        errorMessage = null,
    )

    private fun vectorValidFrom(): Long = verifiedDefinition().validFrom.value

    private fun vectorValidUntil(): Long = verifiedDefinition().validUntil.value

    private companion object {
        const val VECTOR_PATH = "vectors/positive/event-definition-v1.json"
        const val JOIN_CODE = "ethtokyo2026"

        /**
         * The same Event ID and event-code hash pair the receiver-state suite
         * uses. They are a real OPEN v1 pair — the hash is what
         * `eventCodeHashForOpenEventV1` derives from the ID — which is what
         * lets a promotion actually complete here.
         */
        const val EVENT_ID = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"

        /**
         * The canonical open code for the definition the *event-definition*
         * vector carries: `canonicalOpenCodeV1` is the lowercase hex of the
         * whole 32-byte Event ID, so for an open event the code and the ID are
         * the same string.
         *
         * Note that this is **not** [EVENT_ID]. That constant belongs to the
         * nearby-candidate fixtures above and is a different event; using it
         * here would have made the positive control below assert a mismatch
         * while reading like a match. The literal is spelled out rather than
         * derived so a reader can see the value, and
         * `theCanonicalOpenCodeFixtureIsTheVectorsOwnEventId` asserts it still
         * is the vector's, so a changed vector fails loudly instead of quietly
         * turning the positive control into a fourth mismatch test.
         */
        const val CANONICAL_OPEN_CODE =
            "5d5891b92a9a6597aa2c58586fd2fdf3974f40f732b9a319ec9f3fc4d7ab3195"

        /** A well-formed canonical open code for some other event. */
        const val OTHER_CANONICAL_OPEN_CODE =
            "1f1e1d1c1b1a191817161514131211100f0e0d0c0b0a09080706050403020100"
        const val HASH = "6c86c6aac5fb24bc"
        const val OTHER_HASH = "0011223344556677"
        val CONTAINER = byteArrayOf(3, 0, 1, 2)
        val DEFINITION_HASH_HEX = "ab".repeat(32)
        val BLOCK_HASH_HEX = "cd".repeat(32)
        const val VALID_FROM = 1_800_000_000L
        const val VALID_UNTIL = 1_900_000_000L
    }
}

private fun ByteArray.toLowercaseHex(): String =
    joinToString(separator = "") { (it.toInt() and 0xff).toString(16).padStart(2, '0') }

private fun String.hexBytes(): ByteArray =
    chunked(2).map { it.toInt(16).toByte() }.toByteArray()
