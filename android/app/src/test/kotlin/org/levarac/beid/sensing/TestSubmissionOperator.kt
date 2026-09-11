package org.levarac.beid.sensing

import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.io.OutputStream
import java.math.BigInteger
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketException
import java.security.MessageDigest
import org.levarac.parallax.submission.ACCEPTANCE_RECEIPT_MEDIA_TYPE
import org.levarac.parallax.submission.restoreStoredObservation

/**
 * beid#525 test support: a REAL loopback HTTP operator, mirroring iOS's
 * `StubOperatorServer` (`ios/BeidTests/ReportSubmissionOperatorIntegrationTests.swift`).
 *
 * `SubmissionClient`'s constructor and `createSubmissionClientForTest` are
 * `internal` to `:shared` and invisible here, so unlike `shared`'s own
 * `SubmissionClientTest` this cannot inject a fake transport — the only seam
 * `:app` has is a real endpoint. This exercises the real
 * `createSubmissionClient()` (real `HttpURLConnection` transport, per
 * `AndroidSubmissionHttpTransport`) against a real, if minimal, operator
 * implementation, over loopback HTTP with `allowInsecureLoopbackForTests =
 * true` — the same tradeoff iOS's own integration suite makes.
 *
 * Hand-rolled on `java.net.ServerSocket` rather than `com.sun.net.httpserver`:
 * Android's unit-test Kotlin compilation classpath is the Android SDK's own
 * boot classpath, not the host JDK's, and does not expose `com.sun.*`
 * internal JDK packages even though the tests execute on a real host JVM.
 * One request per accepted connection, `Connection: close` on every
 * response — no keep-alive, no pipelining; this repository's client never
 * needs either.
 */
