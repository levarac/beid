package org.levarac.beid.sensing

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.advanceTimeBy
import org.levarac.parallax.registry.EventJoinMode
import org.levarac.parallax.registry.eventCodeHashForOpenEventV1
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

@OptIn(ExperimentalCoroutinesApi::class)
class NearbyEventDiscoverySessionTest {
    @Test
    fun unresolvedCandidateShowsOnlyTheBeaconAnnouncementAndCannotJoin() = runTest {
        val registry = FakeNearbyEventRegistry()
        val session = session(registry)

        session.recordHint("peripheral", "Beacon announcement", EVENT_HASH, null, false, false)

        val card = session.cards.value.single()
        assertEquals(EVENT_HASH.toHex(), card.eventCodeHashHex)
        assertEquals("Beacon announcement", card.beaconDisplayName)
        assertNull(card.eventIdHex)
        assertNull(card.displayValidFromEpochSeconds)
        assertNull(card.displayValidUntilEpochSeconds)
    }

    @Test
    fun verifiedOpenDefinitionPublishesItsExactIdAndPeriod() = runTest {
        val registry = FakeNearbyEventRegistry()
        // Inside the definition's 100..200 second window: the join issuer
        // re-checks that window when it is asked, so a clock at zero would put
        // this candidate outside its own definition.
        val session = session(registry, baseEpochMillis = 150_000L)
        // An agreeing envelope, so the candidate genuinely reaches
        // REGISTRY_VERIFIED. Under the v1.0 nearby ruling a hint-only candidate
        // is not a joinable tier however well its registry read went, so
        // without this the card would correctly publish no id at all.
        session.recordRadioSelfVerifiedEnvelope(
            "peripheral",
            "Beacon announcement",
            EVENT_HASH,
            CONTAINER,
        ) { true }

        registry.completeLookup(NearbyEventIdLookup(true, EVENT_ID_HEX, null))
        runCurrent()
        registry.completeDefinition(eligibleDefinition())
        runCurrent()

        val card = session.cards.value.single()
        assertEquals(EVENT_ID_HEX, card.eventIdHex)
        assertEquals(100L, card.displayValidFromEpochSeconds)
        assertEquals(200L, card.displayValidUntilEpochSeconds)
    }

    @Test
    fun verifiedV2EnvelopeUsesItsEventIdWithoutHumanCodeHashLookup() = runTest {
        val registry = FakeNearbyEventRegistry()
        val session = session(registry, baseEpochMillis = 150_000L)

        session.recordRadioSelfVerifiedEnvelope(
            "peripheral",
            "Beacon announcement",
            EVENT_HASH,
            CONTAINER,
            verifiedEventIdHex = EVENT_ID_HEX,
        ) { true }
        runCurrent()

        assertEquals(0, registry.lookupRequests)
        assertEquals(listOf(EVENT_ID_HEX), registry.definitionEventIds)
        registry.completeDefinition(eligibleDefinition())
        runCurrent()

        val card = session.cards.value.single()
        assertEquals(EVENT_ID_HEX, card.eventIdHex)
        assertEquals(100L, card.displayValidFromEpochSeconds)
        assertEquals(200L, card.displayValidUntilEpochSeconds)
    }

    @Test
    fun gatedDefinitionRemainsNonJoinable() = runTest {
        val registry = FakeNearbyEventRegistry()
        val session = session(registry)
        session.recordHint("peripheral", "Beacon announcement", EVENT_HASH, null, false, false)

        registry.completeLookup(NearbyEventIdLookup(true, EVENT_ID_HEX, null))
        runCurrent()
        registry.completeDefinition(
            NearbyEventDefinitionVerification(
                true,
                EventJoinMode.GATED,
                EVENT_ID_HEX,
                EVENT_HASH.toHex(),
                100L,
                200L,
            ),
        )
        runCurrent()

        assertNull(session.cards.value.single().eventIdHex)
    }

    @Test
    fun verifiedDefinitionWithDifferentEventIdRemainsNonJoinable() = runTest {
        val registry = FakeNearbyEventRegistry()
        val session = session(registry)
        session.recordHint("peripheral", "Beacon announcement", EVENT_HASH, null, false, false)

        registry.completeLookup(NearbyEventIdLookup(true, EVENT_ID_HEX, null))
        runCurrent()
        registry.completeDefinition(
            NearbyEventDefinitionVerification(
                true,
                EventJoinMode.OPEN,
                "0x" + "ff".repeat(32),
                EVENT_HASH.toHex(),
                100L,
                200L,
            ),
        )
        runCurrent()

        assertNull(session.cards.value.single().eventIdHex)
    }

