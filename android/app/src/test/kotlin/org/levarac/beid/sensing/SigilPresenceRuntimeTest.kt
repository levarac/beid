package org.levarac.beid.sensing

import java.nio.file.Files
import java.util.UUID
import org.levarac.beid.persistence.SigilPresenceStore
import org.levarac.beid.persistence.SigilPresenceStoreException
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotNull
import kotlin.test.assertNull

/**
 * beid#722 cross-check: the Android native path (Barnard-shaped observations
 * through [AggregationRuntime], tokens topped up by [SigilPresenceRuntime],
 * persisted by [SigilPresenceStore], reloaded from disk) produces text
 * byte-identical to the literal iOS pins for the same input.
 */
class SigilPresenceRuntimeTest {
    private fun tokens(vararg values: Int): SigilPresenceTokenSource {
        val queue = ArrayDeque(values.map { it.toString(16).padStart(32, '0') })
        return SigilPresenceTokenSource { queue.removeFirstOrNull() }
    }

    @Test
    fun theAndroidPathMatchesTheIosStoreVectorByteForByteAfterReload() {
        val file = SigilPresenceStore.defaultFile(Files.createTempDirectory("sigil-cross-check").toFile())
        val aggregation = AggregationRuntime()
        val presence = SigilPresenceRuntime(aggregation, tokens(1, 2))
        // iOS SigilPresenceStoreTests.makeSession's rows; the uppercase id
        // exercises the same shared normalization the detection path applies.
        listOf(Triple(10L, "r1", "D0000001"), Triple(10L, "r2", "d0000002"), Triple(11L, "r3", "d0000001"))
            .forEach { (enin, rpid, displayId) ->
                aggregation.recordObservation(enin, rpid, displayId)
                presence.topUpTokens()
            }
        val proofId = UUID.randomUUID()
        presence.persist(SigilPresenceStore(file), proofId)

        val reloaded = SigilPresenceStore(file)
        assertEquals(IOS_STORE_VECTOR, reloaded.records.single().presenceText)
        assertEquals(2, assertNotNull(reloaded.sigilInput(proofId)).windowCount)
    }

    @Test
    fun theAndroidPathMatchesTheSharedFirstSeenOrderVector() {
        // shared SigilPresenceTest.tokensAreTheSuppliedValuesAssignedInFirstSeenOrder
        val aggregation = AggregationRuntime()
        val tokenA = "ffffffffffffffffffffffffffffffff"
        val tokenB = "00000000000000000000000000000001"
        val queue = ArrayDeque(listOf(tokenA, tokenB))
        val presence = SigilPresenceRuntime(aggregation) { queue.removeFirstOrNull() }
        listOf(
            Triple(10L, "rpid-a", "aaaa0001"),
            Triple(10L, "rpid-b", null),
            Triple(11L, "rpid-c", "bbbb0002"),
            Triple(11L, "rpid-d", "aaaa0001"),
        ).forEach { (enin, rpid, displayId) ->
            aggregation.recordObservation(enin, rpid, displayId)
            presence.topUpTokens()
        }
        val file = SigilPresenceStore.defaultFile(Files.createTempDirectory("sigil-cross-check").toFile())
        presence.persist(SigilPresenceStore(file), UUID.randomUUID())
        assertEquals(
            "beid-sigil-presence\t1\n" +
                "windows\t2\n" +
                "peers\t2\n" +
                "peer\t00000000000000000000000000000001\t1\n" +
                "peer\tffffffffffffffffffffffffffffffff\t0,1\n" +
                "end\n",
            SigilPresenceStore(file).records.single().presenceText,
        )
    }

    @Test
    fun aRuntimeOverAReplacedAggregationIsUnencodableAndHasNoLiveInput() {
        val aggregation = AggregationRuntime()
        val presence = SigilPresenceRuntime(aggregation, tokens(1))
        aggregation.recordObservation(1, "r1", "d0000001")
        presence.topUpTokens()
        assertNotNull(presence.liveInput())
        aggregation.reset()
        aggregation.recordObservation(1, "r1", "d0000001")
        assertNull(presence.liveInput(), "a session is bound to one observation input (input_mismatch)")
        val file = SigilPresenceStore.defaultFile(Files.createTempDirectory("sigil-mismatch").toFile())
        val error = assertFailsWith<SigilPresenceStoreException> { presence.persist(SigilPresenceStore(file), UUID.randomUUID()) }
        assertEquals(SigilPresenceStoreException.Reason.UNENCODABLE, error.reason)
    }

    private companion object {
        /** iOS `SigilPresenceStoreTests.testAPersistedRecordReadsBackAsASigilInputAndSurvivesReload`. */
        const val IOS_STORE_VECTOR =
            "beid-sigil-presence\t1\nwindows\t2\npeers\t2\n" +
                "peer\t00000000000000000000000000000001\t0,1\n" +
                "peer\t00000000000000000000000000000002\t0\nend\n"
    }
}
