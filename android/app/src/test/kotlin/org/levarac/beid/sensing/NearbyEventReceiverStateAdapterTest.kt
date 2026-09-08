package org.levarac.beid.sensing

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.levarac.barnard.BarnardEventDefinitionV1
import org.levarac.parallax.discovery.NearbyEventReceiverState
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
    @Test
    fun hintOnlyCandidateStaysUnverifiedAndIsNotJoinable() = runTest {
        val registry = FakeRegistry()
        val session = session(registry)
        session.recordHint("peripheral", "Beacon", EVENT_HASH, null, false, false)

        resolveVerifiedOpenDefinition(registry)

        assertEquals(NearbyEventReceiverState.UNVERIFIED, candidate(session).receiverState)
        assertEquals(
            NearbyEventRegistryStatus.REGISTERED_VIA_OPERATOR_LOOKUP,
            candidate(session).registryStatus,
            "the registration itself is genuine -- it is the TIER that is not joinable",
        )
        assertNull(
            session.cards.value.single().eventIdHex,
            "v1.0 nearby join requires REGISTRY_VERIFIED; a successful registry read alone is not it",
        )
    }

    /**
     * A verified-but-unregistered envelope withdraws join only from a
     * candidate that had nothing else to stand on. With no operator lookup
     * behind it this candidate has nothing, so it stays unjoinable.
     */
    @Test
    fun aV2OnlyCandidateWithoutAnOperatorLookupStaysUnjoinable() = runTest {
        val registry = FakeRegistry()
        val session = session(registry)
        session.recordRadioSelfVerifiedEnvelope("peripheral", "Beacon", EVENT_HASH, CONTAINER) { false }
        assertEquals(NearbyEventReceiverState.RADIO_SELF_VERIFIED, candidate(session).receiverState)

        registry.completeLookup(NearbyEventIdLookup(false, null, "event_code_lookup_not_found"))
        runCurrent()

        assertEquals(NearbyEventReceiverState.RADIO_SELF_VERIFIED, candidate(session).receiverState)
        assertNull(session.cards.value.single().eventIdHex)
    }

    /**
     * The positive pin of the v1.0 nearby ruling, asked for by name.
     *
     * `RADIO_SELF_VERIFIED` plus a genuine `REGISTERED_VIA_OPERATOR_LOOKUP`
     * registration is the strongest state that is still NOT joinable, and it is
     * the one the old local rule admitted. Nothing else in this suite pins that
     * exact combination: the neighbouring tests reach it incidentally while
     * asserting something else, so a regression that made it joinable again
     * would not necessarily turn any of them red.
     */
    @Test
    fun radioSelfVerifiedWithAnOperatorLookupRegistrationIsNotJoinable() = runTest {
        val registry = FakeRegistry()
        val session = session(registry)
        session.recordHint("peripheral", "Beacon", EVENT_HASH, null, false, false)
        resolveVerifiedOpenDefinition(registry)
        session.recordRadioSelfVerifiedEnvelope("peripheral", "Beacon", EVENT_HASH, CONTAINER) { false }

        val candidate = candidate(session)
        assertEquals(NearbyEventReceiverState.RADIO_SELF_VERIFIED, candidate.receiverState)
        assertEquals(NearbyEventRegistryStatus.REGISTERED_VIA_OPERATOR_LOOKUP, candidate.registryStatus)
        assertNull(
            session.cards.value.single().eventIdHex,
            "this exact pair rendered as an enabled card before beid#374's review and tapped to JoinFailed",
        )
        assertNull(session.cards.value.single().displayValidFromEpochSeconds)
    }

    @Test
    fun agreementOnAVerifiedDefinitionPromotesAndUnlocksJoin() = runTest {
        val registry = FakeRegistry()
        val session = session(registry)
        session.recordRadioSelfVerifiedEnvelope("peripheral", "Beacon", EVENT_HASH, CONTAINER) { true }

        resolveVerifiedOpenDefinition(registry)

        assertEquals(NearbyEventReceiverState.REGISTRY_VERIFIED, candidate(session).receiverState)
        assertEquals(EVENT_ID_HEX, session.cards.value.single().eventIdHex)
    }

    @Test
    fun anEnvelopeArrivingAfterResolutionStillPromotes() = runTest {
        val registry = FakeRegistry()
        val session = session(registry)
        session.recordHint("peripheral", "Beacon", EVENT_HASH, null, false, false)
        resolveVerifiedOpenDefinition(registry)

        session.recordRadioSelfVerifiedEnvelope("peripheral", "Beacon", EVENT_HASH, CONTAINER) { true }

        assertEquals(NearbyEventReceiverState.REGISTRY_VERIFIED, candidate(session).receiverState)
        assertEquals(EVENT_ID_HEX, session.cards.value.single().eventIdHex)
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
        assertEquals(EVENT_ID_HEX, session.cards.value.single().eventIdHex)

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
        val KEY_SET_DIGEST_HEX = "0x" + KEY_SET_DIGEST_BYTES.toHex()

        fun ByteArray.toHex(): String = joinToString("") { "%02x".format(it.toInt() and 0xff) }
    }
}
