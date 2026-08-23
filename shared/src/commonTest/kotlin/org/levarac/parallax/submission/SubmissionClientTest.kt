package org.levarac.parallax.submission

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.test.runTest
import org.levarac.parallax.observation.ImmutableBytes
import org.levarac.parallax.observation.Sha256Digest
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

class SubmissionClientTest {
    @Test
    fun successfulPostSendsStoredBytesAndPersistsVerifiedReceiptResult() = runTest {
        val transport = FakeSubmissionTransport(
            SubmissionHttpResponse(201, ACCEPTANCE_RECEIPT_HEX.hexToBytes()),
        )
        val client = createSubmissionClientForTest(transport)
        val stored = storedObservation()
        val result = client.submitAndAwait(stored, operatorConfiguration())

        assertTrue(result.isSuccess)
        assertNotNull(result.receipt)
        assertContentEquals(stored.signedBytes.toByteArray(), transport.requests.single().body)
        assertEquals("POST", transport.requests.single().method)
        assertEquals(
            "http://127.0.0.1:8787/v1/observations",
            transport.requests.single().url,
        )
        assertEquals(
            OBSERVATION_SUBMISSION_MEDIA_TYPE,
            transport.requests.single().headers["Content-Type"],
        )
        assertEquals(
            ACCEPTANCE_RECEIPT_MEDIA_TYPE,
            transport.requests.single().headers["Accept"],
        )
        assertEquals(
            "4893627cca8a089901f8c2a88cf2dc2143cd0ad02f9fd4879e745b88704dbff9",
            result.receipt.observationDigest.toHexForTest(),
        )
    }

    @Test
    fun lookupUsesTheStoredDigestPathAndVerifiesTheReceipt() = runTest {
        val transport = FakeSubmissionTransport(
            SubmissionHttpResponse(200, ACCEPTANCE_RECEIPT_HEX.hexToBytes()),
        )
        val client = createSubmissionClientForTest(transport)
        val stored = storedObservation()
        val result = client.lookupReceiptAndAwait(stored, operatorConfiguration())

        assertTrue(result.isSuccess)
        assertEquals("GET", transport.requests.single().method)
        assertEquals(
            "http://127.0.0.1:8787/v1/observations/4893627cca8a089901f8c2a88cf2dc2143cd0ad02f9fd4879e745b88704dbff9/acceptance",
            transport.requests.single().url,
        )
        assertTrue(transport.requests.single().body == null)
    }

    @Test
    fun lookup404IsAnExplicitReceiptNotFoundResult() = runTest {
        val transport = FakeSubmissionTransport(
            SubmissionHttpResponse(404, ByteArray(0)),
        )
        val result = createSubmissionClientForTest(transport)
            .lookupReceiptAndAwait(storedObservation(), operatorConfiguration())

        assertFalse(result.isSuccess)
        assertEquals("receipt_not_found", result.errorCode)
        assertFalse(result.isRetryable)
    }

    @Test
    fun responseMediaTypeIsRequiredForAReceipt() = runTest {
        val transport = FakeSubmissionTransport(
            SubmissionHttpResponse(
                statusCode = 201,
                body = ACCEPTANCE_RECEIPT_HEX.hexToBytes(),
                headers = mapOf("Content-Type" to "application/octet-stream"),
            ),
        )
        val result = createSubmissionClientForTest(transport)
            .submitAndAwait(storedObservation(), operatorConfiguration())

        assertFalse(result.isSuccess)
        assertEquals("protocol_error", result.errorCode)
        assertFalse(result.isRetryable)
    }

    @Test
    fun oversizedDeclaredArrayLengthIsRejectedBeforeAllocation() = runTest {
        val response = byteArrayOf(
            0x9a.toByte(),
            0x7f,
            0xff.toByte(),
            0xff.toByte(),
            0xff.toByte(),
        )
        val result = createSubmissionClientForTest(
            FakeSubmissionTransport(
                SubmissionHttpResponse(
                    statusCode = 201,
                    body = response,
                    headers = mapOf("Content-Type" to ACCEPTANCE_RECEIPT_MEDIA_TYPE),
                ),
            ),
        ).submitAndAwait(storedObservation(), operatorConfiguration())

        assertFalse(result.isSuccess)
        assertEquals("protocol_error", result.errorCode)
    }

