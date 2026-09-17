package org.levarac.parallax.discovery

import org.levarac.parallax.registry.EventJoinMode
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull

/**
 * beid#584: a resolution that failed was never tried again.
 *
 * `beginNearbyEventRegistryResolutionFromHex` accepted a candidate only while
 * its record was UNRESOLVED, and a NOT_REGISTERED verdict left that record in
 * place for the whole discovery TTL. A LOOKUP_UNAVAILABLE verdict was retried,
 * but on *every* re-observation with no delay at all, which is the opposite
 * failure: a beacon transmitting several times a second drove one operator
 * request per hint.
 *
 * Both are replaced by one bounded schedule that lives here rather than in
 * either host, so iOS and Android retry the same candidate at the same times.
 */
class NearbyEventRegistryRetryTest {

    @Test
    fun aResolverThatFailsTwiceThenSucceedsEndsWithTheEventIdPublished() {
        val store = createNearbyEventDiscoveryStore()
        recordNearbyEventHint(store, "p", "Event", HASH.hexBytes(), null, false, false, 0L)

        failOnce(store, NearbyEventRegistryResolutionResult.LOOKUP_UNAVAILABLE)
        val secondAttemptAt = 0L + FIRST_RETRY_DELAY_MILLIS
        recordNearbyEventHint(store, "p", "Event", HASH.hexBytes(), null, false, false, secondAttemptAt)
        failOnce(store, NearbyEventRegistryResolutionResult.NOT_REGISTERED)

        val thirdAttemptAt = secondAttemptAt + SECOND_RETRY_DELAY_MILLIS
        recordNearbyEventHint(store, "p", "Event", HASH.hexBytes(), null, false, false, thirdAttemptAt)
        val attempt = assertNotNull(beginNearbyEventRegistryResolutionFromHex(store, HASH))
        val update = completeVerified(store, attempt)

        val candidate = assertNotNull(update.snapshot.candidateAt(0))
        assertEquals(NearbyEventRegistryStatus.REGISTERED_VIA_OPERATOR_LOOKUP, candidate.registryStatus)
        assertEquals(EVENT_ID, candidate.resolvedEventIdHex)
    }

    @Test
    fun aFailedCandidateIsNotRetriedBeforeItsBackoffElapses() {
        val store = createNearbyEventDiscoveryStore()
        recordNearbyEventHint(store, "p", "Event", HASH.hexBytes(), null, false, false, 0L)
        failOnce(store, NearbyEventRegistryResolutionResult.LOOKUP_UNAVAILABLE)

        recordNearbyEventHint(
            store, "p", "Event", HASH.hexBytes(), null, false, false, FIRST_RETRY_DELAY_MILLIS - 1L,
        )

        assertNull(beginNearbyEventRegistryResolutionFromHex(store, HASH))
    }

    /**
     * The verdict a failed candidate carries is what the card shows, so it
     * must survive until a retry actually replaces it. An earlier design
     * reset the record to UNRESOLVED when the retry was armed, which put the
     * card back to "Checking" between attempts — the state beid#584 exists to
     * get rid of.
     */
    @Test
    fun anArmedRetryKeepsTheVerdictTheCardIsShowing() {
        val store = createNearbyEventDiscoveryStore()
        recordNearbyEventHint(store, "p", "Event", HASH.hexBytes(), null, false, false, 0L)
        failOnce(store, NearbyEventRegistryResolutionResult.NOT_REGISTERED)

        val update = recordNearbyEventHint(
            store, "p", "Event", HASH.hexBytes(), null, false, false, FIRST_RETRY_DELAY_MILLIS,
        )

        assertEquals(
            NearbyEventRegistryStatus.NOT_REGISTERED,
            assertNotNull(update.snapshot.candidateAt(0)).registryStatus,
        )
        assertNotNull(beginNearbyEventRegistryResolutionFromHex(store, HASH))
    }

    @Test
    fun theBackoffGrowsAndThenHoldsAtItsLongestInterval() {
        val store = createNearbyEventDiscoveryStore()
        recordNearbyEventHint(store, "p", "Event", HASH.hexBytes(), null, false, false, 0L)

        val observed = mutableListOf<Long>()
        var now = 0L
        repeat(4) {
            failOnce(store, NearbyEventRegistryResolutionResult.LOOKUP_UNAVAILABLE)
            val retryAt = assertNotNull(
                assertNotNull(store.snapshot.candidateAt(0)).registryRetryAtEpochMillis,
            )
            observed += retryAt - now
            now = retryAt
            recordNearbyEventHint(store, "p", "Event", HASH.hexBytes(), null, false, false, now)
        }

        assertEquals(
            listOf(
                FIRST_RETRY_DELAY_MILLIS,
                SECOND_RETRY_DELAY_MILLIS,
                STEADY_RETRY_INTERVAL_MILLIS,
                STEADY_RETRY_INTERVAL_MILLIS,
            ),
            observed,
        )
    }

