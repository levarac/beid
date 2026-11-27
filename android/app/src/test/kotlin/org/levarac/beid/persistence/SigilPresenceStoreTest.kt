package org.levarac.beid.persistence

import java.io.File
import java.nio.file.Files
import java.util.UUID
import org.levarac.beid.shared.aggregation.AggregationObservationInput
import org.levarac.beid.shared.aggregation.addAggregationObservation
import org.levarac.beid.shared.aggregation.createAggregationObservationInput
import org.levarac.beid.shared.sigil.SigilPresenceSession
import org.levarac.beid.shared.sigil.addSigilPresenceToken
import org.levarac.beid.shared.sigil.createSigilPresenceSession
import org.levarac.beid.shared.sigil.sigilPresenceTokensNeeded
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue

/**
 * [SigilPresenceStore] (beid#722, the Android port of iOS #653's
 * `SigilPresenceStore`): persistence mechanics only. What the text means is
 * pinned by the shared `SigilPresenceTest`; every expected text here is a
 * literal taken from iOS `SigilPresenceStoreTests`, never re-derived.
 */
class SigilPresenceStoreTest {
    private val directory: File = Files.createTempDirectory("sigil-presence-store").toFile()
    private val file: File = SigilPresenceStore.defaultFile(directory)

    /**
     * iOS `SigilPresenceStoreTests.makeSession`: two peers over two windows,
     * tokens `firstToken`, `firstToken + 1` unless [tokened] is false.
     */
    private fun makeSession(firstToken: Int = 1, tokened: Boolean = true): Pair<SigilPresenceSession, AggregationObservationInput> {
        val observations = createAggregationObservationInput()
        listOf(Triple(10L, "r1", "d0000001"), Triple(10L, "r2", "d0000002"), Triple(11L, "r3", "d0000001"))
            .forEach { (window, rpid, displayId) ->
                assertTrue(addAggregationObservation(observations, window, rpid, displayId, false))
            }
        val session = createSigilPresenceSession()
        if (tokened) {
            val needed = sigilPresenceTokensNeeded(session, observations)
            assertEquals(2, needed)
            for (offset in 0 until needed) {
                assertTrue(addSigilPresenceToken(session, observations, (firstToken + offset).toString(16).padStart(32, '0')))
            }
        }
        return session to observations
    }

    @Test
    fun aPersistedRecordReadsBackAsASigilInputAndSurvivesReload() {
        val store = SigilPresenceStore(file)
        val proofId = UUID.randomUUID()
        val (session, observations) = makeSession()
        val record = store.persist(session, observations, proofId)

        assertEquals(proofId, record.proofId)
        assertEquals(IOS_STORE_VECTOR, record.presenceText)
        assertEquals(2, store.sigilInput(proofId)?.windowCount)

        val reloaded = SigilPresenceStore(file)
        assertEquals(store.records, reloaded.records)
        assertEquals(IOS_STORE_VECTOR, reloaded.records.single().presenceText)
        assertEquals(2, reloaded.sigilInput(proofId)?.windowCount)
    }

    @Test
    fun aRepeatedLookupReturnsTheSameInstanceUntilTheRowIsRemoved() {
        val store = SigilPresenceStore(file)
        val proofId = UUID.randomUUID()
        val (session, observations) = makeSession()
        store.persist(session, observations, proofId)

        val first = assertNotNull(store.sigilInput(proofId))
        assertSame(first, store.sigilInput(proofId), "a row must be decoded once, not on every recomposition")

        store.remove(proofId)
        assertNull(store.sigilInput(proofId), "remove must drop the cached input too")
        assertTrue(SigilPresenceStore(file).records.isEmpty(), "remove must reach the disk")
    }

    @Test
    fun aLookupBeforeTheRowExistsDoesNotHideItLater() {
        val store = SigilPresenceStore(file)
        val proofId = UUID.randomUUID()
        assertNull(store.sigilInput(proofId))
        val (session, observations) = makeSession()
        store.persist(session, observations, proofId)
        assertNotNull(store.sigilInput(proofId), "a missing row must not be cached as absent")
    }

    @Test
    fun anUnknownRecordHasNoInput() {
        assertNull(SigilPresenceStore(file).sigilInput(UUID.randomUUID()))
    }