    @Test
    fun oversizedDeclaredMapLengthIsRejectedBeforeAllocation() = runTest {
        val response = byteArrayOf(
            0xba.toByte(),
            0x7f,
            0xff.toByte(),
            0xff.toByte(),
            0xff.toByte(),
        )
        val result = createSubmissionClientForTest(
            FakeSubmissionTransport(
                SubmissionHttpResponse(
                    statusCode = 201,
                    body = response,
                    headers = mapOf("Content-Type" to ACCEPTANCE_RECEIPT_MEDIA_TYPE),
                ),
            ),
        ).submitAndAwait(storedObservation(), operatorConfiguration())

        assertFalse(result.isSuccess)
        assertEquals("protocol_error", result.errorCode)
    }

    @Test
    fun storedObservationCanBeRestoredWithoutChangingItsBytes() {
        val stored = requireNotNull(restoreStoredObservation(SIGNED_OBSERVATION_HEX))

        assertContentEquals(SIGNED_OBSERVATION_HEX.hexToBytes(), stored.signedBytes.toByteArray())
        assertEquals(
            "4893627cca8a089901f8c2a88cf2dc2143cd0ad02f9fd4879e745b88704dbff9",
            stored.observationDigest.toHexForTest(),
        )
    }

    @Test
    fun retryableStatusesAreReportedRetryableAndTerminalStatusesAreNot() = runTest {
        val retryable = createSubmissionClientForTest(
            FakeSubmissionTransport(SubmissionHttpResponse(429, ByteArray(0))),
        )
        val terminal = createSubmissionClientForTest(
            FakeSubmissionTransport(SubmissionHttpResponse(422, ByteArray(0))),
        )

        val retryableResult = retryable.submitAndAwait(storedObservation(), operatorConfiguration())
        val terminalResult = terminal.submitAndAwait(storedObservation(), operatorConfiguration())

        assertFalse(retryableResult.isSuccess)
        assertTrue(retryableResult.isRetryable)
        assertFalse(terminalResult.isSuccess)
        assertFalse(terminalResult.isRetryable)
    }

    @Test
    fun serverFailuresAndTimeoutsAreReportedRetryable() = runTest {
        val serverResult = createSubmissionClientForTest(
            FakeSubmissionTransport(SubmissionHttpResponse(503, ByteArray(0))),
        ).submitAndAwait(storedObservation(), operatorConfiguration())
        val timeoutResult = createSubmissionClientForTest(TimeoutSubmissionTransport())
            .submitAndAwait(storedObservation(), operatorConfiguration())

        assertTrue(serverResult.isRetryable)
        assertEquals("server_error", serverResult.errorCode)
        assertTrue(timeoutResult.isRetryable)
        assertEquals("timeout", timeoutResult.errorCode)
    }

    @Test
    fun anIdempotentResubmissionUsesTheSameStoredBytes() = runTest {
        val transport = FakeSubmissionTransport(
            SubmissionHttpResponse(201, ACCEPTANCE_RECEIPT_HEX.hexToBytes()),
            SubmissionHttpResponse(200, ACCEPTANCE_RECEIPT_HEX.hexToBytes()),
        )
        val client = createSubmissionClientForTest(transport)
        val stored = storedObservation()

        assertTrue(client.submitAndAwait(stored, operatorConfiguration()).isSuccess)
        assertTrue(client.submitAndAwait(stored, operatorConfiguration()).isSuccess)

        assertEquals(2, transport.requests.size)
        assertContentEquals(transport.requests[0].body, transport.requests[1].body)
    }

    private suspend fun SubmissionClient.submitAndAwait(
        stored: StoredObservationV1,
        configuration: SubmissionOperatorConfiguration,
    ): SubmissionResult {
        val result = CompletableDeferred<SubmissionResult>()
        submit(stored, configuration) { result.complete(it) }
        return result.await()
    }

