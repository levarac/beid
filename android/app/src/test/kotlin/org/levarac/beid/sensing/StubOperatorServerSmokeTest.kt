package org.levarac.beid.sensing

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.CompletableDeferred
import org.levarac.parallax.submission.SubmissionResult
import org.levarac.parallax.submission.StoredObservationV1
import org.levarac.parallax.submission.SubmissionOperatorConfiguration
import org.levarac.parallax.submission.createSubmissionClient
import org.levarac.parallax.submission.createSubmissionOperatorConfiguration
import org.levarac.parallax.submission.restoreStoredObservation

/**
 * Validates the test-only CBOR encoder + secp256k1 signer + loopback HTTP
 * server in isolation, against the REAL `SubmissionClient`, before any
 * beid#525 acceptance test builds on top of it. Not one of #525's four
 * required tests — infrastructure only.
 */
class StubOperatorServerSmokeTest {
    @Test
    fun realClientAcceptsTheSyntheticOperatorReceipt() = runTest {
        val receiptPublicKeyHex = "02c6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee5"
        val operatorIdHex = testAcceptanceOperatorIdHex(receiptPublicKeyHex)
        val eventIdHex = "11".repeat(32)
        val server = StubOperatorServer(
            operatorIdHex = operatorIdHex,
            eventIdHex = eventIdHex,
            receiptPublicKeyHex = receiptPublicKeyHex,
            receiptPrivateScalar = 2,
        )
        val endpoint = server.start()
        try {
            val configuration = requireNotNull(
                createSubmissionOperatorConfiguration(
                    endpoint = endpoint,
                    receiptPublicKeyHex = receiptPublicKeyHex,
                    eventIdHex = eventIdHex,
                    allowInsecureLoopbackForTests = true,
                ),
            )
            // Arbitrary bytes: `restoreStoredObservation` only requires valid
            // hex, it does not parse COSE structure — this is exercising the
            // stub server + real client + digest pipeline, not observation
            // validity.
            val observation = requireNotNull(
                restoreStoredObservation("ab".repeat(64)),
            ) { "fixture bytes must decode as a StoredObservationV1" }

            val result = createSubmissionClient().submitAndAwait(observation, configuration)

            assertTrue(result.isSuccess, "expected success, got errorCode=${result.errorCode}")
            assertEquals(1, server.postCount)
        } finally {
            server.stop()
        }
    }

    private suspend fun org.levarac.parallax.submission.SubmissionClient.submitAndAwait(
        observation: StoredObservationV1,
        configuration: SubmissionOperatorConfiguration,
    ): SubmissionResult {
        val deferred = CompletableDeferred<SubmissionResult>()
        submit(observation, configuration) { deferred.complete(it) }
        return deferred.await()
    }
}
