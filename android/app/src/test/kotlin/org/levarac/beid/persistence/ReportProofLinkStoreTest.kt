package org.levarac.beid.persistence

import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.util.UUID
import javax.xml.parsers.DocumentBuilderFactory
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFails
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject

class ReportProofLinkStoreTest {
    @Test
    fun firstLaunchHasNoLinksAndDoesNotCreateAFile() {
        val file = linkFile()
        val store = ReportProofLinkContract(file)
        assertEquals(emptyList(), store.links())
        assertNull(store.proofIdFor(WINDOW))
        assertEquals(emptySet(), store.windowIdsFor(PROOF))
        assertFalse(file.exists())
    }

    @Test
    fun restartPreservesOnlyTheWindowAndProofIds() {
        val file = linkFile()
        ReportProofLinkContract(file).add(WINDOW, PROOF)
        val restarted = ReportProofLinkContract(file)
        assertEquals(listOf(WINDOW to PROOF), restarted.links())
        assertEquals(PROOF, restarted.proofIdFor(WINDOW))
        assertEquals(setOf(WINDOW), restarted.windowIdsFor(PROOF))
        assertEquals(setOf("schemaVersion", "records"), Json.parseToJsonElement(file.readText()).jsonObject.keys)
        val row = Json.parseToJsonElement(file.readText()).jsonObject.getValue("records").jsonArray.single().jsonObject
        assertEquals(setOf("windowId", "proofId"), row.keys)
        assertEquals(listOf(file.name), requireNotNull(file.parentFile).listFiles()!!.map { it.name })
    }

    @Test
    fun samePairIsANoOpAndConflictingProofIsRefused() {
        val file = linkFile()
        ReportProofLinkContract(file).add(WINDOW, PROOF)
        val original = file.readBytes()
        var writes = 0
        val store = ReportProofLinkContract(file) { _, _ -> writes++; throw IOException("must not write") }
        store.add(WINDOW, PROOF)
        assertFails { store.add(WINDOW, OTHER_PROOF) }
        assertEquals(0, writes)
        assertEquals(listOf(WINDOW to PROOF), store.links())
        assertContentEquals(original, file.readBytes())
    }

    @Test
    fun multipleWindowsCanBelongToOneProof() {
        val store = ReportProofLinkContract(linkFile())
        store.add(WINDOW, PROOF)
        store.add(OTHER_WINDOW, PROOF)
        assertEquals(setOf(WINDOW, OTHER_WINDOW), store.windowIdsFor(PROOF))
    }

    @Test
    fun unreadableFileLatchesUnavailableAndIsNeverOverwritten() {
        val file = linkFile().also { it.writeText("not json") }
        val store = ReportProofLinkContract(file)
        assertFails { store.links() }
        assertFails { store.proofIdFor(WINDOW) }
        assertFails { store.windowIdsFor(PROOF) }
        assertFails { store.add(WINDOW, PROOF) }
        assertEquals("not json", file.readText())
        file.writeText("{\"schemaVersion\":1,\"records\":[]}")
        assertFails { store.add(WINDOW, PROOF) }
    }

    @Test
    fun conflictingRowsOnDiskAreUnavailableRatherThanGuessed() {
        val file = linkFile().also {
            it.writeText("""{"schemaVersion":1,"records":[{"windowId":"$WINDOW","proofId":"$PROOF"},{"windowId":"$WINDOW","proofId":"$OTHER_PROOF"}]}""")
        }
        val original = file.readBytes()
        val store = ReportProofLinkContract(file)
        assertFails { store.links() }
        assertFails { store.add(OTHER_WINDOW, PROOF) }
        assertContentEquals(original, file.readBytes())
    }

    @Test
    fun failedWriteKeepsPreviouslyPublishedMemoryAndDisk() {
        val file = linkFile()
        ReportProofLinkContract(file).add(WINDOW, PROOF)
        val original = file.readBytes()
        val store = ReportProofLinkContract(file) { _, _ -> throw IOException("injected") }
        assertFails { store.add(OTHER_WINDOW, PROOF) }
        assertEquals(listOf(WINDOW to PROOF), store.links())
        assertContentEquals(original, file.readBytes())
    }

    @Test
    fun backupRulesExcludeTheLinkFileFromCloudAndDeviceTransfer() {
        val root = File("src/main")
        val parser = DocumentBuilderFactory.newInstance().apply { isNamespaceAware = true }.newDocumentBuilder()
        val application = parser.parse(root.resolve("AndroidManifest.xml")).getElementsByTagName("application").item(0)
        val ns = "http://schemas.android.com/apk/res/android"
        for ((attribute, sections) in listOf("fullBackupContent" to listOf("full-backup-content"),
            "dataExtractionRules" to listOf("cloud-backup", "device-transfer"))) {
            val resource = application.attributes.getNamedItemNS(ns, attribute)?.nodeValue
            assertEquals(true, resource?.startsWith("@xml/"), "$attribute must reference backup rules")
            val rules = parser.parse(root.resolve("res/xml/${resource!!.substringAfter('/')}.xml"))
            for (section in sections) {
                val exclusions = (rules.getElementsByTagName(section).item(0) as org.w3c.dom.Element)
                    .getElementsByTagName("exclude")
                for (path in listOf("report-proof-links.json", "report-proof-links-staging")) {
                    assertEquals(true, (0 until exclusions.length).any { index ->
                        val row = exclusions.item(index).attributes
                        row.getNamedItem("domain")?.nodeValue == "file" && row.getNamedItem("path")?.nodeValue == path
                    }, "$section must exclude $path")
                }
            }
        }
    }

    private fun linkFile(): File = Files.createTempDirectory("report-links").resolve("report-proof-links.json").toFile()

    private companion object {
        val WINDOW: UUID = UUID.fromString("00112233-4455-6677-8899-aabbccddeeff")
        val OTHER_WINDOW: UUID = UUID.fromString("11112233-4455-6677-8899-aabbccddeeff")
        val PROOF: UUID = UUID.fromString("22222222-2222-2222-2222-222222222222")
        val OTHER_PROOF: UUID = UUID.fromString("33333333-3333-3333-3333-333333333333")
    }
}
