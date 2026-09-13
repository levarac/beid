package org.levarac.beid.sensing

import android.content.SharedPreferences
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyPermanentlyInvalidatedException
import android.security.keystore.KeyProperties
import android.security.keystore.UserNotAuthenticatedException
import android.util.Base64
import java.io.IOException
import java.io.File
import java.io.FileInputStream
import java.security.GeneralSecurityException
import java.security.InvalidKeyException
import java.security.KeyStore
import java.security.KeyStoreException
import java.security.UnrecoverableKeyException
import javax.crypto.AEADBadTagException
import javax.crypto.BadPaddingException
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Distinguishes a genuinely absent seed from every state in which existing identity material may still exist. */
sealed interface OwnerKeyReadResult {
    data object Missing : OwnerKeyReadResult
    data class Present(val bytes: ByteArray) : OwnerKeyReadResult
    data class Failure(val reason: OwnerKeyStorageFailure) : OwnerKeyReadResult
}

/** Stable, caller-visible reasons that stop owner-key use without replacing the identity. */
enum class OwnerKeyStorageFailure {
    TEMPORARILY_UNAVAILABLE,
    CORRUPT,
    RESTORE_MISMATCH,
    LEGACY_PLAINTEXT,
    WRITE_FAILED,
    WRITE_VERIFICATION_FAILED,
}

class OwnerKeyUnavailableException(
    val failure: OwnerKeyStorageFailure,
    cause: Throwable? = null,
) : IllegalStateException("Owner key seed unavailable: $failure", cause)

/** Loads/stores [OwnerKeyProvider]'s 32-byte seed without collapsing read failure into absence. */
interface OwnerKeyStorage {
    fun readBytes(key: String): OwnerKeyReadResult
    fun putBytes(key: String, bytes: ByteArray)
}

internal data class ProtectedOwnerKey(
    val initializationVector: ByteArray,
    val ciphertext: ByteArray,
)

internal sealed interface OwnerKeyUnprotectResult {
    data class Success(val bytes: ByteArray) : OwnerKeyUnprotectResult
    data class Failure(val reason: OwnerKeyStorageFailure) : OwnerKeyUnprotectResult
}

internal interface OwnerKeyProtector {
    fun protect(bytes: ByteArray): ProtectedOwnerKey
    fun unprotect(value: ProtectedOwnerKey): OwnerKeyUnprotectResult
    fun hasExistingKey(): Boolean = false
}

/**
 * Stores only an AES-GCM envelope in SharedPreferences. The AES key stays in
 * AndroidKeyStore and is created only on the first write. A restored envelope
 * without its non-backupable Keystore key is a restore mismatch, never an
 * invitation to create a replacement identity.
 */
