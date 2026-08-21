package org.levarac.parallax.submission

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import org.levarac.parallax.observation.ByteString32
import org.levarac.parallax.observation.CanonicalCbor
import org.levarac.parallax.observation.CompactEs256kSignature
import org.levarac.parallax.observation.ImmutableBytes
import org.levarac.parallax.observation.ProtocolUInt
import org.levarac.parallax.observation.Secp256k1
import org.levarac.parallax.observation.Sha256
import org.levarac.parallax.observation.Sha256Digest

public const val OBSERVATION_SUBMISSION_MEDIA_TYPE: String =
    "application/vnd.levarac.observation+cose"
public const val ACCEPTANCE_RECEIPT_MEDIA_TYPE: String =
    "application/vnd.levarac.acceptance-receipt+cose"
private const val ACCEPTANCE_RECEIPT_PAYLOAD_MEDIA_TYPE: String =
    "application/vnd.levarac.acceptance-receipt+cbor"
private const val SIG_STRUCTURE_CONTEXT: String = "Signature1"
private const val COSE_SIGN1_TAG: Long = 18L
private const val COSE_ALGORITHM: Long = -47L
private const val REQUEST_TIMEOUT_MILLIS: Int = 4_000

public class SubmissionClient internal constructor(
    private val transport: SubmissionHttpTransport,
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Default),
) {
    /** Sends the exact stored signed Observation bytes once. Call again for an idempotent retry. */
    public fun submit(
        observation: StoredObservationV1,
        configuration: SubmissionOperatorConfiguration,
        completion: (SubmissionResult) -> Unit,
    ): SubmissionRequest {
        val job = scope.launch {
            val result = submitOnce(observation, configuration)
            completion(result)
        }
        return SubmissionRequest(job::cancel)
    }

    /** Reads the stored Receipt for an Observation and verifies it with the same trust boundary. */
    public fun lookupReceipt(
        observation: StoredObservationV1,
        configuration: SubmissionOperatorConfiguration,
        completion: (SubmissionResult) -> Unit,
    ): SubmissionRequest {
        val job = scope.launch {
            val result = lookupOnce(observation, configuration)
            completion(result)
        }
        return SubmissionRequest(job::cancel)
    }

    public fun close() {
        scope.cancel()
    }

    private suspend fun submitOnce(
        observation: StoredObservationV1,
        configuration: SubmissionOperatorConfiguration,
    ): SubmissionResult {
        val request = SubmissionHttpRequest(
            method = "POST",
            url = observationsEndpoint(configuration),
            headers = mapOf(
                "Accept" to ACCEPTANCE_RECEIPT_MEDIA_TYPE,
                "Content-Type" to OBSERVATION_SUBMISSION_MEDIA_TYPE,
            ),
            body = observation.signedBytes.toByteArray(),
            timeoutMillis = REQUEST_TIMEOUT_MILLIS,
        )
        return executeAndDecode(
            request = request,
            observation = observation,
            configuration = configuration,
            successStatuses = setOf(200, 201),
        )
    }

    private suspend fun lookupOnce(
        observation: StoredObservationV1,
        configuration: SubmissionOperatorConfiguration,
    ): SubmissionResult {
        val request = SubmissionHttpRequest(
            method = "GET",
            url = "${observationsEndpoint(configuration)}/${observation.observationDigest.toHex()}/acceptance",
            headers = mapOf("Accept" to ACCEPTANCE_RECEIPT_MEDIA_TYPE),
            timeoutMillis = REQUEST_TIMEOUT_MILLIS,
        )
        return executeAndDecode(
            request = request,
            observation = observation,
            configuration = configuration,
            successStatuses = setOf(200),
        )
    }

    private suspend fun executeAndDecode(
        request: SubmissionHttpRequest,
        observation: StoredObservationV1,
        configuration: SubmissionOperatorConfiguration,
        successStatuses: Set<Int>,
    ): SubmissionResult {
        return try {
            val response = transport.execute(request)
            when {
                response.statusCode in successStatuses -> {
                    requireResponseContentType(response.headers, ACCEPTANCE_RECEIPT_MEDIA_TYPE)
                    val receipt = decodeAndVerifyAcceptanceReceipt(
                        signedBytes = response.body,
                        observation = observation,
                        configuration = configuration,
                    )
                    SubmissionResult(
                        isSuccess = true,
                        receipt = receipt,
                        statusCode = response.statusCode,
                        isRetryable = false,
                        errorCode = null,
                        errorMessage = null,
                    )
                }

                response.statusCode == 429 -> failure(
                    statusCode = response.statusCode,
                    code = SubmissionErrorCode.RATE_LIMITED,
                    retryable = true,
                    message = "operator rate limit exceeded",
                )

                response.statusCode in 500..599 -> failure(
                    statusCode = response.statusCode,
                    code = SubmissionErrorCode.SERVER_ERROR,
                    retryable = true,
                    message = "operator service is temporarily unavailable",
                )

                response.statusCode == 409 -> failure(
                    statusCode = response.statusCode,
                    code = SubmissionErrorCode.CONFLICT,
                    retryable = false,
                    message = "operator rejected the Observation natural-key conflict",
                )

                request.method == "GET" && response.statusCode == 404 -> failure(
                    statusCode = response.statusCode,
                    code = SubmissionErrorCode.RECEIPT_NOT_FOUND,
                    retryable = false,
                    message = "operator has no stored AcceptanceReceipt for this Observation",
                )

                response.statusCode == 422 -> failure(
                    statusCode = response.statusCode,
                    code = SubmissionErrorCode.REJECTED,
                    retryable = false,
                    message = "operator rejected the Observation",
                )

                else -> failure(
                    statusCode = response.statusCode,
                    code = SubmissionErrorCode.HTTP_ERROR,
                    retryable = false,
                    message = "operator returned HTTP ${response.statusCode}",
                )
            }
        } catch (_: CancellationException) {
            failure(
                statusCode = 0,
                code = SubmissionErrorCode.CANCELLED,
                retryable = false,
                message = "submission was cancelled",
            )
        } catch (error: SubmissionTransportTimeoutException) {
            failure(
                statusCode = 0,
                code = SubmissionErrorCode.TIMEOUT,
                retryable = true,
                message = error.message ?: "submission request timed out",
            )
        } catch (error: IllegalArgumentException) {
            failure(
                statusCode = 0,
                code = SubmissionErrorCode.PROTOCOL_ERROR,
                retryable = false,
                message = error.message ?: "operator returned an invalid AcceptanceReceipt",
            )
        } catch (error: Throwable) {
            failure(
                statusCode = 0,
                code = SubmissionErrorCode.HTTP_ERROR,
                retryable = false,
                message = error.message ?: "submission transport failed",
            )
        }
    }

    private fun failure(
        statusCode: Int,
        code: SubmissionErrorCode,
        retryable: Boolean,
        message: String,
    ): SubmissionResult = SubmissionResult(
        isSuccess = false,
        receipt = null,
        statusCode = statusCode,
        isRetryable = retryable,
        errorCode = code.wireName,
        errorMessage = message,
    )
}

