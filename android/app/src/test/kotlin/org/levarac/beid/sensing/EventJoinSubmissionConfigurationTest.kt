package org.levarac.beid.sensing

import java.io.File
import java.nio.file.Files
import java.security.MessageDigest
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withContext
import org.levarac.beid.persistence.BindingRecordStore
import org.levarac.beid.persistence.SelfProofRecordStore
import org.levarac.beid.persistence.SubmissionRecordStore
import org.levarac.beid.shared.jointestsupport.createEventDefinitionResolutionForTesting
import org.levarac.parallax.registry.EventDefinitionResolution
import org.levarac.parallax.submission.createSubmissionOperatorConfiguration
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

@OptIn(ExperimentalCoroutinesApi::class)
class EventJoinSubmissionConfigurationTest {
    @Test
    fun nearbyJoinSubmitsVerifiedSettingsAfterRestartWithRegistryOffline() = restart(nearby = true, expired = false)

    @Test
    fun nearbyJoinSubmitsVerifiedSettingsAfterDefinitionExpires() = restart(nearby = true, expired = true)

    @Test
    fun manualJoinSubmitsVerifiedSettingsAfterRestartWithRegistryOffline() = restart(nearby = false, expired = false)

    @Test
    fun manualJoinSubmitsVerifiedSettingsAfterDefinitionExpires() = restart(nearby = false, expired = true)

    private fun restart(nearby: Boolean, expired: Boolean) = runTest {
        val directory = Files.createTempDirectory("join-submission-config").toFile()
        var now = NearbyEventPromotionFixture.VECTOR_NOW_EPOCH_MILLIS
        val registry = OneReadRegistry()
        val firstTransport = JoinSubmissionFixture()
        val firstClient = firstTransport.client(backgroundScope)
        val firstOwner = WindowObservationRuntimeOwner()
        val cryptography = signingCryptography()
        val firstRuntime = firstOwner.acquire(directory, cryptography, { now / 1_000.0 }, firstClient, registry)
        val engine = FakeEventJoinEngine()
        val first = coordinator(directory, engine, firstOwner, registry, cryptography) { now }
        var second: EventJoinCoordinator? = null
        var secondRuntime: WindowObservationRuntime? = null
        val secondTransport = JoinSubmissionFixture()
        val secondClient = secondTransport.client(backgroundScope)
        try {
            // Finish the empty startup recovery before any observations arrive.
            withContext(Dispatchers.IO) { firstRuntime.recoverAfterRelaunch() }
            if (nearby) {
                engine.emitVerifiedEnvelopeV2("nearby", NearbyEventPromotionFixture.CONTAINER, NearbyEventPromotionFixture.ENIN)
                runCurrent()
                first.joinNearbyEvent(NearbyEventPromotionFixture.EVENT_CODE_HASH)
            } else {
                first.joinEvent("community-meetup")
            }
            runCurrent()
            assertEquals(1, engine.joinEventCalls)
            assertEquals(1, registry.definitionReads, "one verified definition read at join/discovery")
            repeat(3) { index ->
                engine.emitDetection(NearbyEventPromotionFixture.ENIN, "01" + "${index + 1}".repeat(32), "peer-$index", REPORTER)
            }
            // End the business window with delivery suspended, as if the process
            // died after the durable close and before its first network request.
            firstRuntime.submissionDrain.close()
            now += 10_000
            first.leaveEvent()
            first.dispose()
            val artifact = directory.resolve("canonical-observations-v1").listFiles().orEmpty().single()
            val signedBytes = artifact.readBytes()
            val recordFile = SubmissionRecordStore.defaultFile(directory)
            val windowId = SubmissionRecordStore(recordFile).records.single().windowId
            assertTrue(firstTransport.requests.isEmpty())

            registry.failure = if (expired) "definition_validity_mismatch" else "timeout"
            now = if (expired) (VALID_UNTIL + 1) * 1_000 else now + 60_000
            // New owners, stores, coordinator and drain: nothing in the first
            // process's context or caches may supply the submission settings.
            val secondOwner = WindowObservationRuntimeOwner()
            val restoredRuntime = secondOwner.acquire(directory, signingCryptography(), { now / 1_000.0 }, secondClient, registry)
            secondRuntime = restoredRuntime
            // Complete startup recovery before the replacement coordinator
            // acquires this process runtime, so its asynchronous startup cannot
            // race the assertions on the deterministic HTTP dispatcher.
            withContext(Dispatchers.IO) { restoredRuntime.recoverAfterRelaunch() }
            runCurrent()
            second = coordinator(directory, FakeEventJoinEngine(), secondOwner, registry, signingCryptography()) { now }

            assertEquals(1, registry.definitionReads, "restart must use the window's verified settings without a registry read")
            val posted = secondTransport.requests.single { it.method == "POST" }
            assertEquals("$ENDPOINT/v1/observations", posted.url)
            assertContentEquals(signedBytes, posted.body, "send exactly the original signed observation")
            val restored = assertNotNull(SubmissionRecordStore(recordFile).recordFor(windowId))
            assertEquals(ENDPOINT, restored.submissionEndpoint)
            assertEquals(RECEIPT_KEY, restored.receiptPublicKeyHex)
            assertEquals(expectedConfiguration.operatorId.toByteArray().hex(), restored.operatorIdHex)
            assertEquals(NearbyEventPromotionFixture.DEFINITION_HASH_HEX, restored.eventDefinitionDigestHex)
            assertEquals(VALID_FROM, restored.validFrom)
            assertEquals(VALID_UNTIL, restored.validUntil)
            assertNull(restored.unresolvedReason)
            assertNull(restored.terminalErrorCode, "a temporary operator failure must keep this queued window retryable")
            assertContentEquals(signedBytes, artifact.readBytes())
        } finally {
            firstRuntime.submissionDrain.close()
            secondRuntime?.submissionDrain?.close()
            first.dispose()
            second?.dispose()
            firstClient.close()
            secondClient.close()
            directory.deleteRecursively()
        }
    }