    @Test
    fun verifiedCardExpiresAtDefinitionValidUntilEvenWhileBeaconHintsContinue() = runTest {
        val registry = FakeNearbyEventRegistry()
        val session = session(registry)
        session.recordRadioSelfVerifiedEnvelope(
            "peripheral",
            "Beacon announcement",
            EVENT_HASH,
            CONTAINER,
        ) { true }
        registry.completeLookup(NearbyEventIdLookup(true, EVENT_ID_HEX, null))
        runCurrent()
        registry.completeDefinition(eligibleDefinition(validFrom = 0L, validUntil = 1L))
        runCurrent()
        assertEquals(EVENT_ID_HEX, session.cards.value.single().eventIdHex)

        advanceTimeBy(1_000L)
        runCurrent()
        session.recordHint("peripheral", "Beacon announcement", EVENT_HASH, null, false, false)
        assertEquals(EVENT_ID_HEX, session.cards.value.single().eventIdHex)

        advanceTimeBy(999L)
        runCurrent()
        session.recordHint("peripheral", "Beacon announcement", EVENT_HASH, null, false, false)
        assertEquals(EVENT_ID_HEX, session.cards.value.single().eventIdHex)

        advanceTimeBy(1L)
        runCurrent()
        session.recordHint("peripheral", "Beacon announcement", EVENT_HASH, null, false, false)

        assertNull(session.cards.value.single().eventIdHex)
    }

    /**
     * beid#584: a candidate whose registry read has not returned yet and one
     * whose read failed both rendered as "Checking", so the Pixel's permanent
     * failure was indistinguishable from a slow success.
     */
    @Test
    fun aCandidateWithNoFailedResolutionYetReportsChecking() = runTest {
        val registry = FakeNearbyEventRegistry()
        val session = session(registry)

        session.recordHint("peripheral", "Beacon announcement", EVENT_HASH, null, false, false)

        assertEquals(
            NearbyEventCardVerification.CHECKING,
            session.cards.value.single().verification,
        )
    }

    @Test
    fun aLookupThatCouldNotBeCompletedReportsRetrying() = runTest {
        val registry = FakeNearbyEventRegistry()
        val session = session(registry)
        session.recordHint("peripheral", "Beacon announcement", EVENT_HASH, null, false, false)

        registry.completeLookup(NearbyEventIdLookup(false, null, "protocol_error"))
        runCurrent()

        assertEquals(
            NearbyEventCardVerification.RETRYING,
            session.cards.value.single().verification,
        )
    }

    /**
     * The definition read is the leg that beid#584's unconfigured URL
     * template failed on, and it reaches the card through the same status.
     */
    @Test
    fun aDefinitionReadThatFailedReportsRetrying() = runTest {
        val registry = FakeNearbyEventRegistry()
        val session = session(registry, baseEpochMillis = 150_000L)
        session.recordHint("peripheral", "Beacon announcement", EVENT_HASH, null, false, false)

        registry.completeLookup(NearbyEventIdLookup(true, EVENT_ID_HEX, null))
        runCurrent()
        registry.completeDefinition(
            NearbyEventDefinitionVerification(false, null, null, null, null, null),
        )
        runCurrent()

        assertEquals(
            NearbyEventCardVerification.RETRYING,
            session.cards.value.single().verification,
        )
    }

    @Test
    fun anUnregisteredEventCodeIsReportedApartFromATransportFailure() = runTest {
        val registry = FakeNearbyEventRegistry()
        val session = session(registry)
        session.recordHint("peripheral", "Beacon announcement", EVENT_HASH, null, false, false)

        registry.completeLookup(NearbyEventIdLookup(false, null, "event_code_lookup_not_found"))
        runCurrent()

        assertEquals(
            NearbyEventCardVerification.NOT_REGISTERED,
            session.cards.value.single().verification,
        )
    }

    @Test
    fun aJoinableCandidateReportsReady() = runTest {
        val registry = FakeNearbyEventRegistry()
        val session = session(registry, baseEpochMillis = 150_000L)
        session.recordRadioSelfVerifiedEnvelope(
            "peripheral",
            "Beacon announcement",
            EVENT_HASH,
            CONTAINER,
        ) { true }

        registry.completeLookup(NearbyEventIdLookup(true, EVENT_ID_HEX, null))
        runCurrent()
        registry.completeDefinition(eligibleDefinition())
        runCurrent()

        assertEquals(
            NearbyEventCardVerification.READY,
            session.cards.value.single().verification,
        )
    }