public fun createSubmissionClient(): SubmissionClient =
    SubmissionClient(createPlatformSubmissionHttpTransport())

internal fun createSubmissionClientForTest(transport: SubmissionHttpTransport): SubmissionClient =
    SubmissionClient(transport)

private fun observationsEndpoint(configuration: SubmissionOperatorConfiguration): String {
    val endpoint = configuration.submissionEndpoint
    return if (endpoint.endsWith("/v1/observations")) endpoint else "$endpoint/v1/observations"
}

private fun requireResponseContentType(headers: Map<String, String>, expected: String) {
    val actual = headers.entries.firstOrNull { it.key.equals("Content-Type", ignoreCase = true) }
        ?.value
        ?.substringBefore(';')
        ?.trim()
    require(actual == expected) {
        "operator response Content-Type must be $expected"
    }
}

private fun decodeAndVerifyAcceptanceReceipt(
    signedBytes: ByteArray,
    observation: StoredObservationV1,
    configuration: SubmissionOperatorConfiguration,
): AcceptanceReceipt {
    require(signedBytes.size <= MAX_SUBMISSION_RESPONSE_BYTES) {
        "AcceptanceReceipt exceeds the configured response limit"
    }
    val rootReader = SubmissionCborReader(signedBytes)
    val root = rootReader.readValue()
    rootReader.requireFinished()
    val tagged = root as? SubmissionCborValue.Tag
        ?: throw IllegalArgumentException("AcceptanceReceipt must use COSE_Sign1 tag 18")
    require(tagged.tag == COSE_SIGN1_TAG) { "unexpected COSE tag" }
    val cose = tagged.value as? SubmissionCborValue.ArrayValue
        ?: throw IllegalArgumentException("COSE_Sign1 must be an array")
    require(cose.values.size == 4) { "COSE_Sign1 must contain four fields" }
    val protected = cose.values[0].asBytes("protected headers")
    val unprotected = cose.values[1] as? SubmissionCborValue.MapValue
        ?: throw IllegalArgumentException("COSE unprotected headers must be a map")
    require(unprotected.entries.isEmpty()) { "COSE unprotected headers must be empty" }
    val payload = cose.values[2].asBytes("AcceptanceReceipt payload")
    val signature = cose.values[3].asBytes("COSE signature")
    require(signature.size == 64) { "COSE signature must be compact 64-byte ES256K" }

    val protectedHeaders = readProtectedHeaders(protected)
    val expectedKid = coseKeyId(configuration.receiptPublicKey.toByteArray())
    require(protectedHeaders.kid.contentEquals(expectedKid)) { "AcceptanceReceipt kid does not match operator key" }
    val sigStructure = CanonicalCbor.encode(
        CanonicalCbor.array(
            CanonicalCbor.text(SIG_STRUCTURE_CONTEXT),
            CanonicalCbor.bytes(protected),
            CanonicalCbor.bytes(ByteArray(0)),
            CanonicalCbor.bytes(payload),
        ),
    )
    val digest = Sha256.digest(sigStructure)
    require(
        Secp256k1.verify(
            digest = digest,
            signature = CompactEs256kSignature(
                signature.copyOfRange(0, 32),
                signature.copyOfRange(32, 64),
            ),
            publicKey = configuration.receiptPublicKey.toByteArray(),
        ),
    ) { "AcceptanceReceipt signature does not verify" }

    val fields = decodeAcceptancePayload(payload)
    require(fields.observationDigest == observation.observationDigest) {
        "AcceptanceReceipt observationDigest does not match stored Observation"
    }
    configuration.eventId?.let { expected ->
        require(fields.context == expected) { "AcceptanceReceipt context does not match Event Definition" }
    }
    configuration.validFrom?.let { validFrom ->
        require(fields.acceptedAt.value >= validFrom) { "AcceptanceReceipt predates Event Definition validity" }
    }
    configuration.validUntil?.let { validUntil ->
        require(fields.mergeBy.value <= validUntil) { "AcceptanceReceipt exceeds Event Definition validity" }
    }
    require(fields.operatorId.toByteArray().contentEquals(configuration.operatorId.toByteArray())) {
        "AcceptanceReceipt operatorId does not match the verified Event Definition"
    }
    return AcceptanceReceipt(
        signedBytes = ImmutableBytes(signedBytes),
        operatorId = fields.operatorId,
        observationDigest = fields.observationDigest,
        context = fields.context,
        acceptedAt = fields.acceptedAt,
        mergeBy = fields.mergeBy,
        policyDigest = fields.policyDigest,
    )
}

