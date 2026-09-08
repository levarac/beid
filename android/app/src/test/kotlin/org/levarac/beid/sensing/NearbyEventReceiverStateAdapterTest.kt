package org.levarac.beid.sensing

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.levarac.barnard.BarnardEventDefinitionV1
import org.levarac.parallax.discovery.NearbyEventJoinEligibility
import org.levarac.parallax.discovery.NearbyEventReceiverState
import org.levarac.parallax.discovery.nearbyCandidateJoinEligibility
import org.levarac.parallax.discovery.NearbyEventRegistryStatus
import org.levarac.parallax.registry.EventJoinMode
import org.levarac.parallax.registry.eventCodeHashForOpenEventV1
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * The Android host's half of the three-state B005 v2 receiver contract.
 *
 * The agreement verdict is stubbed rather than driven through barnard's real
 * `registryAgreement`: `BarnardB005VerifiedEnvelope` has no public constructor
 * on either platform, so no test can fabricate one. What is asserted here is
 * the host's decision about *when* barnard is asked and what is done with the
 * answer; the comparison itself is barnard's own tested code.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class NearbyEventReceiverStateAdapterTest {
    /**
     * The adapter's own error-code mapping, and the second thing beid#391's
     * move dropped.
     *
     * `event_code_lookup_not_found` means the operator answered and does not
     * know this hash, which is NOT_REGISTERED; anything else that fails is
     * LOOKUP_UNAVAILABLE, because a lookup this host could not complete says
     * nothing about whether the event exists. That distinction is made HERE,
     * in the adapter, from a string only this side sees — the shared reducer
     * receives the already-classified result.
     *
     * The moved version of the neighbouring tier test asserted an unjoinable
     * candidate stays unjoinable WITHOUT ever running a lookup that fails, so
     * it kept the assertion and dropped the input that gave it meaning. Same
     * shape as the late-arrival test above: what makes a refusal test real is
     * that something actually refused.
     *
     * This test and its sibling pin THE LOOKUP MAPPING and deliberately say
     * nothing about the card. They cannot: `eventIdHex` is published only from
     * the definition-verification success path, which a failed lookup never
     * reaches, so a card assertion here would read as coverage and hold for
     * every possible card rule including a maximally broken one. The card has
     * a designated guardian in [theCardFollowsTheSharedJoinEligibility], which
     * covers all three tiers itself.
     */
    @Test
    fun aNotFoundLookupIsRecordedAsNotRegisteredRatherThanUnavailable() = runTest {
        val registry = FakeRegistry()
        val session = session(registry)
        session.recordHint("peripheral", "Beacon", EVENT_HASH, null, false, false)

        registry.completeLookup(NearbyEventIdLookup(false, null, "event_code_lookup_not_found"))
        runCurrent()

        assertEquals(NearbyEventRegistryStatus.NOT_REGISTERED, candidate(session).registryStatus)
    }

    /**
     * The other half of that mapping. A lookup that failed for any other
     * reason leaves the question open rather than answering it in the
     * negative, and a host must not treat "I could not ask" as "it does not
     * exist".
     */
    @Test
    fun anyOtherLookupFailureLeavesTheRegistrationUnavailableRatherThanNotRegistered() = runTest {
        val registry = FakeRegistry()
        val session = session(registry)
        session.recordHint("peripheral", "Beacon", EVENT_HASH, null, false, false)

        registry.completeLookup(NearbyEventIdLookup(false, null, "event_code_lookup_http_error"))
        runCurrent()

        assertEquals(NearbyEventRegistryStatus.LOOKUP_UNAVAILABLE, candidate(session).registryStatus)
    }

    /**
     * The late-arrival ordering, and the branch only Android exercises.
     *
     * A hash resolves once, so an envelope arriving AFTER that resolution has
     * no completion callback left to ride on. The adapter therefore asks
     * barnard right here, against the definition its own registry read
     * retained, and hands the verdict to the reducer as `agreesWithRegistry`.
     *
     * This was briefly moved to `shared/` in beid#391 and had to come back,
     * for a reason worth stating because the next person moving tests will
     * reach for the same thing: the shared version exercised
     * `applyNearbyEventRegistryAgreementFromHex`, WHICH HAS NO PRODUCTION
     * CALLER ON EITHER PLATFORM. Both hosts take the inline path above. So the
     * moved test ran against a door nothing walks through while the door
     * production uses had nobody watching it — it passed, it looked like
     * coverage, and it covered nothing that ships. A test can be moved onto an
     * entry point that exists but is unused, and that is invisible unless you
     * mutate the branch you believe is covered.
     */
    @Test
    fun anEnvelopeArrivingAfterResolutionStillPromotes() = runTest {
        val registry = FakeRegistry()
        val session = session(registry)
        session.recordHint("peripheral", "Beacon", EVENT_HASH, null, false, false)
        resolveVerifiedOpenDefinition(registry)

        session.recordRadioSelfVerifiedEnvelope("peripheral", "Beacon", EVENT_HASH, CONTAINER) { true }

        assertEquals(NearbyEventReceiverState.REGISTRY_VERIFIED, candidate(session).receiverState)
        assertEquals(
            NearbyEventJoinEligibility.ELIGIBLE,
            nearbyCandidateJoinEligibility(session.candidates.value, EVENT_HASH.toHex(), NOW_EPOCH_SECONDS),
        )
        assertNotNull(session.cards.value.single().eventIdHex)
    }

    /**
     * The card follows the SHARED rule, and that is all this asserts.
     *
     * Which tier may join is pinned in `shared/`'s
     * [org.levarac.parallax.discovery.NearbyEventJoinEligibilityTest], with
     * mirrored names, because both hosts must answer it identically (beid#391).
     * What has no counterpart there is this projection: the card is an Android
     * rendering of a candidate, and whether it FOLLOWS the shared answer is a
     * different property from what the shared answer is.
     *
     * It is pinned here rather than moved with the rest because the projection
     * deciding for itself is exactly the defect beid#374's review found: the
     * card used to carry its own `when`, which admitted two tiers the issuer
     * refuses, so candidates rendered as enabled and tapped through to
     * JoinFailed. Moving every card assertion to shared would have left that
     * unpinned again.
     */
    @Test
    fun theCardFollowsTheSharedJoinEligibility() = runTest {
        val eligibleRegistry = FakeRegistry()
        val eligible = session(eligibleRegistry)
        eligible.recordRadioSelfVerifiedEnvelope("peripheral", "Beacon", EVENT_HASH, CONTAINER) { true }
        resolveVerifiedOpenDefinition(eligibleRegistry)

        val refusedRegistry = FakeRegistry()
        val refused = session(refusedRegistry)
        refused.recordHint("peripheral", "Beacon", EVENT_HASH, null, false, false)
        resolveVerifiedOpenDefinition(refusedRegistry)
        refused.recordRadioSelfVerifiedEnvelope("peripheral", "Beacon", EVENT_HASH, CONTAINER) { false }

        assertEquals(
            NearbyEventJoinEligibility.ELIGIBLE,
            nearbyCandidateJoinEligibility(eligible.candidates.value, EVENT_HASH.toHex(), NOW_EPOCH_SECONDS),
        )
        assertNotNull(
            eligible.cards.value.single().eventIdHex,
            "a candidate the shared rule calls ELIGIBLE must render as joinable",
        )

        assertEquals(
            NearbyEventJoinEligibility.NOT_REGISTRY_VERIFIED,
            nearbyCandidateJoinEligibility(refused.candidates.value, EVENT_HASH.toHex(), NOW_EPOCH_SECONDS),
        )
        assertNull(
            refused.cards.value.single().eventIdHex,
            "and one it refuses must not, however good its registration looks",
        )

        // The UNVERIFIED tier explicitly, rather than relying on another test
        // to happen to pass through it. Incidental coverage is what evaporates
        // in the next move -- which is precisely what beid#391's first attempt
        // did to the late-arrival branch above.
        val hintOnlyRegistry = FakeRegistry()
        val hintOnly = session(hintOnlyRegistry)
        hintOnly.recordHint("peripheral", "Beacon", EVENT_HASH, null, false, false)
        resolveVerifiedOpenDefinition(hintOnlyRegistry)

        assertEquals(NearbyEventReceiverState.UNVERIFIED, candidate(hintOnly).receiverState)
        assertEquals(
            NearbyEventJoinEligibility.NOT_REGISTRY_VERIFIED,
            nearbyCandidateJoinEligibility(hintOnly.candidates.value, EVENT_HASH.toHex(), NOW_EPOCH_SECONDS),
        )
        assertNull(hintOnly.cards.value.single().eventIdHex)
    }

    /**
     * Spec 122 step 7 binds the event-code hash to the event ID for OPEN
     * events only, so an attacker can forge a self-consistent envelope
     * carrying a GATED event's hash. It verifies and raises the tier. If that
     * withdrew the genuine operator-lookup registration, the forgery would be
     * a cheap denial of service lasting until the discovery TTL. It must
     * still be denied promotion.
     */
    @Test
    fun aDisagreeingEnvelopeNeitherPromotesNorRevokesAnOperatorLookupRegistration() = runTest {
        val registry = FakeRegistry()
        val session = session(registry)
        session.recordHint("peripheral", "Beacon", EVENT_HASH, null, false, false)
        resolveVerifiedOpenDefinition(registry)
        // Not joinable even here: a hint-only candidate is UNVERIFIED, and the
        // v1.0 nearby ruling does not admit that tier however well its registry
        // read went. The registration below is what the forgery must not revoke.
        assertNull(session.cards.value.single().eventIdHex)
        assertEquals(
            NearbyEventRegistryStatus.REGISTERED_VIA_OPERATOR_LOOKUP,
            candidate(session).registryStatus,
        )

        session.recordRadioSelfVerifiedEnvelope("peripheral", "Beacon", EVENT_HASH, CONTAINER) { false }

        assertEquals(NearbyEventReceiverState.RADIO_SELF_VERIFIED, candidate(session).receiverState)
        assertEquals(
            NearbyEventRegistryStatus.REGISTERED_VIA_OPERATOR_LOOKUP,
            candidate(session).registryStatus,
            "the forgery must not revoke the genuine registration -- that is this test's point",
        )
        assertNull(
            session.cards.value.single().eventIdHex,
            "and the tier it forced is still not a joinable one",
        )
    }

    /**
     * The RADIO_SELF_VERIFIED branch of the join gate is not decoration.
     *
     * Verified card metadata is keyed by event-code hash and pruned only
     * against the hashes still live in the published snapshot, while the
     * registry record and the receiver tier are cleared by the shared TTL. So
     * when a candidate's sources expire and the same hash is re-observed
     * inside the same reducer call, the metadata survives while the
     * registration behind it does not: the candidate is RADIO_SELF_VERIFIED
     * with no operator lookup, holding an event identity that a now-cleared
     * registry read had published. Without the branch, that stale identity
     * would be served as joinable.
     *
     * The definition's validity window is far in the future so that the only
     * expiry in play is the discovery TTL, and the wake-up scheduled at
     * exactly that boundary is deliberately not run: the re-observation
     * arrives first, which is the ordering that produces this state.
     */
    @Test
    fun aRetainedDefinitionIsWithheldOnceItsRegistrationHasExpired() = runTest {
        val registry = FakeRegistry()
        val session = session(registry)
        session.recordHint("peripheral", "Beacon", EVENT_HASH, null, false, false)
        registry.completeLookup(NearbyEventIdLookup(true, EVENT_ID_HEX, null))
        runCurrent()
        registry.completeDefinition(verification(validUntilEpochSeconds = 10_000L))
        runCurrent()
        assertNull(
            session.cards.value.single().eventIdHex,
            "a hint-only candidate is not joinable even before its registration lapses",
        )

        // Lands exactly on the TTL boundary without running the wake-up
        // scheduled there, so the re-observation is what expires the old
        // source and clears the registration.
        advanceTimeBy(300_000L)
        session.recordRadioSelfVerifiedEnvelope("peripheral", "Beacon", EVENT_HASH, CONTAINER) { false }

        val candidate = candidate(session)
        assertEquals(NearbyEventReceiverState.RADIO_SELF_VERIFIED, candidate.receiverState)
        assertEquals(NearbyEventRegistryStatus.UNRESOLVED, candidate.registryStatus)
        assertNull(session.cards.value.single().eventIdHex)
        assertNull(session.cards.value.single().displayValidUntilEpochSeconds)
    }

    @Test
    fun barnardIsAskedWithTheDefinitionThisHostRead() = runTest {
        val registry = FakeRegistry()
        val session = session(registry)
        var seen: BarnardEventDefinitionV1? = null
        session.recordRadioSelfVerifiedEnvelope("peripheral", "Beacon", EVENT_HASH, CONTAINER) {
            seen = it
            true
        }

        resolveVerifiedOpenDefinition(registry)

        val definition = assertNotNull(seen)
        assertTrue(EVENT_ID_BYTES.contentEquals(definition.eventId))
        assertTrue(KEY_SET_DIGEST_BYTES.contentEquals(definition.keySetDigest))
        assertTrue(EVENT_HASH.contentEquals(definition.eventCodeHash))
        assertEquals(0, definition.joinMode)
        assertEquals(100L, definition.validFromUnixSeconds)
        assertEquals(200L, definition.validUntilUnixSeconds)
    }

    @Test
    fun anUnavailableRegistryReadNeverPromotesEvenWhenAgreementWouldSayYes() = runTest {
        val registry = FakeRegistry()
        val session = session(registry)
        session.recordRadioSelfVerifiedEnvelope("peripheral", "Beacon", EVENT_HASH, CONTAINER) { true }

        registry.completeLookup(NearbyEventIdLookup(true, EVENT_ID_HEX, null))
        runCurrent()
        registry.completeDefinition(verification(isSuccess = false))
        runCurrent()

        assertEquals(NearbyEventReceiverState.RADIO_SELF_VERIFIED, candidate(session).receiverState)
        assertNull(session.cards.value.single().eventIdHex)
    }

    @Test
    fun aDefinitionMissingItsKeySetDigestNeverPromotes() = runTest {
        val registry = FakeRegistry()
        val session = session(registry)
        session.recordRadioSelfVerifiedEnvelope("peripheral", "Beacon", EVENT_HASH, CONTAINER) { true }

        registry.completeLookup(NearbyEventIdLookup(true, EVENT_ID_HEX, null))
        runCurrent()
        registry.completeDefinition(verification(keySetDigestHex = null))
        runCurrent()

        assertEquals(NearbyEventReceiverState.RADIO_SELF_VERIFIED, candidate(session).receiverState)
    }

    @Test
    fun theRawContainerReachesTheCandidateForSignaturePreservingRelay() = runTest {
        val session = session(FakeRegistry())
        session.recordRadioSelfVerifiedEnvelope("peripheral", "Beacon", EVENT_HASH, CONTAINER) { true }

        val stored = assertNotNull(candidate(session).rawEnvelopeContainer)
        assertTrue(CONTAINER.contentEquals(stored))
    }

    @Test
    fun anUnverifiableContainerIsCountedRatherThanVanishing() = runTest {
        val session = session(FakeRegistry())

        session.recordUnverifiedEnvelope()

        assertEquals(0, session.candidates.value.candidateCount)
        assertEquals(1, session.candidates.value.unverifiedEnvelopeCount)
        assertEquals(0, session.cards.value.size)
    }

    @Test
    fun resetClearsTheReceiverStateAndTheCachedAgreement() = runTest {
        val registry = FakeRegistry()
        val session = session(registry)
        session.recordRadioSelfVerifiedEnvelope("peripheral", "Beacon", EVENT_HASH, CONTAINER) { true }
        resolveVerifiedOpenDefinition(registry)
        assertEquals(NearbyEventReceiverState.REGISTRY_VERIFIED, candidate(session).receiverState)

        session.reset()
        session.recordHint("peripheral", "Beacon", EVENT_HASH, null, false, false)

        assertEquals(NearbyEventReceiverState.UNVERIFIED, candidate(session).receiverState)
    }

    private fun kotlinx.coroutines.test.TestScope.resolveVerifiedOpenDefinition(registry: FakeRegistry) {
        registry.completeLookup(NearbyEventIdLookup(true, EVENT_ID_HEX, null))
        testScheduler.runCurrent()
        registry.completeDefinition(verification())
        testScheduler.runCurrent()
    }

    private fun verification(
        isSuccess: Boolean = true,
        keySetDigestHex: String? = KEY_SET_DIGEST_HEX,
        validUntilEpochSeconds: Long = 200L,
    ) = NearbyEventDefinitionVerification(
        isSuccess = isSuccess,
        joinMode = EventJoinMode.OPEN,
        eventIdHex = EVENT_ID_HEX,
        eventCodeHashHex = EVENT_HASH.toHex(),
        validFromEpochSeconds = 100L,
        validUntilEpochSeconds = validUntilEpochSeconds,
        keySetDigestHex = keySetDigestHex,
        // beid#374: the promotion retains these, and the join issuer re-checks
        // them. Without them a genuinely promoted candidate is refused for
        // incomplete evidence, which is the correct answer and not the one
        // these fixtures are trying to exercise.
        definitionHashHex = DEFINITION_HASH_HEX,
        blockHashHex = BLOCK_HASH_HEX,
    )

    private fun candidate(session: NearbyEventDiscoverySession) =
        assertNotNull(session.candidates.value.candidateAt(0))

    /**
     * The clock sits inside [verification]'s validity window on purpose. The
     * join issuer re-checks that window at the moment it is asked, so a clock
     * at zero — `TestScope`'s default — puts every candidate outside its own
     * definition and refuses it for the wrong reason.
     */
    private fun kotlinx.coroutines.test.TestScope.session(registry: NearbyEventRegistry) =
        NearbyEventDiscoverySession(
            nowEpochMillis = { WINDOW_MIDPOINT_EPOCH_MILLIS + testScheduler.currentTime },
            coroutineScope = backgroundScope,
            registry = registry,
        )

    private class FakeRegistry : NearbyEventRegistry {
        private lateinit var lookupCompletion: (NearbyEventIdLookup) -> Unit
        private lateinit var definitionCompletion: (NearbyEventDefinitionVerification) -> Unit

        override fun resolveEventIdByCodeHash(
            hashHex: String,
            completion: (NearbyEventIdLookup) -> Unit,
        ): NearbyEventRegistryRequest {
            lookupCompletion = completion
            return NearbyEventRegistryRequest {}
        }

        override fun resolveEventDefinition(
            eventIdHex: String,
            useTimeEpochSeconds: Long,
            completion: (NearbyEventDefinitionVerification) -> Unit,
        ): NearbyEventRegistryRequest {
            definitionCompletion = completion
            return NearbyEventRegistryRequest {}
        }

        fun completeLookup(result: NearbyEventIdLookup) = lookupCompletion(result)

        fun completeDefinition(result: NearbyEventDefinitionVerification) = definitionCompletion(result)
    }

    private companion object {
        val EVENT_ID_BYTES = ByteArray(32) { (it + 1).toByte() }
        val KEY_SET_DIGEST_BYTES = ByteArray(32) { (it + 100).toByte() }
        val EVENT_HASH = eventCodeHashForOpenEventV1(EVENT_ID_BYTES)
        val CONTAINER = byteArrayOf(3, 0, 1, 2)
        val EVENT_ID_HEX = "0x" + EVENT_ID_BYTES.toHex()
        val DEFINITION_HASH_HEX = "ab".repeat(32)
        val BLOCK_HASH_HEX = "cd".repeat(32)

        /** Inside `verification()`'s 100..200 second window. */
        const val WINDOW_MIDPOINT_EPOCH_MILLIS = 150_000L
        const val NOW_EPOCH_SECONDS = 150L
        val KEY_SET_DIGEST_HEX = "0x" + KEY_SET_DIGEST_BYTES.toHex()

        fun ByteArray.toHex(): String = joinToString("") { "%02x".format(it.toInt() and 0xff) }
    }
}
