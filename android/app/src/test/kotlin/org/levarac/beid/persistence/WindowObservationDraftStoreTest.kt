package org.levarac.beid.persistence

import java.nio.charset.StandardCharsets
import java.nio.file.Files
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import org.levarac.beid.shared.report.addWindowObservationDraftRpid
import org.levarac.beid.shared.report.createWindowObservationDraft
import org.levarac.beid.shared.report.encodeWindowObservationDraftSnapshot

class WindowObservationDraftStoreTest {
    @Test
    fun persistedDraftReloadsWithTheSameObservationSet() {
        val file = Files.createTempDirectory("draft-store").toFile().resolve("draft.snapshot")
        val store = WindowObservationDraftStore(file)

        store.persist(draft(RPID_TWO, RPID_ONE))
        val loaded = assertNotNull(store.load())

        assertEquals(WINDOW_ID, loaded.windowId)
        assertEquals(6_000_000L, loaded.enin)
        assertEquals(2, loaded.observedRpidCount)
        assertEquals(RPID_TWO, loaded.observedRpidAt(0))
        assertEquals(RPID_ONE, loaded.observedRpidAt(1))
    }

    @Test
    fun aLaterWriteSupersedesTheEarlierOne() {
        val file = Files.createTempDirectory("draft-store-supersede").toFile().resolve("draft.snapshot")
        val store = WindowObservationDraftStore(file)

        store.persist(draft(RPID_ONE))
        store.persist(draft(RPID_ONE, RPID_TWO))

        assertEquals(2, assertNotNull(store.load()).observedRpidCount)
    }

    /**
     * Corrupt bytes are preserved and reported as *no draft*, never as a
     * draft that observed nothing. Deleting them instead would erase the only
     * evidence that a window's observations were lost.
     */
    @Test
    fun corruptDraftIsQuarantinedAndReadsAsAbsentRatherThanEmpty() {
        val directory = Files.createTempDirectory("draft-store-corrupt").toFile()
        val file = directory.resolve("draft.snapshot")
        file.writeText("not a valid draft", StandardCharsets.UTF_8)

        val loaded = WindowObservationDraftStore(file).load()

        assertNull(loaded)
        assertFalse(file.exists())
        val quarantined = assertNotNull(
            directory.listFiles().orEmpty().singleOrNull { it.name.contains(".corrupt-") },
        )
        assertEquals("not a valid draft", quarantined.readText(StandardCharsets.UTF_8))
    }

    @Test
    fun quarantiningAnUnusableDraftPreservesItsBytesAndFreesThePath() {
        val directory = Files.createTempDirectory("draft-store-unusable").toFile()
        val file = directory.resolve("draft.snapshot")
        val store = WindowObservationDraftStore(file)
        store.persist(draft(RPID_ONE))
        val original = file.readText(StandardCharsets.UTF_8)

        store.quarantineUnusable()

        assertFalse(file.exists())
        assertNull(store.load())
        val quarantined = assertNotNull(
            directory.listFiles().orEmpty().singleOrNull { it.name.contains(".corrupt-") },
        )
        assertEquals(original, quarantined.readText(StandardCharsets.UTF_8))
    }

    @Test
    fun clearRemovesTheDraftAndIsSafeWhenThereIsNone() {
        val file = Files.createTempDirectory("draft-store-clear").toFile().resolve("draft.snapshot")
        val store = WindowObservationDraftStore(file)
        store.persist(draft(RPID_ONE))

        store.clear()
        store.clear()

        assertFalse(file.exists())
        assertNull(store.load())
    }

    @Test
    fun absentDraftIsNullWithoutCreatingAnything() {
        val directory = Files.createTempDirectory("draft-store-absent").toFile()

        assertNull(WindowObservationDraftStore(directory.resolve("draft.snapshot")).load())

        assertTrue(directory.listFiles().orEmpty().isEmpty())
    }

    @Test
    fun persistWritesExactlyTheSharedCanonicalText() {
        val file = Files.createTempDirectory("draft-store-canonical").toFile().resolve("draft.snapshot")
        val expected = draft(RPID_ONE)

        WindowObservationDraftStore(file).persist(expected)

        assertEquals(
            encodeWindowObservationDraftSnapshot(expected),
            file.readText(StandardCharsets.UTF_8),
        )
    }

    private fun draft(vararg observedRpids: String) = run {
        var value = assertNotNull(
            createWindowObservationDraft(
                windowId = WINDOW_ID,
                enin = 6_000_000L,
                eventCode = "event",
                eventIdHex = "21".repeat(32),
                eventDefinitionDigestHex = "22".repeat(32),
                participantCommitmentHex = "ab".repeat(32),
                reporterRpidHex = REPORTER_RPID,
            ).draft,
        )
        observedRpids.forEach { rpid ->
            value = assertNotNull(addWindowObservationDraftRpid(value, rpid).draft)
        }
        value
    }

    private companion object {
        const val WINDOW_ID = "00112233-4455-6677-8899-aabbccddeeff"
        const val REPORTER_RPID = "0110101010101010101010101010101010"
        const val RPID_ONE = "0111111111111111111111111111111111"
        const val RPID_TWO = "0122222222222222222222222222222222"
    }
}