    /**
     * beid#584's second defect: a resolution that failed was never tried
     * again. NOT_REGISTERED was terminal for the whole discovery TTL, and
     * LOOKUP_UNAVAILABLE was retried only when a beacon happened to be
     * re-observed. Nothing woke the session on its own.
     */
    @Test
    fun aFailedResolutionIsRetriedOnItsOwnTimerUntilItSucceeds() = runTest {
        val registry = FakeNearbyEventRegistry()
        val session = session(registry, baseEpochMillis = 150_000L)
        session.recordRadioSelfVerifiedEnvelope(
            "peripheral",
            "Beacon announcement",
            EVENT_HASH,
            CONTAINER,
        ) { true }
        assertEquals(1, registry.lookupRequests)

        registry.completeLookup(NearbyEventIdLookup(false, null, "protocol_error"))
        runCurrent()
        assertEquals(1, registry.lookupRequests)

        advanceTimeBy(FIRST_RETRY_DELAY_MILLIS)
        runCurrent()
        assertEquals(2, registry.lookupRequests)

        registry.completeLookup(NearbyEventIdLookup(false, null, "event_code_lookup_not_found"))
        runCurrent()
        advanceTimeBy(SECOND_RETRY_DELAY_MILLIS)
        runCurrent()
        assertEquals(3, registry.lookupRequests)

        registry.completeLookup(NearbyEventIdLookup(true, EVENT_ID_HEX, null))
        runCurrent()
        registry.completeDefinition(eligibleDefinition())
        runCurrent()

        val card = session.cards.value.single()
        assertEquals(EVENT_ID_HEX, card.eventIdHex)
        assertEquals(NearbyEventCardVerification.READY, card.verification)
    }

    /**
     * A session with no registry client never resolves, so it never fails,
     * so it must never schedule a retry either. This is the constructor's
     * default and the state before one is configured; the reducer-side
     * guarantee that an armed retry leaves no deadline behind for the timer
     * to wake on again is asserted in the shared
     * `NearbyEventRegistryRetryTest`, which can reach the failed record this
     * session cannot produce.
     */
    @Test
    fun aSessionWithNoRegistryClientSchedulesNoRetry() = runTest {
        val session = NearbyEventDiscoverySession(
            nowEpochMillis = { testScheduler.currentTime },
            coroutineScope = backgroundScope,
        )

        session.recordHint("peripheral", "Beacon announcement", EVENT_HASH, null, false, false)
        advanceTimeBy(FIRST_RETRY_DELAY_MILLIS * 4)
        runCurrent()

        assertEquals(1, session.cards.value.size)
        assertNull(session.candidates.value.nextRegistryRetryAtEpochMillis)
    }

    /**
     * PR 595 review, P1. The retry deadline used to be measured from the
     * candidate's most recent observation, which stops advancing as soon as
     * the beacon goes quiet. Once the backoff grew past the age of that
     * observation the deadline was already in the past, the session's wake-up
     * delay computed to zero, and the candidate went to back-to-back operator
     * requests until the TTL evicted it -- worst exactly when connectivity is
     * down, which is when the failures happen in the first place.
     *
     * No hint is recorded after the first, so nothing moves the observation
     * time. The assertion is that the fourth failure buys real time like the
     * three before it: no further request without the clock advancing.
     */
    @Test
    fun aSilentBeaconStillGetsARealWaitBetweenRetries() = runTest {
        val registry = FakeNearbyEventRegistry()
        val session = session(registry)
        session.recordHint("peripheral", "Beacon announcement", EVENT_HASH, null, false, false)
        assertEquals(1, registry.lookupRequests)

        listOf(FIRST_RETRY_DELAY_MILLIS, SECOND_RETRY_DELAY_MILLIS, STEADY_RETRY_INTERVAL_MILLIS)
            .forEachIndexed { index, delay ->
                registry.completeLookup(NearbyEventIdLookup(false, null, "protocol_error"))
                runCurrent()
                assertEquals(index + 1, registry.lookupRequests)
                advanceTimeBy(delay)
                runCurrent()
                assertEquals(index + 2, registry.lookupRequests)
            }

        // The fourth failure. Its backoff (120 s) is by now far longer than
        // the age of the single observation, which is what used to collapse.
        registry.completeLookup(NearbyEventIdLookup(false, null, "protocol_error"))
        runCurrent()

        assertEquals(4, registry.lookupRequests)
        advanceTimeBy(STEADY_RETRY_INTERVAL_MILLIS - 1L)
        runCurrent()
        assertEquals(4, registry.lookupRequests)
        advanceTimeBy(1L)
        runCurrent()
        assertEquals(5, registry.lookupRequests)
    }

    @Test
    fun everyResolutionAttemptAndOutcomeReachesTheLog() = runTest {
        val registry = FakeNearbyEventRegistry()
        val lines = mutableListOf<String>()
        val session = session(registry, baseEpochMillis = 150_000L, log = lines::add)
        session.recordHint("peripheral", "Beacon announcement", EVENT_HASH, null, false, false)

        registry.completeLookup(NearbyEventIdLookup(false, null, "protocol_error"))
        runCurrent()
        advanceTimeBy(FIRST_RETRY_DELAY_MILLIS)
        runCurrent()

        val hash = EVENT_HASH.toHex()
        assertEquals(
            listOf(
                "registry_resolution_begin hash=$hash attempt=1",
                "registry_resolution_outcome hash=$hash stage=lookup result=LOOKUP_UNAVAILABLE " +
                    "status=LOOKUP_UNAVAILABLE attempt=1 retry_in_ms=$FIRST_RETRY_DELAY_MILLIS",
                "registry_resolution_begin hash=$hash attempt=2",
            ),
            lines,
        )
    }