    @Test
    fun anUnencodableSessionWritesNothing() {
        val store = SigilPresenceStore(file)
        val proofId = UUID.randomUUID()
        val (session, observations) = makeSession(tokened = false)
        val error = assertFailsWith<SigilPresenceStoreException> { store.persist(session, observations, proofId) }
        assertEquals(SigilPresenceStoreException.Reason.UNENCODABLE, error.reason)
        assertTrue(store.records.isEmpty())
        assertFalse(file.exists())
        assertNull(store.sigilInput(proofId))
    }

    @Test
    fun anIdenticalRewriteIsANoOpAndADifferentOneConflicts() {
        val store = SigilPresenceStore(file)
        val proofId = UUID.randomUUID()
        val (session, observations) = makeSession()
        val first = store.persist(session, observations, proofId, createdAtEpochMillis = 1_000)
        val again = store.persist(session, observations, proofId, createdAtEpochMillis = 2_000)
        assertEquals(first, again, "the first immutable row is returned unchanged")
        assertEquals(1, store.records.size)

        val (other, otherObservations) = makeSession(firstToken = 100)
        val error = assertFailsWith<SigilPresenceStoreException> { store.persist(other, otherObservations, proofId) }
        assertEquals(SigilPresenceStoreException.Reason.CONFLICTING_PRESENCE, error.reason)
        assertEquals(listOf(first), store.records)
        assertEquals(listOf(first), SigilPresenceStore(file).records)
    }

    @Test
    fun exceptionsCarryNoPayloadBeyondTheirReason() {
        // Logged at session end: a message must never carry a token or display id.
        SigilPresenceStoreException.Reason.entries.forEach { reason ->
            assertEquals(reason.name, SigilPresenceStoreException(reason).message)
        }
    }

    @Test
    fun aCorruptFileIsQuarantinedAndTheStoreKeepsWorking() {
        file.parentFile.mkdirs()
        file.writeText("not json at all")
        val store = SigilPresenceStore(file)

        assertTrue(store.records.isEmpty())
        assertFalse(store.isPersistenceSuspended, "a quarantined file must not wedge later sessions")
        val quarantined = assertNotNull(store.quarantinedFile)
        assertEquals("not json at all", quarantined.readText(), "the corrupt bytes are preserved, not deleted")

        val proofId = UUID.randomUUID()
        val (session, observations) = makeSession()
        store.persist(session, observations, proofId)
        assertEquals(IOS_STORE_VECTOR, SigilPresenceStore(file).records.single().presenceText)
    }

    @Test
    fun aRowWhoseTextSharedRejectsHasNoInputButOthersStillLoad() {
        val good = UUID.randomUUID()
        val store = SigilPresenceStore(file)
        val (session, observations) = makeSession()
        store.persist(session, observations, good)
        val bad = UUID.randomUUID()
        file.writeText(
            file.readText().replace(
                "]}",
                ",{\"proofId\":\"$bad\",\"presenceText\":\"beid-sigil-presence\\t2\\n\",\"createdAt\":0}]}",
            ),
        )
        val reloaded = SigilPresenceStore(file)
        assertEquals(2, reloaded.records.size, "a rejected text is display data, not a corrupt store")
        assertNull(reloaded.sigilInput(bad))
        assertNotNull(reloaded.sigilInput(good))
    }

    @Test
    fun theStoredFileCarriesNoDisplayIdOrRpid() {
        val store = SigilPresenceStore(file)
        val (session, observations) = makeSession()
        store.persist(session, observations, UUID.randomUUID())
        val bytes = file.readText()
        listOf("d0000001", "d0000002", "r1", "r2", "r3").forEach {
            assertFalse(bytes.contains("\"$it\"") || bytes.contains("\t$it"), "found $it in the presence file")
        }
        assertFalse(bytes.contains("d000000"))
    }

    @Test
    fun theDefaultFileIsInsideTheGivenDirectory() {
        val resolved = SigilPresenceStore.defaultFile(directory).canonicalFile
        assertTrue(resolved.toPath().startsWith(directory.canonicalFile.toPath()))
    }

    companion object {
        /** iOS `SigilPresenceStoreTests.testAPersistedRecordReadsBackAsASigilInputAndSurvivesReload`. */
        const val IOS_STORE_VECTOR =
            "beid-sigil-presence\t1\nwindows\t2\npeers\t2\n" +
                "peer\t00000000000000000000000000000001\t0,1\n" +
                "peer\t00000000000000000000000000000002\t0\nend\n"
    }
}