    /**
     * A retry a host never consumes must not stay due in the snapshot: the
     * Android session schedules its next wake-up from this value, and a
     * deadline that stays in the past is a wake-up loop.
     */
    @Test
    fun anArmedRetryLeavesNoDeadlineBehindForTheHostToWakeOnAgain() {
        val store = createNearbyEventDiscoveryStore()
        recordNearbyEventHint(store, "p", "Event", HASH.hexBytes(), null, false, false, 0L)
        failOnce(store, NearbyEventRegistryResolutionResult.LOOKUP_UNAVAILABLE)

        val refreshed = refreshNearbyEventDiscovery(store, FIRST_RETRY_DELAY_MILLIS)

        assertNull(refreshed.snapshot.nextRegistryRetryAtEpochMillis)
        assertNull(assertNotNull(refreshed.snapshot.candidateAt(0)).registryRetryAtEpochMillis)
    }

    @Test
    fun aSucceededResolutionIsNeverRetried() {
        val store = createNearbyEventDiscoveryStore()
        recordNearbyEventHint(store, "p", "Event", HASH.hexBytes(), null, false, false, 0L)
        val attempt = assertNotNull(beginNearbyEventRegistryResolutionFromHex(store, HASH))
        completeVerified(store, attempt)

        recordNearbyEventHint(
            store, "p", "Event", HASH.hexBytes(), null, false, false, STEADY_RETRY_INTERVAL_MILLIS,
        )

        assertNull(store.snapshot.nextRegistryRetryAtEpochMillis)
        assertNull(beginNearbyEventRegistryResolutionFromHex(store, HASH))
    }

    @Test
    fun theHostCanSeeWhenTheNextRetryIsDue() {
        val store = createNearbyEventDiscoveryStore()
        recordNearbyEventHint(store, "p", "Event", HASH.hexBytes(), null, false, false, 0L)
        failOnce(store, NearbyEventRegistryResolutionResult.LOOKUP_UNAVAILABLE)

        assertEquals(FIRST_RETRY_DELAY_MILLIS, store.snapshot.nextRegistryRetryAtEpochMillis)
    }

    private fun failOnce(
        store: NearbyEventDiscoveryStore,
        result: NearbyEventRegistryResolutionResult,
    ) {
        val attempt = assertNotNull(beginNearbyEventRegistryResolutionFromHex(store, HASH))
        completeNearbyEventRegistryResolutionFromHex(
            store = store,
            attempt = attempt,
            result = result,
            resolvedEventIdHex = null,
            verifiedDefinitionJoinMode = null,
            verifiedDefinitionEventIdHex = null,
            verifiedDefinitionEventCodeHashHex = null,
            envelopeAgreesWithRegistry = false,
        )
    }

    private fun completeVerified(
        store: NearbyEventDiscoveryStore,
        attempt: NearbyEventRegistryResolutionAttempt,
    ): NearbyEventDiscoveryUpdate = completeNearbyEventRegistryResolutionFromHex(
        store = store,
        attempt = attempt,
        result = NearbyEventRegistryResolutionResult.VERIFIED,
        resolvedEventIdHex = EVENT_ID,
        verifiedDefinitionJoinMode = EventJoinMode.OPEN,
        verifiedDefinitionEventIdHex = EVENT_ID,
        verifiedDefinitionEventCodeHashHex = HASH,
        envelopeAgreesWithRegistry = false,
    )

    private fun String.hexBytes(): ByteArray =
        ByteArray(length / 2) { ((this[it * 2].digitToInt(16) shl 4) or this[it * 2 + 1].digitToInt(16)).toByte() }

    private companion object {
        const val EVENT_ID = "0x" + "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
        const val HASH = "6c86c6aac5fb24bc"
        const val FIRST_RETRY_DELAY_MILLIS = 5_000L
        const val SECOND_RETRY_DELAY_MILLIS = 30_000L
        const val STEADY_RETRY_INTERVAL_MILLIS = 120_000L
    }
}
