package org.levarac.beid.venue

import java.io.File
import java.net.InetAddress
import java.net.ServerSocket
import java.net.SocketException
import java.util.Base64
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import org.levarac.parallax.registry.createSepoliaRegistryClientWithRpcEndpoints
import org.levarac.parallax.venue.decodeVenueHandoff

/** Uses the exact signed gap/full-schedule artifacts and registry recordings used on iOS. */
class VenueScheduleImportTest {
    @Test fun gapBundleIsRejectedAtImportEvenWhileItsCurrentLeaseVerifies() = runTest {
        withImporter(full = false, now = 1_800_000_000) { importer, link ->
            assertEquals(VenueImportOutcome.VerificationFailed, importer.import(link))
        }
    }

    @Test fun validScheduleImportsAndStillNeedsCurrentEligibility() = runTest {
        withImporter(full = true, now = 1_790_294_401) { importer, link ->
            val pack = assertIs<VenueImportOutcome.Ready>(importer.import(link)).pack
            assertEquals("996ab4d7cd0785199b715e6ff004f41ef740ead3b3363602ce1cb14b812d1f94", pack.eventIdHex)
            assertEquals(1_790_294_700L, pack.stopAtUnixSeconds)
        }
    }

    @Test fun validImportScheduleDoesNotOverrideNotStartedServingGate() = runTest {
        withImporter(full = true, now = 1_790_294_399) { importer, link ->
            assertEquals(VenueImportOutcome.NotReady("notStarted"), importer.import(link))
        }
    }

    private suspend fun withImporter(full: Boolean, now: Long, check: suspend (SharedVenuePackImporter, String) -> Unit) {
        val server = ServerSocket(0, 8, InetAddress.getByName("127.0.0.1"))
        val worker = Thread {
            while (!server.isClosed) {
                val socket = try { server.accept() } catch (_: SocketException) { break }
                socket.use {
                    it.soTimeout = 5_000
                    val input = it.getInputStream().bufferedReader(Charsets.UTF_8)
                    input.readLine()
                    var length = 0
                    while (true) {
                        val line = input.readLine() ?: break
                        if (line.isEmpty()) break
                        if (line.startsWith("Content-Length:", ignoreCase = true)) length = line.substringAfter(':').trim().toInt()
                    }
                    val chars = CharArray(length)
                    var read = 0
                    while (read < length) {
                        val count = input.read(chars, read, length - read)
                        require(count > 0)
                        read += count
                    }
                    val blockRead = String(chars).contains("eth_getBlockByNumber")
                    val result = if (blockRead) {
                        "{\"number\":\"0x2a\",\"hash\":\"0x${"22".repeat(32)}\"}"
                    } else "\"0x${if (full) FULL_CONTEXT else GAP_CONTEXT}\""
                    val bytes = "{\"jsonrpc\":\"2.0\",\"id\":${if (blockRead) 1 else 2},\"result\":$result}".encodeToByteArray()
                    val headers = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ${bytes.size}\r\nConnection: close\r\n\r\n"
                    it.getOutputStream().apply { write(headers.encodeToByteArray()); write(bytes); flush() }
                }
            }
        }.apply { isDaemon = true; start() }
        val endpoint = "http://127.0.0.1:${server.localPort}/"
        val client = requireNotNull(createSepoliaRegistryClientWithRpcEndpoints(
            "0xd4852f8526a1555a1b2c34145f0ecda412a53c51", endpoint, endpoint,
        ))
        try {
            val bundle = fixture(if (full) "full-schedule.venue-bundle.hex" else "valid.venue-bundle.cbor")
            val handoff = fixture(if (full) "full-schedule.venue-handoff.hex" else "valid.venue-handoff.cbor")
            val url = "https://venue.example/pack.cbor".encodeToByteArray()
            // Add the acquisition address to the existing canonical handoff, without changing its expected digest.
            val linked = if (requireNotNull(decodeVenueHandoff(handoff)).bundleUrl == null) {
                byteArrayOf(0xa7.toByte()) + handoff.drop(1) + byteArrayOf(7, 0x78, url.size.toByte()) + url
            } else handoff
            val link = "https://venue.example/#" + Base64.getUrlEncoder().withoutPadding().encodeToString(linked)
            check(SharedVenuePackImporter(client, VenueBundleAcquirer { bundle }, { now }), link)
        } finally {
            client.close()
            server.close()
            worker.join(5_000)
        }
    }

    private fun fixture(name: String): ByteArray {
        val root = generateSequence(File(System.getProperty("user.dir")).canonicalFile) { it.parentFile }
            .first { File(it, "ios/BeidTests/Fixtures/venue-bundle-conformance").isDirectory }
        val file = File(root, "ios/BeidTests/Fixtures/venue-bundle-conformance/$name")
        return if (name.endsWith(".hex")) file.readText().trim().chunked(2).map { it.toInt(16).toByte() }.toByteArray()
        else file.readBytes()
    }

    private companion object {
        // Recorded registry reader ABI results; same bytes as ProductionVenueBundleVerifierTests.
        const val GAP_CONTEXT = "000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000b7a3010102a40154111111111111111111111111111111111111111102542222222222222222222222222222222222222222035820cba59e50c7666ef2468a14f2e53f04decfd078933cd245a9a2d77532eb23b700041a6b49c26003a30101020103818601582000000000000000000000000000000000000000000000000000000000000000005820f1b4b54e6c911f1f02c1c9383c4914af56ffa3888ec28910f9f3204812276d7f1a6b49c6481a6b49dee31a6b49c3f0000000000000000000"
        const val FULL_CONTEXT = "000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000b7a3010102a40154df6986bbadd189309d52d437851c10e47ca02e200254d34c8acff6dbc4dc192e0712aa97b1c836770512035820e8dab1e251bac55f04aa0316e67916b7fff99c15c9ee4e4f41ba44599b5bf223041a6ab4641803a301010201038186015820000000000000000000000000000000000000000000000000000000000000000058203440ccbda7e59782ff36f7760275298ee2ebb71e994f11d4127fb1259efb5c2c1a6ab5b9801a6ab85c801a6ab46800000000000000000000"
    }
}
