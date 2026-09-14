package org.levarac.beid.persistence

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.core.app.ActivityScenario
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.security.MessageDigest
import org.levarac.beid.sensing.AndroidKeystoreOwnerKeyStorage
import org.levarac.beid.sensing.AndroidKeystoreOwnerKeyProtector
import org.levarac.beid.sensing.OwnerKeyProvider
import org.levarac.beid.sensing.SecureRandomOwnerKeySource
import org.levarac.beid.sensing.OwnerKeyReadResult
import org.levarac.beid.sensing.BarnardSensingCryptography
import org.levarac.beid.sensing.WindowObservationContext
import org.levarac.beid.sensing.WindowObservationRuntimeOwner
import org.levarac.beid.MainActivity
import org.levarac.beid.sensing.ownerKeyPreferences
import org.levarac.beid.sensing.ownerKeyPreferencesFile
import org.levarac.beid.sensing.sharedPreferencesDurableSnapshot
import org.levarac.barnard.BarnardIdentity
import org.levarac.parallax.submission.createSubmissionOperatorConfiguration

/** Device proof for dispatch#52 using the production stores and key custody. */
@RunWith(AndroidJUnit4::class)
class Dispatch52PersistenceInstrumentationTest {
    @Test
    fun finishProductionActivityNormally() {
        ActivityScenario.launch(MainActivity::class.java).use { it.close() }
    }

    @Test
    fun seedProductionOwnerKeyAndUnsentLedger() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val provider = OwnerKeyProvider(
            BarnardIdentity(context),
            AndroidKeystoreOwnerKeyStorage(ownerKeyPreferences(context)),
            SecureRandomOwnerKeySource(),
        )
        val publicKey = provider.publicKeyCompressed()
        assertTrue(publicKey.isNotEmpty())
        val immediateReadBack = OwnerKeyProvider(
            BarnardIdentity(context),
            AndroidKeystoreOwnerKeyStorage(ownerKeyPreferences(context)),
            SecureRandomOwnerKeySource(),
        ).publicKeyCompressed()
        assertEquals(publicKey.sha256(), immediateReadBack.sha256())
        val productionStorage = AndroidKeystoreOwnerKeyStorage(
            ownerKeyPreferences(context),
            AndroidKeystoreOwnerKeyProtector(),
            durableSnapshot = { sharedPreferencesDurableSnapshot(ownerKeyPreferencesFile(context)) },
        )
        val productionReadBack = OwnerKeyProvider(
            BarnardIdentity(context), productionStorage, SecureRandomOwnerKeySource(),
        ).publicKeyCompressed()
        assertEquals(publicKey.sha256(), productionReadBack.sha256())

