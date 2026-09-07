package org.levarac.beid.sensing

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.levarac.barnard.BarnardEventDefinitionV1
import org.levarac.parallax.discovery.NearbyEventReceiverState
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
    fun hintOnlyCandidateStaysUnverifiedAndKeepsTheExistingJoinGate() = runTest {
        val registry = FakeRegistry()
        val session = session(registry)
        session.recordHint("peripheral", "Beacon", EVENT_HASH, null, false, false)

        resolveVerifiedOpenDefinition(registry)

        assertEquals(NearbyEventReceiverState.UNVERIFIED, candidate(session).receiverState)
        assertEquals(EVENT_ID_HEX, session.cards.value.single().eventIdHex)
    }

    @Test
    fun radioSelfVerifiedEnvelopeIsNotJoinableUntilTheRegistryAgrees() = runTest {
        val registry = FakeRegistry()
        val session = session(registry)
        session.recordRadioSelfVerifiedEnvelope("peripheral", "Beacon", EVENT_HASH) { false }

        assertEquals(NearbyEventReceiverState.RADIO_SELF_VERIFIED, candidate(session).receiverState)
        resolveVerifiedOpenDefinition(registry)

        assertEquals(NearbyEventReceiverState.RADIO_SELF_VERIFIED, candidate(session).receiverState)
        assertNull(session.cards.value.single().eventIdHex)
    }

    @Test
    fun agreementOnAVerifiedDefinitionPromotesAndUnlocksJoin() = runTest {
        val registry = FakeRegistry()
        val session = session(registry)
        session.recordRadioSelfVerifiedEnvelope("peripheral", "Beacon", EVENT_HASH) { true }

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

        session.recordRadioSelfVerifiedEnvelope("peripheral", "Beacon", EVENT_HASH) { true }

        assertEquals(NearbyEventReceiverState.REGISTRY_VERIFIED, candidate(session).receiverState)
        assertEquals(EVENT_ID_HEX, session.cards.value.single().eventIdHex)
    }

    /**
     * The gate must be re-evaluated when the tier changes, not only when the
     * registry read completes: a disagreeing envelope arriving after a
     * successful resolution would otherwise leave the already-published
     * verified metadata on a card that is no longer allowed to be joinable.
     */
    @Test
    fun aDisagreeingEnvelopeArrivingAfterResolutionRevokesJoinability() = runTest {
        val registry = FakeRegistry()
        val session = session(registry)
        session.recordHint("peripheral", "Beacon", EVENT_HASH, null, false, false)
        resolveVerifiedOpenDefinition(registry)
        assertEquals(EVENT_ID_HEX, session.cards.value.single().eventIdHex)

        session.recordRadioSelfVerifiedEnvelope("peripheral", "Beacon", EVENT_HASH) { false }

        assertEquals(NearbyEventReceiverState.RADIO_SELF_VERIFIED, candidate(session).receiverState)
        assertNull(session.cards.value.single().eventIdHex)
        assertNull(session.cards.value.single().validFromEpochSeconds)
    }

    @Test
    fun barnardIsAskedWithTheDefinitionThisHostRead() = runTest {
        val registry = FakeRegistry()
        val session = session(registry)
        var seen: BarnardEventDefinitionV1? = null
        session.recordRadioSelfVerifiedEnvelope("peripheral", "Beacon", EVENT_HASH) {
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
        session.recordRadioSelfVerifiedEnvelope("peripheral", "Beacon", EVENT_HASH) { true }

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
        session.recordRadioSelfVerifiedEnvelope("peripheral", "Beacon", EVENT_HASH) { true }

        registry.completeLookup(NearbyEventIdLookup(true, EVENT_ID_HEX, null))
        runCurrent()
        registry.completeDefinition(verification(keySetDigestHex = null))
        runCurrent()

        assertEquals(NearbyEventReceiverState.RADIO_SELF_VERIFIED, candidate(session).receiverState)
    }

    @Test
    fun resetClearsTheReceiverStateAndTheCachedAgreement() = runTest {
        val registry = FakeRegistry()
        val session = session(registry)
        session.recordRadioSelfVerifiedEnvelope("peripheral", "Beacon", EVENT_HASH) { true }
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
    ) = NearbyEventDefinitionVerification(
        isSuccess = isSuccess,
        joinMode = EventJoinMode.OPEN,
        eventIdHex = EVENT_ID_HEX,
        eventCodeHashHex = EVENT_HASH.toHex(),
        validFromEpochSeconds = 100L,
        validUntilEpochSeconds = 200L,
        keySetDigestHex = keySetDigestHex,
    )

    private fun candidate(session: NearbyEventDiscoverySession) =
        assertNotNull(session.candidates.value.candidateAt(0))

    private fun kotlinx.coroutines.test.TestScope.session(registry: NearbyEventRegistry) =
        NearbyEventDiscoverySession(
            nowEpochMillis = { testScheduler.currentTime },
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
        val EVENT_ID_HEX = "0x" + EVENT_ID_BYTES.toHex()
        val KEY_SET_DIGEST_HEX = "0x" + KEY_SET_DIGEST_BYTES.toHex()

        fun ByteArray.toHex(): String = joinToString("") { "%02x".format(it.toInt() and 0xff) }
    }
}