private data class ProtectedHeaders(val kid: ByteArray)

private fun readProtectedHeaders(bytes: ByteArray): ProtectedHeaders {
    val reader = SubmissionCborReader(bytes)
    val map = reader.readValue() as? SubmissionCborValue.MapValue
        ?: throw IllegalArgumentException("COSE protected headers must be a map")
    reader.requireFinished()
    require(map.entries.size == 3) { "unexpected COSE protected header count" }
    require(map.entries[0].first.asUnsigned("COSE header key") == 1L)
    require(map.entries[0].second.asNegative("COSE algorithm") == COSE_ALGORITHM)
    require(map.entries[1].first.asUnsigned("COSE header key") == 3L)
    require(map.entries[1].second.asText("COSE content type") == ACCEPTANCE_RECEIPT_PAYLOAD_MEDIA_TYPE)
    require(map.entries[2].first.asUnsigned("COSE header key") == 4L)
    val kid = map.entries[2].second.asBytes("COSE key ID")
    require(kid.size == 8) { "COSE key ID must be eight bytes" }
    return ProtectedHeaders(kid)
}

private data class AcceptanceFields(
    val operatorId: ByteString32,
    val observationDigest: Sha256Digest,
    val context: ByteString32,
    val acceptedAt: ProtocolUInt,
    val mergeBy: ProtocolUInt,
    val policyDigest: ByteString32,
)