class AndroidKeystoreOwnerKeyStorage internal constructor(
    private val preferences: SharedPreferences,
    private val protector: OwnerKeyProtector,
    private val durableSnapshot: (() -> Map<String, String>?)? = null,
) : OwnerKeyStorage {
    constructor(preferences: SharedPreferences) : this(preferences, AndroidKeystoreOwnerKeyProtector())

    override fun readBytes(key: String): OwnerKeyReadResult {
        val durable = if (durableSnapshot != null) {
            try { durableSnapshot.invoke() } catch (_: RuntimeException) {
                return OwnerKeyReadResult.Failure(OwnerKeyStorageFailure.TEMPORARILY_UNAVAILABLE)
            }
        } else null
        if (durableSnapshot != null) {
            if (durable == null) {
                return missingOrExistingKeyFailure()
            }
            if (durable.isEmpty()) {
                return missingOrExistingKeyFailure()
            }
            val durableValue = durable[key]
            val durableStaging = durable["$key.migration.v1"]
            if (durableValue == null && durableStaging != null) {
                return OwnerKeyReadResult.Failure(OwnerKeyStorageFailure.WRITE_VERIFICATION_FAILED)
            }
            if (durableValue == null) return OwnerKeyReadResult.Failure(OwnerKeyStorageFailure.CORRUPT)
        }
        if (durableSnapshot == null) {
            val containsKey = try {
                preferences.contains(key)
            } catch (_: RuntimeException) {
                return OwnerKeyReadResult.Failure(OwnerKeyStorageFailure.TEMPORARILY_UNAVAILABLE)
            }
            if (!containsKey) return OwnerKeyReadResult.Missing
        }

        val encoded = try {
            durable?.get(key) ?:
            preferences.getString(key, null)
        } catch (_: ClassCastException) {
            return OwnerKeyReadResult.Failure(OwnerKeyStorageFailure.CORRUPT)
        } catch (_: RuntimeException) {
            return OwnerKeyReadResult.Failure(OwnerKeyStorageFailure.TEMPORARILY_UNAVAILABLE)
        } ?: return OwnerKeyReadResult.Failure(OwnerKeyStorageFailure.CORRUPT)

        if (!encoded.startsWith(ENVELOPE_PREFIX)) {
            return migrateLegacySeed(key, encoded)
        }
        val protected = decodeEnvelope(encoded) ?: return OwnerKeyReadResult.Failure(OwnerKeyStorageFailure.CORRUPT)
        return when (val result = protector.unprotect(protected)) {
            is OwnerKeyUnprotectResult.Success -> OwnerKeyReadResult.Present(result.bytes)
            is OwnerKeyUnprotectResult.Failure -> OwnerKeyReadResult.Failure(result.reason)
        }
    }

    /** Preserve the original until a durable protected copy has been decrypted and compared. */
    private fun migrateLegacySeed(key: String, encoded: String): OwnerKeyReadResult {
        val seed = try {
            Base64.decode(encoded, Base64.NO_WRAP)
        } catch (_: IllegalArgumentException) {
            return OwnerKeyReadResult.Failure(OwnerKeyStorageFailure.CORRUPT)
        }
        if (seed.size != 32) return OwnerKeyReadResult.Failure(OwnerKeyStorageFailure.CORRUPT)
        val stagingKey = "$key.migration.v1"
        return try {
            var staged = if (durableSnapshot != null) {
                durableSnapshot.invoke()?.get(stagingKey)
            } else {
                preferences.getString(stagingKey, null)
            }
            if (staged == null) {
                val encodedStaging = encodeEnvelope(protector.protect(seed))
                if (!preferences.edit().putString(stagingKey, encodedStaging).commit()) {
                    return OwnerKeyReadResult.Failure(OwnerKeyStorageFailure.WRITE_FAILED)
                }
                // A successful commit alone is not evidence: refresh the physical state.
                staged = if (durableSnapshot != null) {
                    durableSnapshot.invoke()?.get(stagingKey)
                } else {
                    preferences.getString(stagingKey, null)
                } ?: return OwnerKeyReadResult.Failure(OwnerKeyStorageFailure.WRITE_VERIFICATION_FAILED)
            }
            val envelope = decodeEnvelope(staged)
                ?: return OwnerKeyReadResult.Failure(OwnerKeyStorageFailure.WRITE_VERIFICATION_FAILED)
            when (val verified = protector.unprotect(envelope)) {
                is OwnerKeyUnprotectResult.Failure -> OwnerKeyReadResult.Failure(verified.reason)
                is OwnerKeyUnprotectResult.Success -> {
                    if (!verified.bytes.contentEquals(seed)) {
                        return OwnerKeyReadResult.Failure(OwnerKeyStorageFailure.WRITE_VERIFICATION_FAILED)
                    }
                    if (!preferences.edit().putString(key, staged).remove(stagingKey).commit()) {
                        return OwnerKeyReadResult.Failure(OwnerKeyStorageFailure.WRITE_FAILED)
                    }
                    verifyPromotedSeed(key, stagingKey, seed)
                }
            }
        } catch (error: OwnerKeyUnavailableException) {
            OwnerKeyReadResult.Failure(error.failure)
        } catch (_: RuntimeException) {
            OwnerKeyReadResult.Failure(OwnerKeyStorageFailure.TEMPORARILY_UNAVAILABLE)
        }
    }

    override fun putBytes(key: String, bytes: ByteArray) {
        val durable = if (durableSnapshot != null) {
            try { durableSnapshot.invoke() } catch (_: RuntimeException) {
                throw OwnerKeyUnavailableException(OwnerKeyStorageFailure.TEMPORARILY_UNAVAILABLE)
            }
        } else null
        val mayCreate = if (durableSnapshot != null) {
            durable == null || durable.isEmpty()
        } else {
            !preferences.contains(key)
        }
        if (!mayCreate) {
            throw OwnerKeyUnavailableException(OwnerKeyStorageFailure.WRITE_FAILED)
        }
        when (existingKeyState()) {
            ExistingKeyState.ABSENT -> Unit
            ExistingKeyState.PRESENT -> throw OwnerKeyUnavailableException(OwnerKeyStorageFailure.RESTORE_MISMATCH)
            ExistingKeyState.UNAVAILABLE -> throw OwnerKeyUnavailableException(OwnerKeyStorageFailure.TEMPORARILY_UNAVAILABLE)
        }
        val protected = try {
            protector.protect(bytes)
        } catch (error: OwnerKeyUnavailableException) {
            throw error
        } catch (error: RuntimeException) {
            throw OwnerKeyUnavailableException(OwnerKeyStorageFailure.WRITE_FAILED, error)
        }
        if (protected.initializationVector.size != GCM_IV_BYTES || protected.ciphertext.size < GCM_TAG_BYTES) {
            throw OwnerKeyUnavailableException(OwnerKeyStorageFailure.WRITE_FAILED)
        }
        val encoded = encodeEnvelope(protected)
        val committed = preferences.edit()
            .putString(key, encoded)
            .commit()
        if (!committed) {
            throw OwnerKeyUnavailableException(OwnerKeyStorageFailure.WRITE_FAILED)
        }
        if (durableSnapshot != null) {
            val persisted = try { durableSnapshot()?.get(key) } catch (_: RuntimeException) { null }
            if (persisted != encoded) {
                throw OwnerKeyUnavailableException(OwnerKeyStorageFailure.WRITE_VERIFICATION_FAILED)
            }
        }
    }

    /** Missing is valid only when no physical owner-key state and no Keystore identity exist. */
    private fun missingOrExistingKeyFailure(): OwnerKeyReadResult = when (existingKeyState()) {
        ExistingKeyState.ABSENT -> OwnerKeyReadResult.Missing
        ExistingKeyState.PRESENT -> OwnerKeyReadResult.Failure(OwnerKeyStorageFailure.RESTORE_MISMATCH)
        ExistingKeyState.UNAVAILABLE -> OwnerKeyReadResult.Failure(OwnerKeyStorageFailure.TEMPORARILY_UNAVAILABLE)
    }

    private fun existingKeyState(): ExistingKeyState = try {
        if (protector.hasExistingKey()) ExistingKeyState.PRESENT else ExistingKeyState.ABSENT
    } catch (_: Exception) {
        ExistingKeyState.UNAVAILABLE
    }

    /** A bounded post-promotion verification; never re-enters legacy migration through [readBytes]. */
    private fun verifyPromotedSeed(key: String, stagingKey: String, seed: ByteArray): OwnerKeyReadResult {
        val encoded = try {
            if (durableSnapshot != null) {
                val durable = durableSnapshot.invoke()
                    ?: return OwnerKeyReadResult.Failure(OwnerKeyStorageFailure.WRITE_VERIFICATION_FAILED)
                if (durable.containsKey(stagingKey)) {
                    return OwnerKeyReadResult.Failure(OwnerKeyStorageFailure.WRITE_VERIFICATION_FAILED)
                }
                durable[key]
            } else {
                preferences.getString(key, null)
            }
        } catch (_: RuntimeException) {
            return OwnerKeyReadResult.Failure(OwnerKeyStorageFailure.TEMPORARILY_UNAVAILABLE)
        } ?: return OwnerKeyReadResult.Failure(OwnerKeyStorageFailure.WRITE_VERIFICATION_FAILED)
        val envelope = decodeEnvelope(encoded)
            ?: return OwnerKeyReadResult.Failure(OwnerKeyStorageFailure.WRITE_VERIFICATION_FAILED)
        return when (val verified = protector.unprotect(envelope)) {
            is OwnerKeyUnprotectResult.Success -> if (verified.bytes.contentEquals(seed)) {
                OwnerKeyReadResult.Present(verified.bytes)
            } else {
                OwnerKeyReadResult.Failure(OwnerKeyStorageFailure.WRITE_VERIFICATION_FAILED)
            }
            is OwnerKeyUnprotectResult.Failure -> OwnerKeyReadResult.Failure(verified.reason)
        }
    }

    private enum class ExistingKeyState { ABSENT, PRESENT, UNAVAILABLE }

    private fun encodeEnvelope(value: ProtectedOwnerKey): String =
        ENVELOPE_PREFIX + Base64.encodeToString(value.initializationVector + value.ciphertext, Base64.NO_WRAP)

    private fun decodeEnvelope(encoded: String): ProtectedOwnerKey? {
        val bytes = try {
            Base64.decode(encoded.removePrefix(ENVELOPE_PREFIX), Base64.NO_WRAP)
        } catch (_: IllegalArgumentException) {
            return null
        }
        if (bytes.size < GCM_IV_BYTES + GCM_TAG_BYTES) return null
        return ProtectedOwnerKey(
            initializationVector = bytes.copyOfRange(0, GCM_IV_BYTES),
            ciphertext = bytes.copyOfRange(GCM_IV_BYTES, bytes.size),
        )
    }

    private companion object {
        const val ENVELOPE_PREFIX = "beid-owner-key:v1:"
        const val GCM_IV_BYTES = 12
        const val GCM_TAG_BYTES = 16
    }
}

