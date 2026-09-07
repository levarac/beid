package org.levarac.parallax.discovery

import org.levarac.parallax.registry.EventJoinMode
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class NearbyEventRegistryResolutionTest {
    @Test
    fun openDefinitionWhoseB005SignedAndRecomputedHashesMatchPublishesRegisteredEventId() {
        val store = createNearbyEventDiscoveryStore()
        val eventId = (0..31).joinToString("") { it.toString(16).padStart(2, '0') }
        val hash = "6c86c6aac5fb24bc"
        recordNearbyEventHint(store, "p", "Event", hash.hexBytes(), null, false, false, 1L)
        val attempt = assertNotNull(beginNearbyEventRegistryResolutionFromHex(store, hash))
        assertNull(beginNearbyEventRegistryResolutionFromHex(store, hash))
        val update = completeNearbyEventRegistryResolutionFromHex(
            store = store,
            attempt = attempt,
            result = NearbyEventRegistryResolutionResult.VERIFIED,
            resolvedEventIdHex = "0x$eventId",
            verifiedDefinitionJoinMode = EventJoinMode.OPEN,
            verifiedDefinitionEventIdHex = eventId,
            verifiedDefinitionEventCodeHashHex = hash,
            envelopeAgreesWithRegistry = false,
        )
        val candidate = update.snapshot.candidateAt(0)!!
        assertEquals(NearbyEventRegistryStatus.REGISTERED_VIA_OPERATOR_LOOKUP, candidate.registryStatus)
        assertEquals("0x$eventId", candidate.resolvedEventIdHex)
    }

    @Test
    fun missingVerifiedDefinitionHashNeverPublishesRegisteredStatus() {
        val candidate = completeVerifiedOpenDefinition(definitionHash = null)

        assertEquals(NearbyEventRegistryStatus.LOOKUP_UNAVAILABLE, candidate.registryStatus)
        assertNull(candidate.resolvedEventIdHex)
    }

    @Test
    fun mismatchedVerifiedDefinitionHashNeverPublishesRegisteredStatus() {
        val candidate = completeVerifiedOpenDefinition(definitionHash = "08090a0b0c0d0e0f")

        assertEquals(NearbyEventRegistryStatus.LOOKUP_UNAVAILABLE, candidate.registryStatus)
        assertNull(candidate.resolvedEventIdHex)
    }

    @Test
    fun gatedAndLegacyDefinitionsRemainNonDiscoverable() {
        listOf(EventJoinMode.GATED, null).forEach { mode ->
            val candidate = completeVerifiedDefinition(
                eventCodeHash = CANONICAL_HASH,
                definitionHash = CANONICAL_HASH,
                joinMode = mode,
            )

            assertEquals(NearbyEventRegistryStatus.LOOKUP_UNAVAILABLE, candidate.registryStatus)
            assertNull(candidate.resolvedEventIdHex)
        }
    }

    @Test
    fun matchingB005AndSignedHashCannotHideARecomputedCanonicalHashMismatch() {
        val candidate = completeVerifiedDefinition(
            eventCodeHash = "0001020304050607",
            definitionHash = "0001020304050607",
            joinMode = EventJoinMode.OPEN,
        )

        assertEquals(NearbyEventRegistryStatus.LOOKUP_UNAVAILABLE, candidate.registryStatus)
        assertNull(candidate.resolvedEventIdHex)
    }

    @Test
    fun lookupEventIdMustMatchTheAuthorityVerifiedDefinitionEventId() {
        val candidate = completeVerifiedDefinition(
            eventCodeHash = CANONICAL_HASH,
            definitionHash = CANONICAL_HASH,
            joinMode = EventJoinMode.OPEN,
            resolvedEventId = "ab".repeat(32),
        )

        assertEquals(NearbyEventRegistryStatus.LOOKUP_UNAVAILABLE, candidate.registryStatus)
        assertNull(candidate.resolvedEventIdHex)
    }

    @Test
    fun expiryDropsVerdictAndReappearanceStartsUnresolved() {
        val store = createNearbyEventDiscoveryStore()
        val bytes = ByteArray(8)
        recordNearbyEventHint(store, "p", "Event", bytes, null, false, false, 0L)
        val attempt = assertNotNull(beginNearbyEventRegistryResolutionFromHex(store, "0000000000000000"))
        completeNearbyEventRegistryResolutionFromHex(
            store,
            attempt,
            NearbyEventRegistryResolutionResult.NOT_REGISTERED,
            null,
            null,
            null,
            null,
            false,
        )
        refreshNearbyEventDiscovery(store, 300_000L)
        recordNearbyEventHint(store, "p2", "Event", bytes, null, false, false, 300_001L)
        val candidate = store.snapshot.candidateAt(0)!!
        assertEquals(NearbyEventRegistryStatus.UNRESOLVED, candidate.registryStatus)
        assertNull(candidate.resolvedEventIdHex)
    }

    @Test
    fun staleCompletionFromBeforeResetCannotCompleteSameHashReplacementAttempt() {
        val store = createNearbyEventDiscoveryStore()
        recordNearbyEventHint(store, "a", "Event A", CANONICAL_HASH.hexBytes(), null, false, false, 0L)
        val attemptA = assertNotNull(beginNearbyEventRegistryResolutionFromHex(store, CANONICAL_HASH))

        resetNearbyEventDiscovery(store)
        recordNearbyEventHint(store, "b", "Event B", CANONICAL_HASH.hexBytes(), null, false, false, 1L)
        val attemptB = assertNotNull(beginNearbyEventRegistryResolutionFromHex(store, CANONICAL_HASH))

        val stale = completeVerifiedOpenDefinition(store, attemptA)
        assertFalse(stale.changed)
        assertEquals(
            NearbyEventRegistryStatus.UNRESOLVED,
            assertNotNull(stale.snapshot.candidateAt(0)).registryStatus,
        )

        val current = completeVerifiedOpenDefinition(store, attemptB)
        assertTrue(current.changed)
        assertEquals(
            NearbyEventRegistryStatus.REGISTERED_VIA_OPERATOR_LOOKUP,
            assertNotNull(current.snapshot.candidateAt(0)).registryStatus,
        )
    }

    @Test
    fun staleCompletionFromExpiredAttemptCannotPoisonSameHashReplacementAttempt() {
        val store = createNearbyEventDiscoveryStore()
        recordNearbyEventHint(store, "a", "Event A", CANONICAL_HASH.hexBytes(), null, false, false, 0L)
        val attemptA = assertNotNull(beginNearbyEventRegistryResolutionFromHex(store, CANONICAL_HASH))

        refreshNearbyEventDiscovery(store, 300_000L)
        recordNearbyEventHint(store, "b", "Event B", CANONICAL_HASH.hexBytes(), null, false, false, 300_001L)
        val attemptB = assertNotNull(beginNearbyEventRegistryResolutionFromHex(store, CANONICAL_HASH))

        val stale = completeNearbyEventRegistryResolutionFromHex(
            store = store,
            attempt = attemptA,
            result = NearbyEventRegistryResolutionResult.LOOKUP_UNAVAILABLE,
            resolvedEventIdHex = null,
            verifiedDefinitionJoinMode = null,
            verifiedDefinitionEventIdHex = null,
            verifiedDefinitionEventCodeHashHex = null,
            envelopeAgreesWithRegistry = false,
        )
        assertFalse(stale.changed)
        assertEquals(
            NearbyEventRegistryStatus.UNRESOLVED,
            assertNotNull(stale.snapshot.candidateAt(0)).registryStatus,
        )

        val current = completeVerifiedOpenDefinition(store, attemptB)
        assertTrue(current.changed)
        assertEquals(
            NearbyEventRegistryStatus.REGISTERED_VIA_OPERATOR_LOOKUP,
            assertNotNull(current.snapshot.candidateAt(0)).registryStatus,
        )
    }

    private fun completeVerifiedOpenDefinition(
        definitionHash: String?,
    ): NearbyEventCandidate = completeVerifiedDefinition(
        eventCodeHash = CANONICAL_HASH,
        definitionHash = definitionHash,
        joinMode = EventJoinMode.OPEN,
    )

    private fun completeVerifiedDefinition(
        eventCodeHash: String,
        definitionHash: String?,
        joinMode: EventJoinMode?,
        resolvedEventId: String = CANONICAL_EVENT_ID,
    ): NearbyEventCandidate {
        val store = createNearbyEventDiscoveryStore()
        recordNearbyEventHint(
            store,
            "p",
            "Event",
            eventCodeHash.hexBytes(),
            null,
            false,
            false,
            1L,
        )
        val attempt = assertNotNull(beginNearbyEventRegistryResolutionFromHex(store, eventCodeHash))
        return completeNearbyEventRegistryResolutionFromHex(
            store = store,
            attempt = attempt,
            result = NearbyEventRegistryResolutionResult.VERIFIED,
            resolvedEventIdHex = "0x$resolvedEventId",
            verifiedDefinitionJoinMode = joinMode,
            verifiedDefinitionEventIdHex = CANONICAL_EVENT_ID,
            verifiedDefinitionEventCodeHashHex = definitionHash,
            envelopeAgreesWithRegistry = false,
        ).snapshot.candidateAt(0)!!
    }

    private fun completeVerifiedOpenDefinition(
        store: NearbyEventDiscoveryStore,
        attempt: NearbyEventRegistryResolutionAttempt,
    ): NearbyEventDiscoveryUpdate = completeNearbyEventRegistryResolutionFromHex(
        store = store,
        attempt = attempt,
        result = NearbyEventRegistryResolutionResult.VERIFIED,
        resolvedEventIdHex = "0x$CANONICAL_EVENT_ID",
        verifiedDefinitionJoinMode = EventJoinMode.OPEN,
        verifiedDefinitionEventIdHex = CANONICAL_EVENT_ID,
        verifiedDefinitionEventCodeHashHex = CANONICAL_HASH,
        envelopeAgreesWithRegistry = false,
    )

    private companion object {
        const val CANONICAL_EVENT_ID =
            "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
        const val CANONICAL_HASH = "6c86c6aac5fb24bc"
    }
}

private fun String.hexBytes(): ByteArray =
    chunked(2).map { it.toInt(16).toByte() }.toByteArray()
