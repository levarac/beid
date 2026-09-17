package org.levarac.parallax.discovery

import org.levarac.parallax.registry.EventJoinMode
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

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
 *
 * The reducer holds no clock. A completion therefore records only how long to
 * wait, and the next call that carries a clock turns that into a deadline.
 * That indirection is not incidental: anchoring the deadline to the
 * candidate's last observation instead, which was this change's first form,
 * collapses to a zero-length wait as soon as the backoff outgrows the age of
 * that observation (PR 595 review, P1).
 */
class NearbyEventRegistryRetryTest {

    @Test
    fun aResolverThatFailsTwiceThenSucceedsEndsWithTheEventIdPublished() {
        val store = createNearbyEventDiscoveryStore()
        recordNearbyEventHint(store, "p", "Event", HASH.hexBytes(), null, false, false, 0L)

        failOnce(store, NearbyEventRegistryResolutionResult.LOOKUP_UNAVAILABLE, at = 0L)
        val secondAttemptAt = FIRST_RETRY_DELAY_MILLIS
        recordNearbyEventHint(store, "p", "Event", HASH.hexBytes(), null, false, false, secondAttemptAt)
        failOnce(store, NearbyEventRegistryResolutionResult.NOT_REGISTERED, at = secondAttemptAt)

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
        failOnce(store, NearbyEventRegistryResolutionResult.LOOKUP_UNAVAILABLE, at = 0L)

        recordNearbyEventHint(
            store, "p", "Event", HASH.hexBytes(), null, false, false, FIRST_RETRY_DELAY_MILLIS - 1L,
        )

        assertNull(beginNearbyEventRegistryResolutionFromHex(store, HASH))
    }

    /**
     * PR 595 review, P1. The deadline must be measured from a clock reading
     * taken at or after the completion, never from the candidate's last
     * observation: a beacon that goes quiet stops advancing that observation,
     * and once the backoff is longer than its age every deadline is already
     * in the past. A host that wakes on these deadlines then runs back to
     * back operator requests until the TTL evicts the candidate.
     */
    @Test
    fun aDeadlineIsAlwaysAheadOfTheClockThatSetItEvenForASilentBeacon() {
        val store = createNearbyEventDiscoveryStore()
        recordNearbyEventHint(store, "p", "Event", HASH.hexBytes(), null, false, false, 0L)

        var now = 0L
        repeat(4) {
            failOnce(store, NearbyEventRegistryResolutionResult.LOOKUP_UNAVAILABLE, at = now)
            val deadline = assertNotNull(store.snapshot.nextRegistryRetryAtEpochMillis)
            assertTrue(
                deadline > now,
                "a deadline of $deadline set at $now is already due and buys no wait at all",
            )
            now = deadline
            refreshNearbyEventDiscovery(store, now)
        }
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
        failOnce(store, NearbyEventRegistryResolutionResult.NOT_REGISTERED, at = 0L)

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
            failOnce(store, NearbyEventRegistryResolutionResult.LOOKUP_UNAVAILABLE, at = now)
            val deadline = assertNotNull(store.snapshot.nextRegistryRetryAtEpochMillis)
            observed += deadline - now
            now = deadline
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
        failOnce(store, NearbyEventRegistryResolutionResult.LOOKUP_UNAVAILABLE, at = 0L)

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
        failOnce(store, NearbyEventRegistryResolutionResult.LOOKUP_UNAVAILABLE, at = 0L)

        assertEquals(FIRST_RETRY_DELAY_MILLIS, store.snapshot.nextRegistryRetryAtEpochMillis)
    }

    /**
     * PR 595 review, P2c. Source eviction at `MAX_LIVE_SOURCE_COUNT` removes
     * a hash's last source without touching its registry record, so the
     * completion that arrives afterwards finds no live source, returns early
     * and leaves `attempt` set. The slot is then held forever: the hash can
     * be re-admitted by a later beacon and `begin` will still refuse it.
     */
    @Test
    fun aCompletionStrandedBySourceEvictionReleasesItsSlot() {
        val store = createNearbyEventDiscoveryStore()
        recordNearbyEventHint(store, "p", "Event", HASH.hexBytes(), null, false, false, 0L)
        val attempt = assertNotNull(beginNearbyEventRegistryResolutionFromHex(store, HASH))
        evictTheOldestSourceWithFreshTraffic(store, after = 0L)

        completeVerified(store, attempt)
        recordNearbyEventHint(store, "p", "Event", HASH.hexBytes(), null, false, false, 400L)

        assertNotNull(beginNearbyEventRegistryResolutionFromHex(store, HASH))
    }

    /**
     * The same stranding, one state later, which the review did not name: the
     * attempt being stranded is a *retry*, so the record's status is a failed
     * verdict rather than UNRESOLVED and its due flag was consumed when the
     * retry began. Releasing the slot alone is not enough -- `begin` refuses
     * anything that is neither UNRESOLVED nor due -- so the wait has to be
     * put back too.
     */
    @Test
    fun aStrandedRetryIsRescheduledRatherThanLeftUnreachable() {
        val store = createNearbyEventDiscoveryStore()
        recordNearbyEventHint(store, "p", "Event", HASH.hexBytes(), null, false, false, 0L)
        failOnce(store, NearbyEventRegistryResolutionResult.LOOKUP_UNAVAILABLE, at = 0L)
        recordNearbyEventHint(
            store, "p", "Event", HASH.hexBytes(), null, false, false, FIRST_RETRY_DELAY_MILLIS,
        )
        val retry = assertNotNull(beginNearbyEventRegistryResolutionFromHex(store, HASH))
        evictTheOldestSourceWithFreshTraffic(store, after = FIRST_RETRY_DELAY_MILLIS)

        completeVerified(store, retry)
        val readmittedAt = FIRST_RETRY_DELAY_MILLIS + MAX_LIVE_SOURCE_COUNT + 1L
        recordNearbyEventHint(store, "p", "Event", HASH.hexBytes(), null, false, false, readmittedAt)
        refreshNearbyEventDiscovery(store, readmittedAt + SECOND_RETRY_DELAY_MILLIS)

        assertNotNull(beginNearbyEventRegistryResolutionFromHex(store, HASH))
    }

    /**
     * Fills the live-source table with traffic newer than [after] so the
     * oldest source, the test's own, is the one eviction takes.
     */
    private fun evictTheOldestSourceWithFreshTraffic(
        store: NearbyEventDiscoveryStore,
        after: Long,
    ) {
        repeat(MAX_LIVE_SOURCE_COUNT) { index ->
            val hash = index.toLong().toString(16).padStart(15, '0') + "f"
            recordNearbyEventHint(
                store, "filler-$index", "Other", hash.hexBytes(), null, false, false, after + 1L + index,
            )
        }
    }

    /**
     * One failed resolution, followed by the clock reading that turns its
     * wait into a deadline. [at] is what a host's own clock would read when
     * it next enters the reducer, which on Android is immediately after the
     * completion.
     */
    private fun failOnce(
        store: NearbyEventDiscoveryStore,
        result: NearbyEventRegistryResolutionResult,
        at: Long,
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
        refreshNearbyEventDiscovery(store, at)
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

        /** Mirrors `NearbyEventDiscovery.kt`'s own live-source ceiling. */
        const val MAX_LIVE_SOURCE_COUNT = 256
    }
}