    private suspend fun SubmissionClient.lookupReceiptAndAwait(
        stored: StoredObservationV1,
        configuration: SubmissionOperatorConfiguration,
    ): SubmissionResult {
        val result = CompletableDeferred<SubmissionResult>()
        lookupReceipt(stored, configuration) { result.complete(it) }
        return result.await()
    }

    private fun storedObservation(): StoredObservationV1 = StoredObservationV1(
        signedBytes = ImmutableBytes(SIGNED_OBSERVATION_HEX.hexToBytes()),
        observationDigest = Sha256Digest(
            "4893627cca8a089901f8c2a88cf2dc2143cd0ad02f9fd4879e745b88704dbff9".hexToBytes(),
        ),
    )

    private fun operatorConfiguration(): SubmissionOperatorConfiguration =
        requireNotNull(createSubmissionOperatorConfiguration(
            endpoint = "http://127.0.0.1:8787",
            receiptPublicKeyHex = "02c6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee5",
            allowInsecureLoopbackForTests = true,
        ))

    private class FakeSubmissionTransport(
        private vararg val responses: SubmissionHttpResponse,
    ) : SubmissionHttpTransport {
        val requests = mutableListOf<SubmissionHttpRequest>()
        private var responseIndex = 0

        override suspend fun execute(request: SubmissionHttpRequest): SubmissionHttpResponse {
            requests += request
            val response = responses[minOf(responseIndex++, responses.lastIndex)]
            return if (response.body.isNotEmpty() && response.headers.isEmpty()) {
                response.copy(headers = mapOf("Content-Type" to ACCEPTANCE_RECEIPT_MEDIA_TYPE))
            } else {
                response
            }
        }
    }

    private class TimeoutSubmissionTransport : SubmissionHttpTransport {
        override suspend fun execute(request: SubmissionHttpRequest): SubmissionHttpResponse {
            throw SubmissionTransportTimeoutException()
        }
    }

    private fun String.hexToBytes(): ByteArray {
        require(length % 2 == 0)
        return ByteArray(length / 2) { index -> substring(index * 2, index * 2 + 2).toInt(16).toByte() }
    }

    private fun Sha256Digest.toHexForTest(): String = toByteArray().joinToString("") {
        (it.toInt() and 0xff).toString(16).padStart(2, '0')
    }

    private companion object {
        const val SIGNED_OBSERVATION_HEX =
            "d2845839a301382e0378286170706c69636174696f6e2f766e642e6c6576617261632e6f62736572766174696f6e2b63626f7204485ef036280edf16eba0590103a80101025000112233445566778899aabbccddeeff0378196c6576617261632e6d757475616c2d73656e73696e672f76310458205d5891b92a9a6597aa2c58586fd2fdf3974f40f732b9a319ec9f3fc4d7ab31950558210279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798061a6b49d2000751011010101010101010101010101010101008586fa501582047414a8186bba5f3ebccfc8fb8c6f5436cc586685041f185ac4a687e3704243d021a005b8d80038251012020202020202020202020202020202051013030303030303030303030303030303004581a746573742d6f6e6c792d6b65792d686f6c6465722d636c61696d05f6584018496b67eb1652a5c6eeb23587110819c9b709c6ebc6480951eb90e114ac1da77c43599cb4cdd431837db184dbcea617a8b256678eace436d7e09bd30b1d740f"
        const val ACCEPTANCE_RECEIPT_HEX =
            "d2845840a301382e03782f6170706c69636174696f6e2f766e642e6c6576617261632e616363657074616e63652d726563656970742b63626f7204482975d3634802af4ea0589ba7010102582050d8f3689f95e95c30be32dc4e516460dff139c088ab1117af0c1041882529490358204893627cca8a089901f8c2a88cf2dc2143cd0ad02f9fd4879e745b88704dbff90458205d5891b92a9a6597aa2c58586fd2fdf3974f40f732b9a319ec9f3fc4d7ab3195051a6b49d201061a6b49d32d075820666666666666666666666666666666666666666666666666666666666666666658409f416da83bf7210f32324b7a4beac3837adbbf8022416b95f2f795ff598daa1369c4e8b8bd3462a87d71c0863a17ff2db96d1c8532cc16265e673cee6f953f16"
    }
}