/** Reads the on-disk XML independently of SharedPreferences' process cache. */
internal fun sharedPreferencesDurableSnapshot(file: File): Map<String, String>? {
    val backup = File(file.path + ".bak")
    val source = when {
        backup.exists() -> backup
        file.exists() -> file
        else -> return null
    }
    return try {
        val parser = android.util.Xml.newPullParser()
        FileInputStream(source).use { input ->
            parser.setInput(input, "UTF-8")
            val values = mutableMapOf<String, String>()
            var event = parser.eventType
            var rootSeen = false
            while (event != org.xmlpull.v1.XmlPullParser.END_DOCUMENT) {
                if (event == org.xmlpull.v1.XmlPullParser.START_TAG) {
                    if (!rootSeen) {
                        if (parser.name != "map") throw IllegalStateException("preference XML root is not map")
                        rootSeen = true
                    } else {
                        if (parser.name != "string") throw IllegalStateException("unsupported preference XML value")
                        val name = parser.getAttributeValue(null, "name")
                            ?: throw IllegalStateException("preference string has no name")
                        values[name] = parser.nextText()
                    }
                }
                event = parser.next()
            }
            if (!rootSeen) throw IllegalStateException("preference XML has no map root")
            values
        }
    } catch (_: Exception) {
        throw IllegalStateException("owner-key preferences are unreadable")
    }
}