internal class StubOperatorServer(
    private val operatorIdHex: String,
    private val eventIdHex: String,
    private val receiptPublicKeyHex: String,
    private val receiptPrivateScalar: Int,
    private val policyDigestHex: String = "aa".repeat(32),
    private val nowEpochSeconds: () -> Long = { System.currentTimeMillis() / 1_000L },
) {
    private val lock = Any()
    private var postCountValue = 0
    private var getCountValue = 0
    private val postBodiesValue = mutableListOf<ByteArray>()
    private val receiptsByDigestHex = mutableMapOf<String, ByteArray>()

    private val serverSocket = ServerSocket(0, 50, InetAddress.getLoopbackAddress())
    @Volatile private var running = false
    private var acceptThread: Thread? = null

    val postCount: Int get() = synchronized(lock) { postCountValue }
    val getCount: Int get() = synchronized(lock) { getCountValue }
    val postBodies: List<ByteArray> get() = synchronized(lock) { postBodiesValue.toList() }

    fun start(): String {
        running = true
        acceptThread = Thread({
            while (running) {
                val socket = try {
                    serverSocket.accept()
                } catch (_: SocketException) {
                    break // serverSocket.close() from stop() lands here
                }
                Thread({ handleConnection(socket) }, "stub-operator-connection").apply {
                    isDaemon = true
                    start()
                }
            }
        }, "stub-operator-accept").apply {
            isDaemon = true
            start()
        }
        return "http://127.0.0.1:${serverSocket.localPort}"
    }

    fun stop() {
        running = false
        runCatching { serverSocket.close() }
        acceptThread?.join(1_000)
    }

    private fun handleConnection(socket: Socket) {
        socket.use {
            val request = readRequest(it.getInputStream()) ?: return
            val output = it.getOutputStream()
            when {
                request.method == "POST" && request.path == "/v1/observations" -> handlePost(request, output)
                request.method == "GET" &&
                    request.path.startsWith("/v1/observations/") &&
                    request.path.endsWith("/acceptance") -> handleGet(request, output)
                else -> writeResponse(output, 404, ByteArray(0))
            }
        }
    }

    private fun handlePost(request: ParsedHttpRequest, output: OutputStream) {
        synchronized(lock) {
            postCountValue++
            postBodiesValue += request.body
        }
        val stored = restoreStoredObservation(request.body.toLowercaseHex())
        if (stored == null) {
            writeResponse(output, 422, ByteArray(0))
            return
        }
        val digestHex = stored.observationDigest.toByteArray().toLowercaseHex()
        val receiptBytes = synchronized(lock) {
            receiptsByDigestHex.getOrPut(digestHex) { buildReceipt(digestHex) }
        }
        writeResponse(output, 201, receiptBytes)
    }

    private fun handleGet(request: ParsedHttpRequest, output: OutputStream) {
        synchronized(lock) { getCountValue++ }
        val digestHex = request.path.removePrefix("/v1/observations/").removeSuffix("/acceptance")
        val receiptBytes = synchronized(lock) { receiptsByDigestHex[digestHex] }
        if (receiptBytes == null) {
            writeResponse(output, 404, ByteArray(0))
            return
        }
        writeResponse(output, 200, receiptBytes)
    }

    private fun writeResponse(output: OutputStream, status: Int, body: ByteArray) {
        val statusText = when (status) {
            200 -> "OK"
            201 -> "Created"
            404 -> "Not Found"
            422 -> "Unprocessable Entity"
            else -> "Error"
        }
        val head = buildString {
            append("HTTP/1.1 ").append(status).append(' ').append(statusText).append("\r\n")
            append("Connection: close\r\n")
            append("Content-Length: ").append(body.size).append("\r\n")
            if (body.isNotEmpty()) append("Content-Type: ").append(ACCEPTANCE_RECEIPT_MEDIA_TYPE).append("\r\n")
            append("\r\n")
        }
        output.write(head.toByteArray(Charsets.US_ASCII))
        output.write(body)
        output.flush()
    }

    private fun buildReceipt(observationDigestHex: String): ByteArray = TestAcceptanceReceiptBuilder.build(
        observationDigest = observationDigestHex.hexToByteArray(),
        context = eventIdHex.hexToByteArray(),
        operatorId = operatorIdHex.hexToByteArray(),
        policyDigest = policyDigestHex.hexToByteArray(),
        acceptedAtSeconds = nowEpochSeconds(),
        mergeBySeconds = nowEpochSeconds() + 3_600L,
        receiptPublicKeyCompressed = receiptPublicKeyHex.hexToByteArray(),
        receiptPrivateScalar = receiptPrivateScalar,
    )

    private data class ParsedHttpRequest(val method: String, val path: String, val body: ByteArray)

    private fun readRequest(input: InputStream): ParsedHttpRequest? {
        val requestLine = readLine(input) ?: return null
        val parts = requestLine.split(' ')
        if (parts.size < 2) return null
        val method = parts[0]
        val path = parts[1]
        var contentLength = 0
        while (true) {
            val line = readLine(input) ?: break
            if (line.isEmpty()) break
            val colon = line.indexOf(':')
            if (colon > 0 && line.substring(0, colon).trim().equals("Content-Length", ignoreCase = true)) {
                contentLength = line.substring(colon + 1).trim().toIntOrNull() ?: 0
            }
        }
        val body = ByteArray(contentLength)
        var read = 0
        while (read < contentLength) {
            val count = input.read(body, read, contentLength - read)
            if (count < 0) break
            read += count
        }
        return ParsedHttpRequest(method, path, body)
    }

    private fun readLine(input: InputStream): String? {
        val out = ByteArrayOutputStream()
        while (true) {
            val byte = input.read()
            if (byte < 0) return if (out.size() == 0) null else out.toString("US-ASCII")
            if (byte == '\n'.code) {
                val bytes = out.toByteArray()
                val trimmed = if (bytes.isNotEmpty() && bytes.last() == '\r'.code.toByte()) {
                    bytes.copyOf(bytes.size - 1)
                } else {
                    bytes
                }
                return String(trimmed, Charsets.US_ASCII)
            }
            out.write(byte)
        }
    }
}

/**
 * Builds a synthetic, correctly-signed COSE_Sign1 AcceptanceReceipt for
 * tests — mirrors the exact wire shape `SubmissionClient.kt`'s
 * `decodeAndVerifyAcceptanceReceipt` (`:239-330`) verifies, built with
 * [TestCanonicalCbor] and signed with [TestSecp256k1] since neither
 * `CanonicalCbor` nor `Secp256k1` (`shared/commonMain`) is visible outside
 * `:shared`.
 */