        val runtime = WindowObservationRuntimeOwner(
            newWindowId = { java.util.UUID.fromString("00112233-4455-6677-8899-aabbccddeeff") },
            ledgerInstanceId = { "000102030405060708090a0b0c0d0e0f" },
        ).acquire(context.filesDir, BarnardSensingCryptography(context), { 1_800_000_000.75 })
        val eventId = "21".repeat(32)
        val eventDigest = "22".repeat(32)
        val configuration = createSubmissionOperatorConfiguration(
            endpoint = "http://127.0.0.1:9",
            receiptPublicKeyHex = "0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798",
            eventIdHex = eventId,
            eventDefinitionDigestHex = eventDigest,
            allowInsecureLoopbackForTests = true,
        ) ?: error("test operator configuration invalid")
        runtime.updateContext(WindowObservationContext("dispatch52-event", eventId, eventDigest, "ab".repeat(32), configuration))
        assertTrue(runtime.beginEvent("dispatch52-event"))
        runtime.accumulator.observe(6_000_000, "0111111111111111111111111111111111", "0110101010101010101010101010101010", recording = true)
        runtime.accumulator.observe(6_000_000, "0111222222222222222222222222222222", "0110101010101010101010101010101010", recording = true)
        runtime.submissionDrain.close()
        assertTrue(runtime.accumulator.close())
        val file = UnsentWindowLedgerStore.defaultFile(context.filesDir)
        assertTrue(file.exists())
        val testPrefs = InstrumentationRegistry.getInstrumentation().targetContext
            .getSharedPreferences("dispatch52_test_baseline", 0)
        val artifact = context.filesDir.resolve("canonical-observations-v1").listFiles().orEmpty()
            .singleOrNull { it.extension == "cose" } ?: error("signed artifact missing")
        val windowId = artifact.name.substringBefore("--")
        val submissionRecord = SubmissionRecordStore(SubmissionRecordStore.defaultFile(context.filesDir))
            .recordFor(windowId) ?: error("submission record missing")
        assertEquals(windowId, submissionRecord.windowId)
        assertEquals(eventId, submissionRecord.eventIdHex)
        assertEquals(configuration.submissionEndpoint, submissionRecord.submissionEndpoint)
        assertEquals(configuration.receiptPublicKey.toByteArray().hex(), submissionRecord.receiptPublicKeyHex)
        assertEquals(configuration.operatorId.toByteArray().hex(), submissionRecord.operatorIdHex)
        assertEquals(configuration.eventDefinitionDigest?.toByteArray()?.hex(), submissionRecord.eventDefinitionDigestHex)
        assertEquals(null, submissionRecord.unresolvedReason)
        val seedFingerprint = (AndroidKeystoreOwnerKeyStorage(ownerKeyPreferences(context))
            .readBytes("beid.ownerKeySeed") as? OwnerKeyReadResult.Present)?.bytes?.sha256()
        testPrefs.edit()
            .putString("owner_key_sha256", publicKey.sha256())
            .putString("seed_sha256", seedFingerprint)
            .putString("artifact_name", artifact.name)
            .putString("artifact_sha256", artifact.readBytes().sha256())
            .putString("window_id", windowId)
            .putString("submission_endpoint", submissionRecord.submissionEndpoint)
            .putString("receipt_public_key_hex", submissionRecord.receiptPublicKeyHex)
            .putString("operator_id_hex", submissionRecord.operatorIdHex)
            .putString("event_definition_digest_hex", submissionRecord.eventDefinitionDigestHex)
            .commit()
    }

    @Test
    fun verifyProductionOwnerKeyAndUnsentLedgerAfterColdStart() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val provider = OwnerKeyProvider(
            BarnardIdentity(context),
            AndroidKeystoreOwnerKeyStorage(ownerKeyPreferences(context)),
            SecureRandomOwnerKeySource(),
        )
        assertTrue(provider.publicKeyCompressed().isNotEmpty())
        val restored = UnsentWindowLedgerStore(UnsentWindowLedgerStore.defaultFile(context.filesDir)).load()
            ?: error("ledger missing")
        assertTrue(restored.isSuccess)
        assertNotNull(restored.ledger)
        val testPrefs = InstrumentationRegistry.getInstrumentation().targetContext
            .getSharedPreferences("dispatch52_test_baseline", 0)
        val storedSeed = AndroidKeystoreOwnerKeyStorage(ownerKeyPreferences(context))
            .readBytes("beid.ownerKeySeed")
        assertTrue(storedSeed is OwnerKeyReadResult.Present)
        assertEquals(testPrefs.getString("seed_sha256", null), (storedSeed as OwnerKeyReadResult.Present).bytes.sha256())
        assertEquals(testPrefs.getString("owner_key_sha256", null), provider.publicKeyCompressed().sha256())
        val artifactName = testPrefs.getString("artifact_name", null) ?: error("artifact baseline missing")
        val windowId = testPrefs.getString("window_id", null) ?: error("window baseline missing")
        val artifact = context.filesDir.resolve("canonical-observations-v1").resolve(artifactName)
        assertEquals(testPrefs.getString("artifact_sha256", null), artifact.readBytes().sha256())
        val record = SubmissionRecordStore(SubmissionRecordStore.defaultFile(context.filesDir))
            .recordFor(windowId) ?: error("submission record missing after cold start")
        assertEquals(testPrefs.getString("submission_endpoint", null), record.submissionEndpoint)
        assertEquals(testPrefs.getString("receipt_public_key_hex", null), record.receiptPublicKeyHex)
        assertEquals(testPrefs.getString("operator_id_hex", null), record.operatorIdHex)
        assertEquals(testPrefs.getString("event_definition_digest_hex", null), record.eventDefinitionDigestHex)
        assertEquals(null, record.unresolvedReason)
    }

    private fun ByteArray.sha256(): String = MessageDigest.getInstance("SHA-256")
        .digest(this).joinToString("") { "%02x".format(it) }

    private fun ByteArray.hex(): String = joinToString("") { "%02x".format(it) }
}