private fun decodeAcceptancePayload(bytes: ByteArray): AcceptanceFields {
    val reader = SubmissionCborReader(bytes)
    val map = reader.readValue() as? SubmissionCborValue.MapValue
        ?: throw IllegalArgumentException("AcceptanceReceipt payload must be a map")
    reader.requireFinished()
    require(map.entries.size == 7) { "AcceptanceReceipt payload must contain seven fields" }
    map.entries.forEachIndexed { index, entry ->
        require(entry.first.asUnsigned("AcceptanceReceipt field key") == index + 1L) {
            "AcceptanceReceipt payload keys must be ordered and complete"
        }
    }
    require(map.entries[0].second.asUnsigned("AcceptanceReceipt version") == 1L)
    val operatorId = ByteString32(map.entries[1].second.asBytes("operatorId").also { require(it.size == 32) })
    val observationDigest = Sha256Digest(
        map.entries[2].second.asBytes("observationDigest").also { require(it.size == 32) },
    )
    val context = ByteString32(map.entries[3].second.asBytes("context").also { require(it.size == 32) })
    val acceptedAt = ProtocolUInt(map.entries[4].second.asUnsigned("acceptedAt"))
    val mergeBy = ProtocolUInt(map.entries[5].second.asUnsigned("mergeBy"))
    require(mergeBy.value >= acceptedAt.value) { "AcceptanceReceipt mergeBy precedes acceptedAt" }
    val policyDigest = ByteString32(
        map.entries[6].second.asBytes("policyDigest").also { require(it.size == 32) },
    )
    return AcceptanceFields(operatorId, observationDigest, context, acceptedAt, mergeBy, policyDigest)
}

private fun coseKeyId(publicKey: ByteArray): ByteArray =
    Sha256.digest("levarac:cose-kid:v1".encodeToByteArray() + byteArrayOf(0) + publicKey)
        .copyOfRange(0, 8)

private fun SubmissionCborValue.asBytes(label: String): ByteArray = when (this) {
    is SubmissionCborValue.Bytes -> value.copyOf()
    else -> throw IllegalArgumentException("$label must be a byte string")
}

private fun SubmissionCborValue.asText(label: String): String = when (this) {
    is SubmissionCborValue.Text -> value
    else -> throw IllegalArgumentException("$label must be text")
}

private fun SubmissionCborValue.asUnsigned(label: String): Long = when (this) {
    is SubmissionCborValue.Unsigned -> value
    else -> throw IllegalArgumentException("$label must be an unsigned integer")
}

private fun SubmissionCborValue.asNegative(label: String): Long = when (this) {
    is SubmissionCborValue.Negative -> value
    else -> throw IllegalArgumentException("$label must be a negative integer")
}

private sealed interface SubmissionCborValue {
    data class Unsigned(val value: Long) : SubmissionCborValue
    data class Negative(val value: Long) : SubmissionCborValue
    data class Bytes(val value: ByteArray) : SubmissionCborValue
    data class Text(val value: String) : SubmissionCborValue
    data class ArrayValue(val values: List<SubmissionCborValue>) : SubmissionCborValue
    data class MapValue(val entries: List<Pair<SubmissionCborValue, SubmissionCborValue>>) : SubmissionCborValue
    data class Tag(val tag: Long, val value: SubmissionCborValue) : SubmissionCborValue
}

private class SubmissionCborReader(private val bytes: ByteArray) {
    private var offset: Int = 0

