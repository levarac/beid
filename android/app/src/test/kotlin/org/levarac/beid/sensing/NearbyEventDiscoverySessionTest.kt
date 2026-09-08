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
        val session = session(registry)
        session.recordHint("peripheral", "Beacon announcement", EVENT_HASH, null, false, false)

        registry.completeLookup(NearbyEventIdLookup(true, EVENT_ID_HEX, null))
        runCurrent()
        registry.completeDefinition(
            NearbyEventDefinitionVerification(
                isSuccess = true,
                joinMode = EventJoinMode.OPEN,
                eventIdHex = EVENT_ID_HEX,
                eventCodeHashHex = EVENT_HASH.toHex(),
                validFromEpochSeconds = 100L,
                validUntilEpochSeconds = 200L,
            ),
        )
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
        session.recordHint("peripheral", "Beacon announcement", EVENT_HASH, null, false, false)
        registry.completeLookup(NearbyEventIdLookup(true, EVENT_ID_HEX, null))
        runCurrent()
        registry.completeDefinition(
            NearbyEventDefinitionVerification(true, EventJoinMode.OPEN, EVENT_ID_HEX, EVENT_HASH.toHex(), 0L, 1L),
        )
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

    private fun kotlinx.coroutines.test.TestScope.session(registry: NearbyEventRegistry): NearbyEventDiscoverySession =
        NearbyEventDiscoverySession(
            nowEpochMillis = { testScheduler.currentTime },
            coroutineScope = backgroundScope,
            registry = registry,
        )

    private class FakeNearbyEventRegistry : NearbyEventRegistry {
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

    companion object {
        val EVENT_ID_BYTES = ByteArray(32) { (it + 1).toByte() }
        val EVENT_HASH = eventCodeHashForOpenEventV1(EVENT_ID_BYTES)
        val EVENT_ID_HEX = "0x" + EVENT_ID_BYTES.toHex()

        fun ByteArray.toHex(): String = joinToString("") { "%02x".format(it.toInt() and 0xff) }
    }
}
