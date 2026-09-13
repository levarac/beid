package org.levarac.beid.sensing

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.CompletableDeferred
import org.junit.AssumptionViolatedException
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.levarac.parallax.observation.ObservationPreparationResult
import org.levarac.parallax.observation.createMutualSensingWindowEvidence
import org.levarac.parallax.observation.prepareMutualSensingObservation
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
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
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

    @Test
    fun optInRealBarnardObservationReachesLocalReferenceOperator() = runTest {
        if (System.getenv("BEID_RUN_OPERATOR_SUBMISSION_TEST") != "1") {
            throw AssumptionViolatedException("set BEID_RUN_OPERATOR_SUBMISSION_TEST=1 to run local operator integration")
        }
        val endpoint = requireNotNull(System.getenv("BEID_OPERATOR_SUBMISSION_ENDPOINT"))
        val receiptPublicKeyHex = requireNotNull(System.getenv("BEID_OPERATOR_RECEIPT_PUBLIC_KEY"))
        val eventIdHex = requireNotNull(System.getenv("BEID_EVENT_ID"))
        val definitionDigestHex = requireNotNull(System.getenv("BEID_EVENT_DEFINITION_DIGEST"))
        val eventCode = "android-operator-integration"
        val cryptography = BarnardSensingCryptography(
            context = androidx.test.core.app.ApplicationProvider.getApplicationContext(),
            keyStorage = object : OwnerKeyStorage {
                override fun readBytes(key: String): OwnerKeyReadResult =
                    OwnerKeyReadResult.Present(ByteArray(32) { (it + 1).toByte() })
                override fun putBytes(key: String, bytes: ByteArray) = Unit
            },
            randomSource = object : OwnerKeyRandomSource {
                override fun randomBytes(count: Int): ByteArray = error("fixture must not use randomness")
            },
        )
        val evidence = requireNotNull(
            createMutualSensingWindowEvidence(
                idHex = "33".repeat(16),
                eventIdHex = eventIdHex,
                eventDefinitionDigestHex = definitionDigestHex,
                observerHex = cryptography.eventSigningPublicKey(eventCode).testHex(),
                finalizedAt = 1_800_000_000.0,
                reporterRpidHex = "01" + "aa".repeat(16),
                enin = 1,
                observedRpidHexes = listOf("01" + "bb".repeat(16)),
            ),
        )
        val eligible = requireNotNull(
            prepareMutualSensingObservation(evidence) as? ObservationPreparationResult.Eligible,
        )
        val signature = cryptography.signWindowReport(
            eventCode,
            eligible.prepared.sigStructure.toByteArray(),
        )
        val signed = eligible.prepared.signWithCompactSignatureHex(
            signature.r.testHex(),
            signature.s.testHex(),
        )
        val observation = org.levarac.parallax.submission.storeSignedObservation(signed)
        val configuration = requireNotNull(
            createSubmissionOperatorConfiguration(
                endpoint = endpoint,
                receiptPublicKeyHex = receiptPublicKeyHex,
                eventIdHex = eventIdHex,
                eventDefinitionDigestHex = definitionDigestHex,
                allowInsecureLoopbackForTests = true,
            ),
        )
        val result = createSubmissionClient().submitAndAwait(observation, configuration)
        assertTrue(result.isSuccess, "expected verified receipt, got errorCode=${result.errorCode}")
        assertEquals(201, result.statusCode)
        assertEquals(eventIdHex, result.receipt?.context?.toByteArray()?.testHex())
        assertEquals(definitionDigestHex, result.receipt?.policyDigest?.toByteArray()?.testHex())
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

private fun ByteArray.testHex(): String = joinToString("") { "%02x".format(it.toInt() and 0xff) }