/** AES-GCM itself, separated from the platform key loader so JVM tests exercise the real cipher. */
internal class AesGcmOwnerKeyProtector(
    private val existingKey: () -> SecretKey?,
    private val keyForWrite: () -> SecretKey,
) : OwnerKeyProtector {
    override fun protect(bytes: ByteArray): ProtectedOwnerKey {
        return try {
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.ENCRYPT_MODE, keyForWrite())
            ProtectedOwnerKey(cipher.iv, cipher.doFinal(bytes))
        } catch (error: GeneralSecurityException) {
            throw OwnerKeyUnavailableException(OwnerKeyStorageFailure.TEMPORARILY_UNAVAILABLE, error)
        } catch (error: IOException) {
            throw OwnerKeyUnavailableException(OwnerKeyStorageFailure.TEMPORARILY_UNAVAILABLE, error)
        } catch (error: RuntimeException) {
            throw OwnerKeyUnavailableException(OwnerKeyStorageFailure.TEMPORARILY_UNAVAILABLE, error)
        }
    }

    override fun unprotect(value: ProtectedOwnerKey): OwnerKeyUnprotectResult {
        val key = try {
            existingKey()
        } catch (_: UnrecoverableKeyException) {
            return OwnerKeyUnprotectResult.Failure(OwnerKeyStorageFailure.RESTORE_MISMATCH)
        } catch (_: KeyStoreException) {
            return OwnerKeyUnprotectResult.Failure(OwnerKeyStorageFailure.TEMPORARILY_UNAVAILABLE)
        } catch (_: GeneralSecurityException) {
            return OwnerKeyUnprotectResult.Failure(OwnerKeyStorageFailure.TEMPORARILY_UNAVAILABLE)
        } catch (_: IOException) {
            return OwnerKeyUnprotectResult.Failure(OwnerKeyStorageFailure.TEMPORARILY_UNAVAILABLE)
        } catch (_: RuntimeException) {
            return OwnerKeyUnprotectResult.Failure(OwnerKeyStorageFailure.TEMPORARILY_UNAVAILABLE)
        } ?: return OwnerKeyUnprotectResult.Failure(OwnerKeyStorageFailure.RESTORE_MISMATCH)

        return try {
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, value.initializationVector))
            OwnerKeyUnprotectResult.Success(cipher.doFinal(value.ciphertext))
        } catch (_: AEADBadTagException) {
            OwnerKeyUnprotectResult.Failure(OwnerKeyStorageFailure.CORRUPT)
        } catch (_: BadPaddingException) {
            OwnerKeyUnprotectResult.Failure(OwnerKeyStorageFailure.CORRUPT)
        } catch (_: KeyPermanentlyInvalidatedException) {
            OwnerKeyUnprotectResult.Failure(OwnerKeyStorageFailure.RESTORE_MISMATCH)
        } catch (_: UserNotAuthenticatedException) {
            OwnerKeyUnprotectResult.Failure(OwnerKeyStorageFailure.TEMPORARILY_UNAVAILABLE)
        } catch (_: InvalidKeyException) {
            OwnerKeyUnprotectResult.Failure(OwnerKeyStorageFailure.RESTORE_MISMATCH)
        } catch (_: GeneralSecurityException) {
            OwnerKeyUnprotectResult.Failure(OwnerKeyStorageFailure.TEMPORARILY_UNAVAILABLE)
        } catch (_: RuntimeException) {
            OwnerKeyUnprotectResult.Failure(OwnerKeyStorageFailure.TEMPORARILY_UNAVAILABLE)
        }
    }

    private companion object {
        const val TRANSFORMATION = "AES/GCM/NoPadding"
    }
}

/** Platform key loader; it never exports or persists the AES key. */
internal class AndroidKeystoreOwnerKeyProtector : OwnerKeyProtector {
    private val aesGcm = AesGcmOwnerKeyProtector(
        existingKey = ::loadExistingKey,
        keyForWrite = ::loadOrCreateKey,
    )

    override fun protect(bytes: ByteArray): ProtectedOwnerKey = aesGcm.protect(bytes)

    override fun unprotect(value: ProtectedOwnerKey): OwnerKeyUnprotectResult = aesGcm.unprotect(value)

    override fun hasExistingKey(): Boolean = loadExistingKey() != null

    private fun loadExistingKey(): SecretKey? {
        val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
        return keyStore.getKey(KEY_ALIAS, null) as? SecretKey
    }

    private fun loadOrCreateKey(): SecretKey {
        loadExistingKey()?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEYSTORE)
        generator.init(
            KeyGenParameterSpec.Builder(
                KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setRandomizedEncryptionRequired(true)
                .build(),
        )
        return generator.generateKey()
    }

    private companion object {
        const val ANDROID_KEYSTORE = "AndroidKeyStore"
        const val KEY_ALIAS = "org.levarac.beid.owner-key-seed.v1"
    }
}
