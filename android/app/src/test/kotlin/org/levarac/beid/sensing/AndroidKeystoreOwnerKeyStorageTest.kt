package org.levarac.beid.sensing

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import java.io.IOException
import java.security.KeyStoreException
import java.security.NoSuchAlgorithmException
import java.security.UnrecoverableKeyException
import java.util.UUID
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertTrue
import javax.crypto.spec.SecretKeySpec
import org.levarac.barnard.BarnardIdentity
import org.junit.After
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class AndroidKeystoreOwnerKeyStorageTest {
    private val context: Context = ApplicationProvider.getApplicationContext()
    private val preferencesName = "owner-key-storage-test-${UUID.randomUUID()}"
    private val preferences by lazy { context.getSharedPreferences(preferencesName, Context.MODE_PRIVATE) }
    private val protector = RecordingOwnerKeyProtector(
        AesGcmOwnerKeyProtector(
            existingKey = { SecretKeySpec(ByteArray(32) { 0x2a }, "AES") },
            keyForWrite = { SecretKeySpec(ByteArray(32) { 0x2a }, "AES") },
        ),
    )
    private val storage by lazy { AndroidKeystoreOwnerKeyStorage(preferences, protector) }

    @Before
    fun setUp() {
        preferences.edit().clear().commit()
    }

    @After
    fun tearDown() {
        preferences.edit().clear().commit()
    }

    @Test
    fun failedCommitMemoryMustNotBecomeAUsableIdentityOnRetry() {
        val memory = mutableMapOf<String, String>()
        val cacheOnlyPreferences = object : android.content.SharedPreferences by preferences {
            override fun contains(key: String?): Boolean = memory.containsKey(key)
            override fun getString(key: String?, defaultValue: String?): String? = memory[key] ?: defaultValue
            override fun edit(): android.content.SharedPreferences.Editor {
                val delegate = preferences.edit()
                return object : android.content.SharedPreferences.Editor by delegate {
                    override fun putString(key: String?, value: String?): android.content.SharedPreferences.Editor {
                        if (key != null && value != null) memory[key] = value
                        return this
                    }
                    override fun commit(): Boolean = false
                }
            }
        }
        val failedStore = AndroidKeystoreOwnerKeyStorage(
            cacheOnlyPreferences,
            protector,
            durableSnapshot = { null },
        )
        kotlin.test.assertFailsWith<OwnerKeyUnavailableException> { failedStore.putBytes(SEED_KEY, sequentialSeed()) }
        val reopened = AndroidKeystoreOwnerKeyStorage(
            cacheOnlyPreferences,
            protector,
            durableSnapshot = { null },
        )
        assertFalse(reopened.readBytes(SEED_KEY) is OwnerKeyReadResult.Present)
    }

    @Test
    fun providerRetriesFailedFirstCommitWithTheSameSeedAndRestartReadsOnlyDisk() {
        val modeled = MemoryBeforeDiskPreferences(preferences, emptyMap())
        modeled.failCommitAt = 1
        var randomCalls = 0
        val random = object : OwnerKeyRandomSource {
            override fun randomBytes(count: Int): ByteArray {
                randomCalls += 1
                return sequentialBytes(randomCalls, count)
            }
        }
        val provider = OwnerKeyProvider(
            BarnardIdentity(context),
            AndroidKeystoreOwnerKeyStorage(modeled, protector, modeled::durableSnapshot),
            random,
        )

        assertFailsWith<OwnerKeyUnavailableException> { provider.publicKeyCompressed() }
        assertTrue(modeled.durableSnapshot().isEmpty())
        provider.publicKeyCompressed()
        assertEquals(1, randomCalls, "a retry before a durable identity exists must reuse its pending seed")

        val restartedPreferences = MemoryBeforeDiskPreferences(preferences, modeled.durableSnapshot())
        val restartRandom = object : OwnerKeyRandomSource {
            override fun randomBytes(count: Int): ByteArray = error("restart must read the durable seed")
        }
        val restarted = OwnerKeyProvider(
            BarnardIdentity(context),
            AndroidKeystoreOwnerKeyStorage(restartedPreferences, protector, restartedPreferences::durableSnapshot),
            restartRandom,
        )
        assertEquals(33, restarted.publicKeyCompressed().size)
    }

    @Test
    fun corruptPhysicalXmlMustNeverBeMissing() {
        val name = "corrupt-owner-${UUID.randomUUID()}"
        val file = java.io.File(context.applicationInfo.dataDir, "shared_prefs/$name.xml")
        file.parentFile!!.mkdirs()
        file.writeText("<map><string name=broken")
        val loaded = context.getSharedPreferences(name, Context.MODE_PRIVATE)
        val brokenStore = AndroidKeystoreOwnerKeyStorage(
            loaded,
            protector,
            durableSnapshot = { sharedPreferencesDurableSnapshot(file) },
        )
        assertFalse(brokenStore.readBytes(SEED_KEY) is OwnerKeyReadResult.Missing)
        assertEquals("<map><string name=broken", file.readText())
    }

    @Test
    fun durableSnapshotUsesAtomicFileBackupWhenPrimaryAndBackupBothExist() {
        val name = "backup-owner-${UUID.randomUUID()}"
        val file = java.io.File(context.applicationInfo.dataDir, "shared_prefs/$name.xml")
        val backup = java.io.File(file.path + ".bak")
        file.parentFile!!.mkdirs()
        file.writeText("<map><string name=\"beid.ownerKeySeed\">uncommitted-primary</string></map>")
        backup.writeText("<map><string name=\"beid.ownerKeySeed\">last-committed-backup</string></map>")

        assertEquals("last-committed-backup", sharedPreferencesDurableSnapshot(file)?.get(SEED_KEY))
    }

    @Test
    fun unsupportedPhysicalXmlValueMustNeverBeMissing() {
        val name = "wrong-type-owner-${UUID.randomUUID()}"
        val file = java.io.File(context.applicationInfo.dataDir, "shared_prefs/$name.xml")
        file.parentFile!!.mkdirs()
        file.writeText("<map><int name=beid.ownerKeySeed value=1 /></map>")
        val loaded = context.getSharedPreferences(name, Context.MODE_PRIVATE)
        val brokenStore = AndroidKeystoreOwnerKeyStorage(
            loaded,
            protector,
            durableSnapshot = { sharedPreferencesDurableSnapshot(file) },
        )
        assertFalse(brokenStore.readBytes(SEED_KEY) is OwnerKeyReadResult.Missing)
    }

    @Test
    fun durableSeedWinsWhenProcessCacheIsEmpty() {
        val seed = sequentialSeed()
        val protected = protector.protect(seed)
        val envelope = android.util.Base64.encodeToString(
            protected.initializationVector + protected.ciphertext,
            android.util.Base64.NO_WRAP,
        )
        val emptyCache = object : android.content.SharedPreferences by preferences {
            override fun contains(key: String?): Boolean = false
            override fun getString(key: String?, defaultValue: String?): String? = defaultValue
        }
        val loaded = AndroidKeystoreOwnerKeyStorage(
            emptyCache,
            protector,
            durableSnapshot = { mapOf(SEED_KEY to "beid-owner-key:v1:$envelope") },
        )
        assertContentEquals(seed, assertIs<OwnerKeyReadResult.Present>(loaded.readBytes(SEED_KEY)).bytes)
    }

    @Test
    fun absentDurableFileWithExistingKeyIsRestoreMismatch() {
        val keyedProtector = object : OwnerKeyProtector by protector {
            override fun hasExistingKey(): Boolean = true
        }
        val loaded = AndroidKeystoreOwnerKeyStorage(preferences, keyedProtector, durableSnapshot = { null })
        assertEquals(OwnerKeyStorageFailure.RESTORE_MISMATCH, assertIs<OwnerKeyReadResult.Failure>(loaded.readBytes(SEED_KEY)).reason)
    }

    @Test
    fun absentEntryIsTheOnlyMissingState() {
        assertEquals(OwnerKeyReadResult.Missing, storage.readBytes(SEED_KEY))
        assertEquals(0, protector.unprotectCalls)
    }

    @Test
    fun nonemptySeedlessDurableStateIsCorruptRatherThanMissing() {
        val loaded = AndroidKeystoreOwnerKeyStorage(
            preferences,
            protector,
            durableSnapshot = { mapOf("unexpected" to "preserved evidence") },
        )

        assertEquals(
            OwnerKeyReadResult.Failure(OwnerKeyStorageFailure.CORRUPT),
            loaded.readBytes(SEED_KEY),
        )
    }

    @Test
    fun unavailableExistingKeyInspectionIsTypedTemporaryFailure() {
        val inspectionFailure = object : OwnerKeyProtector by protector {
            override fun hasExistingKey(): Boolean = error("AndroidKeyStore unavailable")
        }
        val loaded = AndroidKeystoreOwnerKeyStorage(
            preferences,
            inspectionFailure,
            durableSnapshot = { null },
        )

        assertEquals(
            OwnerKeyReadResult.Failure(OwnerKeyStorageFailure.TEMPORARILY_UNAVAILABLE),
            loaded.readBytes(SEED_KEY),
        )
    }

    @Test
    fun checkedExistingKeyInspectionFailuresNeverGenerateOrWrite() {
        val checkedFailures = listOf(
            IOException("keystore load failed"),
            KeyStoreException("keystore unavailable"),
            NoSuchAlgorithmException("keystore provider unavailable"),
            UnrecoverableKeyException("keystore key unavailable"),
        )
        checkedFailures.forEach { checkedFailure ->
            preferences.edit().clear().commit()
            val inspectionFailure = object : OwnerKeyProtector by protector {
                override fun hasExistingKey(): Boolean = throw checkedFailure
            }
            var randomCalls = 0
            val provider = OwnerKeyProvider(
                BarnardIdentity(context),
                AndroidKeystoreOwnerKeyStorage(preferences, inspectionFailure, durableSnapshot = { null }),
                object : OwnerKeyRandomSource {
                    override fun randomBytes(count: Int): ByteArray {
                        randomCalls += 1
                        return ByteArray(count)
                    }
                },
            )

            val error = assertFailsWith<OwnerKeyUnavailableException> { provider.publicKeyCompressed() }

            assertEquals(OwnerKeyStorageFailure.TEMPORARILY_UNAVAILABLE, error.failure)
            assertEquals(0, randomCalls, "${checkedFailure.javaClass.simpleName} must not generate an identity")
            assertFalse(preferences.contains(SEED_KEY), "${checkedFailure.javaClass.simpleName} must not write an identity")
        }
    }

    @Test
    fun staleDurablePromotionFailsWithoutRecursing() {
        val seed = sequentialSeed()
        val legacy = android.util.Base64.encodeToString(seed, android.util.Base64.NO_WRAP)
        preferences.edit().putString(SEED_KEY, legacy).commit()
        var snapshotCalls = 0
        val staleDurable = {
            snapshotCalls += 1
            check(snapshotCalls <= 3) { "migration must perform a bounded durable verification" }
            mapOf(SEED_KEY to legacy)
        }
        val loaded = AndroidKeystoreOwnerKeyStorage(preferences, protector, staleDurable)

        assertEquals(
            OwnerKeyStorageFailure.WRITE_VERIFICATION_FAILED,
            assertIs<OwnerKeyReadResult.Failure>(loaded.readBytes(SEED_KEY)).reason,
        )
        assertTrue(snapshotCalls <= 3)
    }

    @Test
    fun legacyPlaintextMigratesWithoutChangingTheSeed() {
        val seed = sequentialSeed()
        val legacy = android.util.Base64.encodeToString(seed, android.util.Base64.NO_WRAP)
        preferences.edit().putString(SEED_KEY, legacy).commit()

        val result = assertIs<OwnerKeyReadResult.Present>(storage.readBytes(SEED_KEY))

        assertContentEquals(seed, result.bytes)
        assertTrue(preferences.getString(SEED_KEY, null)!!.startsWith("beid-owner-key:v1:"))
        assertContentEquals(seed, assertIs<OwnerKeyReadResult.Present>(storage.readBytes(SEED_KEY)).bytes)
    }

    @Test
    fun migrationVerificationFailureKeepsThePlaintextSeedForRecovery() {
        val legacy = android.util.Base64.encodeToString(sequentialSeed(), android.util.Base64.NO_WRAP)
        preferences.edit().putString(SEED_KEY, legacy).commit()
        protector.nextUnprotectFailure = OwnerKeyStorageFailure.TEMPORARILY_UNAVAILABLE

        assertEquals(OwnerKeyReadResult.Failure(OwnerKeyStorageFailure.TEMPORARILY_UNAVAILABLE), storage.readBytes(SEED_KEY))
        assertEquals(legacy, preferences.getString(SEED_KEY, null))
        protector.nextUnprotectFailure = null
        assertContentEquals(sequentialSeed(), assertIs<OwnerKeyReadResult.Present>(storage.readBytes(SEED_KEY)).bytes)
    }

    @Test
    fun malformedLegacySeedRemainsIntactAndIsNeverMissing() {
        preferences.edit().putString(SEED_KEY, "invalid-seed").commit()
        assertEquals(OwnerKeyReadResult.Failure(OwnerKeyStorageFailure.CORRUPT), storage.readBytes(SEED_KEY))
        assertEquals("invalid-seed", preferences.getString(SEED_KEY, null))
    }

    @Test
    fun interruptedMigrationResumesOnlyIfStagedSeedMatchesTheOriginal() {
        val seed = sequentialSeed()
        val legacy = android.util.Base64.encodeToString(seed, android.util.Base64.NO_WRAP)
        preferences.edit().putString(SEED_KEY, legacy).commit()
        storage.putBytes("$SEED_KEY.migration.v1", ByteArray(32) { 0x19 })
        val staged = preferences.getString("$SEED_KEY.migration.v1", null)

        assertEquals(OwnerKeyReadResult.Failure(OwnerKeyStorageFailure.WRITE_VERIFICATION_FAILED), storage.readBytes(SEED_KEY))
        assertEquals(legacy, preferences.getString(SEED_KEY, null))
        assertEquals(staged, preferences.getString("$SEED_KEY.migration.v1", null))
    }

    @Test
    fun failedMigrationCommitReturnsFailureAndPreservesOriginalSeed() {
        val legacy = android.util.Base64.encodeToString(sequentialSeed(), android.util.Base64.NO_WRAP)
        preferences.edit().putString(SEED_KEY, legacy).commit()
        val failedPreferences = object : android.content.SharedPreferences by preferences {
            override fun edit(): android.content.SharedPreferences.Editor {
                val editor = preferences.edit()
                return object : android.content.SharedPreferences.Editor by editor {
                    override fun putString(key: String?, value: String?): android.content.SharedPreferences.Editor {
                        editor.putString(key, value)
                        return this
                    }
                    override fun commit(): Boolean = false
                }
            }
        }
        val failing = AndroidKeystoreOwnerKeyStorage(failedPreferences, protector)
        assertEquals(OwnerKeyReadResult.Failure(OwnerKeyStorageFailure.WRITE_FAILED), failing.readBytes(SEED_KEY))
        assertEquals(legacy, preferences.getString(SEED_KEY, null))
    }

    @Test
    fun failedMigrationPromotionCanRetryAfterDiskRecovers() {
        val seed = sequentialSeed()
        val legacy = android.util.Base64.encodeToString(seed, android.util.Base64.NO_WRAP)
        val modeled = MemoryBeforeDiskPreferences(preferences, mapOf(SEED_KEY to legacy))
        modeled.failCommitAt = 1 // staging write fails after changing process memory only.
        val first = AndroidKeystoreOwnerKeyStorage(modeled, protector, modeled::durableSnapshot)
        assertEquals(OwnerKeyStorageFailure.WRITE_FAILED, assertIs<OwnerKeyReadResult.Failure>(first.readBytes(SEED_KEY)).reason)
        assertEquals(legacy, modeled.durableSnapshot()[SEED_KEY])
        assertFalse(modeled.durableSnapshot().containsKey("$SEED_KEY.migration.v1"))
        modeled.failCommitAt = null
        val second = AndroidKeystoreOwnerKeyStorage(modeled, protector, modeled::durableSnapshot)
        assertContentEquals(seed, assertIs<OwnerKeyReadResult.Present>(second.readBytes(SEED_KEY)).bytes)
    }

    @Test
    fun failedPromotionMemoryDivergenceRetriesFromDurableLegacyAndStaging() {
        val seed = sequentialSeed()
        val legacy = android.util.Base64.encodeToString(seed, android.util.Base64.NO_WRAP)
        val modeled = MemoryBeforeDiskPreferences(preferences, mapOf(SEED_KEY to legacy))
        modeled.failCommitAt = 2 // staging succeeds; promotion mutates memory but not disk.
        val first = AndroidKeystoreOwnerKeyStorage(modeled, protector, modeled::durableSnapshot)

        assertEquals(
            OwnerKeyStorageFailure.WRITE_FAILED,
            assertIs<OwnerKeyReadResult.Failure>(first.readBytes(SEED_KEY)).reason,
        )
        assertEquals(legacy, modeled.durableSnapshot()[SEED_KEY])
        assertTrue(modeled.durableSnapshot().containsKey("$SEED_KEY.migration.v1"))

        val second = AndroidKeystoreOwnerKeyStorage(modeled, protector, modeled::durableSnapshot)
        assertContentEquals(seed, assertIs<OwnerKeyReadResult.Present>(second.readBytes(SEED_KEY)).bytes)
        assertTrue(modeled.durableSnapshot().getValue(SEED_KEY).startsWith("beid-owner-key:v1:"))
        assertFalse(modeled.durableSnapshot().containsKey("$SEED_KEY.migration.v1"))
    }

    @Test
    fun malformedProtectedEnvelopeIsCorruptAndRemainsIntact() {
        val malformed = "beid-owner-key:v1:not-base64"
        preferences.edit().putString(SEED_KEY, malformed).commit()

        val result = storage.readBytes(SEED_KEY)

        assertEquals(OwnerKeyReadResult.Failure(OwnerKeyStorageFailure.CORRUPT), result)
        assertEquals(malformed, preferences.getString(SEED_KEY, null))
        assertEquals(0, protector.unprotectCalls)
    }

    @Test
    fun missingKeystoreKeyIsReportedAsRestoreMismatchWithoutChangingCiphertext() {
        storage.putBytes(SEED_KEY, sequentialSeed())
        val storedEnvelope = preferences.getString(SEED_KEY, null)
        protector.nextUnprotectFailure = OwnerKeyStorageFailure.RESTORE_MISMATCH

        val result = storage.readBytes(SEED_KEY)

        assertEquals(OwnerKeyReadResult.Failure(OwnerKeyStorageFailure.RESTORE_MISMATCH), result)
        assertEquals(storedEnvelope, preferences.getString(SEED_KEY, null))
    }

    @Test
    fun writeStoresOnlyProtectedEnvelopeAndCanReadBackOriginalBytes() {
        val seed = sequentialSeed()

        storage.putBytes(SEED_KEY, seed)

        val rawStored = preferences.getString(SEED_KEY, null)
        assertTrue(rawStored?.startsWith("beid-owner-key:v1:") == true)
        assertFalse(rawStored.orEmpty().contains(android.util.Base64.encodeToString(seed, android.util.Base64.NO_WRAP)))
        val result = assertIs<OwnerKeyReadResult.Present>(storage.readBytes(SEED_KEY))
        assertContentEquals(seed, result.bytes)
    }

    @Test
    fun tamperedCiphertextIsReportedAsCorruptAndNeverReplaced() {
        storage.putBytes(SEED_KEY, sequentialSeed())
        val stored = requireNotNull(preferences.getString(SEED_KEY, null))
        val replacement = if (stored.last() == 'A') 'B' else 'A'
        val tampered = stored.dropLast(1) + replacement
        preferences.edit().putString(SEED_KEY, tampered).commit()

        val result = storage.readBytes(SEED_KEY)

        assertEquals(OwnerKeyReadResult.Failure(OwnerKeyStorageFailure.CORRUPT), result)
        assertEquals(tampered, preferences.getString(SEED_KEY, null))
    }

    private companion object {
        const val SEED_KEY = "beid.ownerKeySeed"
    }
}