    @Test
    fun aSuccessfulResolutionSaysSoInTheLogAndSchedulesNoRetry() = runTest {
        val registry = FakeNearbyEventRegistry()
        val lines = mutableListOf<String>()
        val session = session(registry, baseEpochMillis = 150_000L, log = lines::add)
        session.recordRadioSelfVerifiedEnvelope(
            "peripheral",
            "Beacon announcement",
            EVENT_HASH,
            CONTAINER,
        ) { true }

        registry.completeLookup(NearbyEventIdLookup(true, EVENT_ID_HEX, null))
        runCurrent()
        registry.completeDefinition(eligibleDefinition())
        runCurrent()

        val hash = EVENT_HASH.toHex()
        assertEquals(
            listOf(
                "registry_resolution_begin hash=$hash attempt=1",
                "registry_resolution_outcome hash=$hash stage=definition result=VERIFIED " +
                    "status=REGISTERED_VIA_OPERATOR_LOOKUP attempt=1 retry_in_ms=none",
            ),
            lines,
        )
    }

    private fun kotlinx.coroutines.test.TestScope.session(
        registry: NearbyEventRegistry,
        baseEpochMillis: Long = 0L,
        log: (String) -> Unit = {},
    ): NearbyEventDiscoverySession =
        NearbyEventDiscoverySession(
            nowEpochMillis = { baseEpochMillis + testScheduler.currentTime },
            coroutineScope = backgroundScope,
            registry = registry,
            log = log,
        )

    private class FakeNearbyEventRegistry : NearbyEventRegistry {
        private lateinit var lookupCompletion: (NearbyEventIdLookup) -> Unit
        private lateinit var definitionCompletion: (NearbyEventDefinitionVerification) -> Unit
        var lookupRequests = 0
        val definitionEventIds = mutableListOf<String>()

        override fun resolveEventIdByCodeHash(
            hashHex: String,
            completion: (NearbyEventIdLookup) -> Unit,
        ): NearbyEventRegistryRequest {
            lookupRequests += 1
            lookupCompletion = completion
            return NearbyEventRegistryRequest {}
        }

        override fun resolveEventDefinition(
            eventIdHex: String,
            useTimeEpochSeconds: Long,
            completion: (NearbyEventDefinitionVerification) -> Unit,
        ): NearbyEventRegistryRequest {
            definitionEventIds += eventIdHex
            definitionCompletion = completion
            return NearbyEventRegistryRequest {}
        }

        fun completeLookup(result: NearbyEventIdLookup) = lookupCompletion(result)

        fun completeDefinition(result: NearbyEventDefinitionVerification) = definitionCompletion(result)
    }

    /** A definition an eligible candidate can actually be built from (beid#374). */
    private fun eligibleDefinition(
        validFrom: Long = 100L,
        validUntil: Long = 200L,
    ) = NearbyEventDefinitionVerification(
        isSuccess = true,
        joinMode = EventJoinMode.OPEN,
        eventIdHex = EVENT_ID_HEX,
        eventCodeHashHex = EVENT_HASH.toHex(),
        validFromEpochSeconds = validFrom,
        validUntilEpochSeconds = validUntil,
        keySetDigestHex = KEY_SET_DIGEST_HEX,
        definitionHashHex = DEFINITION_HASH_HEX,
        blockHashHex = BLOCK_HASH_HEX,
    )

    companion object {
        val EVENT_ID_BYTES = ByteArray(32) { (it + 1).toByte() }
        val KEY_SET_DIGEST_HEX = "0x" + ByteArray(32) { (it + 100).toByte() }.toHex()
        val DEFINITION_HASH_HEX = "ab".repeat(32)
        val BLOCK_HASH_HEX = "cd".repeat(32)
        val CONTAINER = byteArrayOf(3, 0, 1, 2)
        val EVENT_HASH = eventCodeHashForOpenEventV1(EVENT_ID_BYTES)
        val EVENT_ID_HEX = "0x" + EVENT_ID_BYTES.toHex()

        /** Mirrors the shared backoff schedule; see `NearbyEventDiscovery.kt`. */
        const val FIRST_RETRY_DELAY_MILLIS = 5_000L
        const val SECOND_RETRY_DELAY_MILLIS = 30_000L
        const val STEADY_RETRY_INTERVAL_MILLIS = 120_000L

        fun ByteArray.toHex(): String = joinToString("") { "%02x".format(it.toInt() and 0xff) }
    }
}