internal object TestAcceptanceReceiptBuilder {
    private const val PAYLOAD_CONTENT_TYPE = "application/vnd.levarac.acceptance-receipt+cbor"
    private const val COSE_ALGORITHM = -47L
    private const val COSE_SIGN1_TAG = 18L

    fun build(
        observationDigest: ByteArray,
        context: ByteArray,
        operatorId: ByteArray,
        policyDigest: ByteArray,
        acceptedAtSeconds: Long,
        mergeBySeconds: Long,
        receiptPublicKeyCompressed: ByteArray,
        receiptPrivateScalar: Int,
    ): ByteArray {
        require(observationDigest.size == 32 && context.size == 32 && operatorId.size == 32 && policyDigest.size == 32)

        val protected = TestCanonicalCbor.map(
            listOf(
                TestCanonicalCbor.uint(1) to TestCanonicalCbor.negint(COSE_ALGORITHM),
                TestCanonicalCbor.uint(3) to TestCanonicalCbor.text(PAYLOAD_CONTENT_TYPE),
                TestCanonicalCbor.uint(4) to TestCanonicalCbor.bstr(coseKeyId(receiptPublicKeyCompressed)),
            ),
        )
        val payload = TestCanonicalCbor.map(
            listOf(
                TestCanonicalCbor.uint(1) to TestCanonicalCbor.uint(1),
                TestCanonicalCbor.uint(2) to TestCanonicalCbor.bstr(operatorId),
                TestCanonicalCbor.uint(3) to TestCanonicalCbor.bstr(observationDigest),
                TestCanonicalCbor.uint(4) to TestCanonicalCbor.bstr(context),
                TestCanonicalCbor.uint(5) to TestCanonicalCbor.uint(acceptedAtSeconds),
                TestCanonicalCbor.uint(6) to TestCanonicalCbor.uint(mergeBySeconds),
                TestCanonicalCbor.uint(7) to TestCanonicalCbor.bstr(policyDigest),
            ),
        )
        val sigStructure = TestCanonicalCbor.array(
            listOf(
                TestCanonicalCbor.text("Signature1"),
                TestCanonicalCbor.bstr(protected),
                TestCanonicalCbor.bstr(ByteArray(0)),
                TestCanonicalCbor.bstr(payload),
            ),
        )
        val digest = MessageDigest.getInstance("SHA-256").digest(sigStructure)
        val (r, s) = TestSecp256k1.sign(digest, receiptPrivateScalar)
        val coseSign1 = TestCanonicalCbor.array(
            listOf(
                TestCanonicalCbor.bstr(protected),
                TestCanonicalCbor.map(emptyList()),
                TestCanonicalCbor.bstr(payload),
                TestCanonicalCbor.bstr(r + s),
            ),
        )
        return TestCanonicalCbor.tag(COSE_SIGN1_TAG, coseSign1)
    }

    /** Mirrors `coseKeyId` in `SubmissionClient.kt` (private there, so re-derived here). */
    private fun coseKeyId(publicKey: ByteArray): ByteArray = MessageDigest.getInstance("SHA-256")
        .digest("levarac:cose-kid:v1".toByteArray(Charsets.UTF_8) + byteArrayOf(0) + publicKey)
        .copyOfRange(0, 8)
}

/**
 * Mirrors `acceptanceOperatorId` in `shared/.../SubmissionModels.kt` (internal
 * there): the operator id `createSubmissionOperatorConfigurationWithOperatorId`
 * requires to equal `sha256("levarac:operator-id:v1" + 0x00 + receiptPublicKey)`.
 */
internal fun testAcceptanceOperatorIdHex(receiptPublicKeyHex: String): String =
    MessageDigest.getInstance("SHA-256")
        .digest("levarac:operator-id:v1".toByteArray(Charsets.UTF_8) + byteArrayOf(0) + receiptPublicKeyHex.hexToByteArray())
        .toLowercaseHex()

/**
 * A minimal canonical-CBOR ENCODER for exactly the shapes beid#525's tests
 * build (unsigned/negative ints, byte/text strings, arrays, small maps with
 * caller-presorted keys, one tag) — mirrors the minimal-length and
 * canonical-ordering rules `SubmissionClient.kt`'s decoder enforces closely
 * enough to round-trip through it. Not a general CBOR encoder.
 */