    private fun TestScope.coordinator(
        directory: File,
        engine: FakeEventJoinEngine,
        owner: WindowObservationRuntimeOwner,
        registry: OneReadRegistry,
        cryptography: SensingCryptography,
        now: () -> Long,
    ) = EventJoinCoordinator(
        engine = engine,
        nowEpochMillis = now,
        coroutineScope = backgroundScope,
        sensingCryptography = cryptography,
        selfProofRecordStore = SelfProofRecordStore(SelfProofRecordStore.defaultFile(directory)),
        bindingRecordStore = BindingRecordStore(BindingRecordStore.defaultFile(directory)),
        ledgerFilesDir = directory,
        windowObservationRuntimeOwner = owner,
        nearbyRegistry = registry.nearby,
        joinRegistry = registry,
        checkpointRuntimeOwner = SessionCheckpointRuntimeOwner(),
    )

    private class OneReadRegistry : EventJoinRegistry {
        var definitionReads = 0
        var failure: String? = null
        private val resolution = JoinSubmissionFixture.withSubmissionConfiguration(
            createEventDefinitionResolutionForTesting(
                eventIdHex = NearbyEventPromotionFixture.EVENT_ID_HEX,
                definitionHashHex = NearbyEventPromotionFixture.DEFINITION_HASH_HEX,
                blockHashHex = NearbyEventPromotionFixture.BLOCK_HASH_HEX,
                eventCodeHashHex = NearbyEventPromotionFixture.EVENT_CODE_HASH,
                validFromEpochSeconds = VALID_FROM,
                validUntilEpochSeconds = VALID_UNTIL,
                keySetDigestHex = NearbyEventPromotionFixture.KEY_SET_DIGEST,
            ),
            expectedConfiguration,
        )

        override fun resolveEventId(code: String, completion: (String?, String?) -> Unit) =
            completion(NearbyEventPromotionFixture.EVENT_ID_HEX, null)

        override fun resolveEventDefinition(
            eventIdHex: String,
            useTimeEpochSeconds: Long,
            completion: (EventDefinitionResolution?, String?) -> Unit,
        ) {
            definitionReads++
            assertEquals(NearbyEventPromotionFixture.EVENT_ID_HEX, eventIdHex)
            completion(resolution.takeIf { failure == null && definitionReads == 1 }, failure ?: "timeout".takeIf { definitionReads > 1 })
        }

        val nearby = object : NearbyEventRegistry {
            override fun resolveEventIdByCodeHash(hashHex: String, completion: (NearbyEventIdLookup) -> Unit): NearbyEventRegistryRequest =
                error("the verified envelope already supplies the canonical event ID")

            override fun resolveEventDefinition(
                eventIdHex: String,
                useTimeEpochSeconds: Long,
                completion: (NearbyEventDefinitionVerification) -> Unit,
            ): NearbyEventRegistryRequest {
                this@OneReadRegistry.resolveEventDefinition(eventIdHex, useTimeEpochSeconds) { answer, _ ->
                    completion(
                        answer?.let { NearbyEventDefinitionVerification.fromResolution(it) }
                            ?: NearbyEventDefinitionVerification(false, null, null, null, null, null),
                    )
                }
                return NearbyEventRegistryRequest {}
            }
        }
    }

    private fun signingCryptography() = object : FakeSensingCryptography(eventSigningPublicKeyResult = SIGNING_KEY.fixtureHexBytes()) {
        override fun signWindowReport(eventCode: String, bytes: ByteArray): SensingRecoverableSignature {
            val (r, s) = TestSecp256k1.sign(MessageDigest.getInstance("SHA-256").digest(bytes), 1)
            return SensingRecoverableSignature(r, s, 0)
        }
    }

    private companion object {
        const val ENDPOINT = "https://operator.example/submit"
        const val SIGNING_KEY = "0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798"
        const val RECEIPT_KEY = "02c6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee5"
        const val REPORTER = "0110101010101010101010101010101010"
        const val VALID_FROM = NearbyEventPromotionFixture.VALID_FROM_ENIN * 300
        const val VALID_UNTIL = (NearbyEventPromotionFixture.VALID_THROUGH_ENIN + 1) * 300 - 1
        val expectedConfiguration = requireNotNull(createSubmissionOperatorConfiguration(
            endpoint = ENDPOINT,
            receiptPublicKeyHex = RECEIPT_KEY,
            eventIdHex = NearbyEventPromotionFixture.EVENT_ID_HEX,
            eventDefinitionDigestHex = NearbyEventPromotionFixture.DEFINITION_HASH_HEX,
            validFrom = VALID_FROM,
            validUntil = VALID_UNTIL,
        ))
    }
}

private fun ByteArray.hex(): String = joinToString("") { "%02x".format(it.toInt() and 0xff) }