private class RecordingOwnerKeyProtector(
    private val delegate: OwnerKeyProtector,
) : OwnerKeyProtector {
    var unprotectCalls = 0
        private set
    var nextUnprotectFailure: OwnerKeyStorageFailure? = null

    override fun protect(bytes: ByteArray): ProtectedOwnerKey = delegate.protect(bytes)

    override fun unprotect(value: ProtectedOwnerKey): OwnerKeyUnprotectResult {
        unprotectCalls += 1
        nextUnprotectFailure?.let { return OwnerKeyUnprotectResult.Failure(it) }
        return delegate.unprotect(value)
    }
}

/** Models Android's commit-to-memory-before-disk behavior without treating the process cache as durable. */
private class MemoryBeforeDiskPreferences(
    private val delegate: android.content.SharedPreferences,
    initialDisk: Map<String, String>,
) : android.content.SharedPreferences by delegate {
    private val memory = initialDisk.toMutableMap()
    private val disk = initialDisk.toMutableMap()
    var commitCalls = 0
    var failCommitAt: Int? = null

    override fun contains(key: String?): Boolean = key != null && memory.containsKey(key)

    override fun getString(key: String?, defaultValue: String?): String? =
        key?.let(memory::get) ?: defaultValue

    override fun edit(): android.content.SharedPreferences.Editor {
        val changes = linkedMapOf<String, String?>()
        return object : android.content.SharedPreferences.Editor {
            override fun putString(key: String?, value: String?): android.content.SharedPreferences.Editor {
                if (key != null) changes[key] = value
                return this
            }

            override fun remove(key: String?): android.content.SharedPreferences.Editor {
                if (key != null) changes[key] = null
                return this
            }

            override fun clear(): android.content.SharedPreferences.Editor {
                changes.clear()
                memory.keys.forEach { changes[it] = null }
                return this
            }

            override fun commit(): Boolean {
                commitCalls += 1
                applyChanges(memory, changes)
                if (commitCalls == failCommitAt) return false
                applyChanges(disk, changes)
                return true
            }

            override fun apply() = Unit
            override fun putStringSet(key: String?, values: MutableSet<String>?): android.content.SharedPreferences.Editor = this
            override fun putInt(key: String?, value: Int): android.content.SharedPreferences.Editor = this
            override fun putLong(key: String?, value: Long): android.content.SharedPreferences.Editor = this
            override fun putFloat(key: String?, value: Float): android.content.SharedPreferences.Editor = this
            override fun putBoolean(key: String?, value: Boolean): android.content.SharedPreferences.Editor = this
        }
    }

    fun durableSnapshot(): Map<String, String> = disk.toMap()

    private fun applyChanges(target: MutableMap<String, String>, changes: Map<String, String?>) {
        changes.forEach { (key, value) -> if (value == null) target.remove(key) else target[key] = value }
    }
}
