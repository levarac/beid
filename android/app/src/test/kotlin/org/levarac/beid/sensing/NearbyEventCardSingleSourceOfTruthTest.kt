package org.levarac.beid.sensing

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runTest
import org.levarac.parallax.discovery.NearbyEventJoinEligibility
import org.levarac.parallax.discovery.candidateForHashHex
import org.levarac.parallax.discovery.nearbyCandidateJoinEligibility
import org.levarac.parallax.registry.EventJoinMode
import org.levarac.parallax.registry.eventCodeHashForOpenEventV1
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull

/**
 * beid#454: the card's `eventIdHex` must always agree with the shared
 * predicate's ELIGIBLE verdict for the same candidate. Before this fix,
 * Android read the card's `eventIdHex` from a native cache
 * (`verifiedMetadataByHash`) that the shared predicate does not consult, so
 * the two could disagree; iOS never had a second source, since
 * [org.levarac.parallax.discovery.RegistryVerifiedJoinContext.fromNearbyCandidate]
 * already reads the candidate directly.
 *
 * The traced route to a live disagreement is source eviction outliving the
 * cache: [org.levarac.parallax.discovery.NearbyEventDiscoveryStore] caps live
 * sources at 256 and evicts the globally oldest one, from `store.sources`
 * only, when a 257th arrives -- `store.registry` / `store.receiverStates` are
 * untouched by that eviction and are pruned only on TTL expiry. If the
 * evicted hash was the only source for a REGISTRY_VERIFIED, registered
 * candidate, that candidate briefly leaves the live snapshot, and Android's
 * per-hash caches (including `verifiedMetadataByHash`) are pruned to match.
 * A later re-observation of the same hash, before its registry record's TTL,
 * rebuilds a candidate the shared predicate still calls ELIGIBLE from
 * retained registry evidence -- but `updateVerifiedCard`'s one call site is
 * the registry *resolution* callback, which never re-runs for an
 * already-resolved hash, so the cache is never refilled. Pre-fix, the card
 * for that candidate renders with a null `eventIdHex` despite the shared
 * ELIGIBLE verdict.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class NearbyEventCardSingleSourceOfTruthTest {
    @Test
    fun theCardsEventIdHexMatchesTheCandidatesResolvedEventIdHexAfterSourceEviction() = runTest {
        val registry = FakeRegistry()
        val session = session(registry)

        // Promote TARGET to ELIGIBLE the same way theCardFollowsTheSharedJoinEligibility
        // does in NearbyEventReceiverStateAdapterTest: a radio-self-verified envelope,
        // then a registry read that agrees with it.
        session.recordRadioSelfVerifiedEnvelope("peripheral", "Beacon", TARGET_HASH, CONTAINER) { true }
        resolveVerifiedOpenDefinition(registry)

        val eligibleCandidate = assertNotNull(
            session.candidates.value.candidateForHashHex(TARGET_HASH_HEX),
        )
        assertEquals(
            NearbyEventJoinEligibility.ELIGIBLE,
            nearbyCandidateJoinEligibility(session.candidates.value, TARGET_HASH_HEX, NOW_EPOCH_SECONDS),
        )
        assertEquals(
            eligibleCandidate.resolvedEventIdHex,
            cardFor(session, TARGET_HASH_HEX).eventIdHex,
            "sanity: parity holds before any eviction",
        )

        // Force the 256-source cap: 256 distinct peripherals under one junk hash, each
        // observed strictly after TARGET's single source, so TARGET is the globally
        // oldest source and is the one evicted when the 257th distinct source arrives
        // (NearbyEventDiscovery.kt's recordObservation, MAX_LIVE_SOURCE_COUNT = 256).
        repeat(256) { i ->
            advanceTimeBy(1)
            session.recordHint("junk-$i", "Junk", JUNK_HASH, null, false, false)
        }

        // Re-observation before the retained registry record's own TTL rebuilds the
        // candidate from retained evidence; this is the "re-observed before the next
        // sweep" step of the traced path.
        advanceTimeBy(1)
        session.recordHint("peripheral", "Beacon", TARGET_HASH, null, false, false)

        val candidateAfterReobservation = assertNotNull(
            session.candidates.value.candidateForHashHex(TARGET_HASH_HEX),
            "TARGET must be back in the live snapshot after re-observation",
        )
        assertEquals(
            NearbyEventJoinEligibility.ELIGIBLE,
            nearbyCandidateJoinEligibility(session.candidates.value, TARGET_HASH_HEX, NOW_EPOCH_SECONDS),
            "the shared predicate must still call this candidate ELIGIBLE -- its registry " +
                "record and receiver tier survived the source eviction untouched",
        )
        assertEquals(
            candidateAfterReobservation.resolvedEventIdHex,
            cardFor(session, TARGET_HASH_HEX).eventIdHex,
            "the card must agree with the shared ELIGIBLE verdict for the same candidate; a " +
                "null here means the card is still gated by a native cache that the eviction " +
                "cleared instead of reading the shared candidate directly",
        )
    }

    private fun cardFor(session: NearbyEventDiscoverySession, hashHex: String) =
        assertNotNull(
            session.cards.value.firstOrNull { it.eventCodeHashHex == hashHex },
            "no card projected for hash $hashHex",
        )

    private fun kotlinx.coroutines.test.TestScope.resolveVerifiedOpenDefinition(registry: FakeRegistry) {
        registry.completeLookup(NearbyEventIdLookup(true, TARGET_EVENT_ID_HEX, null))
        testScheduler.runCurrent()
        registry.completeDefinition(
            NearbyEventDefinitionVerification(
                isSuccess = true,
                joinMode = EventJoinMode.OPEN,
                eventIdHex = TARGET_EVENT_ID_HEX,
                eventCodeHashHex = TARGET_HASH_HEX,
                validFromEpochSeconds = 100L,
                validUntilEpochSeconds = 200L,
                keySetDigestHex = KEY_SET_DIGEST_HEX,
                definitionHashHex = DEFINITION_HASH_HEX,
                blockHashHex = BLOCK_HASH_HEX,
            ),
        )
        testScheduler.runCurrent()
    }

    /**
     * The clock sits inside the definition's 100..200s validity window on purpose, as in
     * NearbyEventReceiverStateAdapterTest -- the join predicate re-checks that window at
     * the moment it is asked.
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
        val TARGET_EVENT_ID_BYTES = ByteArray(32) { (it + 1).toByte() }
        val KEY_SET_DIGEST_BYTES = ByteArray(32) { (it + 100).toByte() }
        val TARGET_HASH = eventCodeHashForOpenEventV1(TARGET_EVENT_ID_BYTES)
        val JUNK_HASH = eventCodeHashForOpenEventV1(ByteArray(32) { 0x77 })
        val CONTAINER = byteArrayOf(3, 0, 1, 2)
        val TARGET_EVENT_ID_HEX = "0x" + TARGET_EVENT_ID_BYTES.toHex()
        val TARGET_HASH_HEX = TARGET_HASH.toHex()
        val DEFINITION_HASH_HEX = "ab".repeat(32)
        val BLOCK_HASH_HEX = "cd".repeat(32)

        /** Inside the fixture definition's 100..200 second validity window. */
        const val WINDOW_MIDPOINT_EPOCH_MILLIS = 150_000L
        const val NOW_EPOCH_SECONDS = 150L
        val KEY_SET_DIGEST_HEX = "0x" + KEY_SET_DIGEST_BYTES.toHex()

        fun ByteArray.toHex(): String = joinToString("") { "%02x".format(it.toInt() and 0xff) }
    }
}