    fun readValue(): SubmissionCborValue {
        val initial = readByte()
        val major = initial ushr 5
        val additional = initial and 0x1f
        return when (major) {
            0 -> SubmissionCborValue.Unsigned(readAdditional(additional))
            1 -> {
                val encoded = readAdditional(additional)
                require(encoded < Long.MAX_VALUE) { "CBOR negative integer exceeds supported range" }
                SubmissionCborValue.Negative(-1L - encoded)
            }
            2 -> SubmissionCborValue.Bytes(readByteString(readAdditional(additional)))
            3 -> SubmissionCborValue.Text(readByteString(readAdditional(additional)).decodeToString())
            4 -> {
                val length = readContainerLength(additional)
                SubmissionCborValue.ArrayValue(List(length) { readValue() })
            }
            5 -> readMap(additional)
            6 -> SubmissionCborValue.Tag(readAdditional(additional), readValue())
            else -> throw IllegalArgumentException("floating-point, simple, or reserved CBOR is not allowed")
        }
    }

    fun requireFinished() {
        require(offset == bytes.size) { "trailing CBOR bytes" }
    }

    private fun readMap(additional: Int): SubmissionCborValue.MapValue {
        val length = readContainerLength(additional)
        val entries = ArrayList<Pair<SubmissionCborValue, SubmissionCborValue>>(length)
        var previousKey: ByteArray? = null
        repeat(length) {
            val keyStart = offset
            val key = readValue()
            val keyBytes = bytes.copyOfRange(keyStart, offset)
            previousKey?.let { previous ->
                require(compareLexicographically(previous, keyBytes) < 0) {
                    "CBOR map keys must be canonical, unique, and sorted"
                }
            }
            previousKey = keyBytes
            entries += key to readValue()
        }
        return SubmissionCborValue.MapValue(entries)
    }

    private fun readByteString(length: Long): ByteArray {
        require(length <= Int.MAX_VALUE) { "CBOR byte string is too large" }
        val count = length.toInt()
        require(count <= bytes.size - offset) { "truncated CBOR byte string" }
        return bytes.copyOfRange(offset, offset + count).also { offset += count }
    }

    private fun readContainerLength(additional: Int): Int {
        val length = readAdditional(additional)
        require(length <= Int.MAX_VALUE) { "CBOR container is too large" }
        return length.toInt()
    }

    private fun readAdditional(additional: Int): Long = when {
        additional < 24 -> additional.toLong()
        additional == 24 -> readUnsignedBytes(1).also { require(it >= 24) { "non-minimal CBOR" } }
        additional == 25 -> readUnsignedBytes(2).also { require(it > 0xff) { "non-minimal CBOR" } }
        additional == 26 -> readUnsignedBytes(4).also { require(it > 0xffff) { "non-minimal CBOR" } }
        additional == 27 -> readUnsignedBytes(8).also { require(it > 0xffff_ffffL) { "non-minimal CBOR" } }
        else -> throw IllegalArgumentException("indefinite or reserved CBOR is not allowed")
    }

    private fun readUnsignedBytes(count: Int): Long {
        require(count <= bytes.size - offset) { "truncated CBOR integer" }
        if (count == 8) {
            require((bytes[offset].toInt() and 0x80) == 0) { "CBOR integer exceeds supported range" }
        }
        var value = 0L
        repeat(count) {
            value = (value shl 8) or readByte().toLong()
        }
        return value
    }

    private fun readByte(): Int {
        require(offset < bytes.size) { "truncated CBOR" }
        return bytes[offset++].toInt() and 0xff
    }
}

private fun compareLexicographically(left: ByteArray, right: ByteArray): Int {
    val common = minOf(left.size, right.size)
    for (index in 0 until common) {
        val comparison = (left[index].toInt() and 0xff) - (right[index].toInt() and 0xff)
        if (comparison != 0) return comparison
    }
    return left.size - right.size
}

private fun Sha256Digest.toHex(): String = toByteArray().joinToString("") { byte ->
    val value = byte.toInt() and 0xff
    value.toString(16).padStart(2, '0')
}