internal object TestCanonicalCbor {
    fun uint(value: Long): ByteArray {
        require(value >= 0)
        return encodeHead(0, value)
    }

    fun negint(value: Long): ByteArray {
        require(value < 0)
        return encodeHead(1, -1L - value)
    }

    fun bstr(bytes: ByteArray): ByteArray = encodeHead(2, bytes.size.toLong()) + bytes

    fun text(value: String): ByteArray {
        val bytes = value.toByteArray(Charsets.UTF_8)
        return encodeHead(3, bytes.size.toLong()) + bytes
    }

    fun array(items: List<ByteArray>): ByteArray {
        val out = ByteArrayOutputStream()
        out.write(encodeHead(4, items.size.toLong()))
        items.forEach(out::write)
        return out.toByteArray()
    }

    /** Entries must already be in canonical (encoded-key-byte-ascending) order — every caller here has fixed, small, already-sorted key sets. */
    fun map(entries: List<Pair<ByteArray, ByteArray>>): ByteArray {
        val out = ByteArrayOutputStream()
        out.write(encodeHead(5, entries.size.toLong()))
        entries.forEach { (key, value) -> out.write(key); out.write(value) }
        return out.toByteArray()
    }

    fun tag(tagNumber: Long, value: ByteArray): ByteArray = encodeHead(6, tagNumber) + value

    private fun encodeHead(major: Int, value: Long): ByteArray {
        require(value >= 0)
        val out = ByteArrayOutputStream()
        when {
            value < 24 -> out.write((major shl 5) or value.toInt())
            value <= 0xffL -> {
                out.write((major shl 5) or 24)
                out.write(value.toInt())
            }
            value <= 0xffffL -> {
                out.write((major shl 5) or 25)
                out.write(((value shr 8) and 0xff).toInt())
                out.write((value and 0xff).toInt())
            }
            value <= 0xffffffffL -> {
                out.write((major shl 5) or 26)
                for (shift in intArrayOf(24, 16, 8, 0)) out.write(((value shr shift) and 0xff).toInt())
            }
            else -> {
                out.write((major shl 5) or 27)
                for (shift in intArrayOf(56, 48, 40, 32, 24, 16, 8, 0)) out.write(((value shr shift) and 0xff).toInt())
            }
        }
        return out.toByteArray()
    }
}

/**
 * Small test-only secp256k1 signer for private scalars 1, 2 and 3 — a Kotlin
 * port of iOS's `TestSecp256k1`
 * (`ios/BeidTests/ReportSubmissionOperatorIntegrationTests.swift`), using
 * `BigInteger` instead of hand-rolled byte arithmetic since the JVM has it
 * built in.
 *
 * The fixed nonce k=1 makes R=G, so r is always the generator's
 * x-coordinate and s = hash + r*d (mod n). A valid ECDSA signature,
 * deliberately unsuitable for production because the nonce is public and
 * reused — production signing stays in Barnard.
 */
internal object TestSecp256k1 {
    private val GX = BigInteger(
        "79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798",
        16,
    )
    private val CURVE_ORDER = BigInteger(
        "fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141",
        16,
    )
    private val HALF_ORDER = CURVE_ORDER.shiftRight(1)

    /** Returns compact 32-byte `(r, s)`. `privateScalar` must be 1, 2, or 3 (this repo's fixture keys). */
    fun sign(messageHash: ByteArray, privateScalar: Int): Pair<ByteArray, ByteArray> {
        require(messageHash.size == 32)
        require(privateScalar in 1..3)
        val hash = BigInteger(1, messageHash)
        var s = hash.add(GX.multiply(BigInteger.valueOf(privateScalar.toLong()))).mod(CURVE_ORDER)
        if (s > HALF_ORDER) s = CURVE_ORDER.subtract(s)
        return GX.toFixedWidth(32) to s.toFixedWidth(32)
    }

    private fun BigInteger.toFixedWidth(width: Int): ByteArray {
        val raw = toByteArray().let { if (it.size > width && it[0] == 0.toByte()) it.copyOfRange(it.size - width, it.size) else it }
        require(raw.size <= width) { "value does not fit in $width bytes" }
        return ByteArray(width - raw.size) + raw
    }
}
