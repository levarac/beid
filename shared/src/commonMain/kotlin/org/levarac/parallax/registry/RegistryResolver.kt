package org.levarac.parallax.registry

import kotlinx.coroutines.delay
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlin.random.Random

public class RegistryCacheKey internal constructor(
    public val chainId: Long,
    public val registryAddressHex: String,
    public val eventIdHex: String,
    public val definitionHashHex: String,
    public val blockNumber: Long,
    public val blockHashHex: String,
)

internal data class RegistryResolvedValue(
    val context: RegistryEventContext,
    val cacheKey: RegistryCacheKey,
    val rawCbor: ByteArray,
    val eip1898Verified: Boolean,
)

internal data class RegistryCachePutResult(
    val retainedValue: RegistryResolvedValue?,
    val unverifiedConflict: Boolean,
    val verifiedConflict: Boolean,
)

internal interface RetryDelay {
    suspend fun wait(delayMillis: Long)
}

internal fun interface JitterSource {
    fun delayMillis(attempt: Int): Long
}

internal class InMemoryRegistryCache(
    private val maxEntries: Int = DEFAULT_MAX_ENTRIES,
) {
    private val mutex = Mutex()
    private val values = mutableListOf<CacheEntry>()

    init {
        require(maxEntries > 0) { "maxEntries must be positive" }
    }

    internal suspend fun findAtBlock(
        chainId: Long,
        registryAddressHex: String,
        eventIdHex: String,
        blockNumber: Long,
        blockHashHex: String,
        requireEip1898: Boolean = false,
    ): RegistryResolvedValue? = mutex.withLock {
        findAndTouch { value ->
            val key = value.cacheKey
            (!requireEip1898 || value.eip1898Verified) &&
                key.chainId == chainId &&
                key.registryAddressHex == registryAddressHex &&
                key.eventIdHex == eventIdHex &&
                key.blockNumber == blockNumber &&
                key.blockHashHex == blockHashHex
        }
    }

    internal suspend fun findByBlockHash(
        chainId: Long,
        registryAddressHex: String,
        eventIdHex: String,
        blockHashHex: String,
    ): RegistryResolvedValue? = mutex.withLock {
        findAndTouch { value ->
            val key = value.cacheKey
            value.eip1898Verified &&
                key.chainId == chainId &&
                key.registryAddressHex == registryAddressHex &&
                key.eventIdHex == eventIdHex &&
                key.blockHashHex == blockHashHex
        }
    }

    internal suspend fun removeByBlockHash(
        chainId: Long,
        registryAddressHex: String,
        eventIdHex: String,
        blockHashHex: String,
    ): Unit = mutex.withLock {
        values.removeAll { entry ->
            val key = entry.value.cacheKey
            key.chainId == chainId &&
                key.registryAddressHex == registryAddressHex &&
                key.eventIdHex == eventIdHex &&
                key.blockHashHex == blockHashHex
        }
    }

    internal suspend fun put(pin: RegistryReadPin, value: RegistryResolvedValue): RegistryCachePutResult =
        mutex.withLock {
            val key = value.cacheKey
            val sameBlockEntries = values.filter { existing ->
                existing.value.cacheKey.isSameEventAndBlockHashAs(key)
            }
            val conflictingEntries = sameBlockEntries.filter { existing ->
                existing.value.cacheKey.blockNumber != key.blockNumber ||
                    !existing.value.rawCbor.contentEquals(value.rawCbor)
            }
            val existingVerified = sameBlockEntries.lastOrNull { it.value.eip1898Verified }
            val unverifiedConflict = conflictingEntries.any { existing ->
                !existing.value.eip1898Verified || !value.eip1898Verified
            }
            val verifiedConflict = conflictingEntries.any { existing ->
                existing.value.eip1898Verified && value.eip1898Verified
            }
            val retainedEntry = if (existingVerified != null &&
                (!value.eip1898Verified || verifiedConflict)
            ) {
                existingVerified
            } else {
                CacheEntry(pin.kind, value)
            }
            val canRetain = !verifiedConflict &&
                !(unverifiedConflict && !retainedEntry.value.eip1898Verified)
            values.removeAll { existing ->
                val existingKey = existing.value.cacheKey
                val sameEvent = existingKey.chainId == key.chainId &&
                    existingKey.registryAddressHex == key.registryAddressHex &&
                    existingKey.eventIdHex == key.eventIdHex
                val supersededMovingPin = pin.kind != RegistryReadPinKind.BLOCK_HASH &&
                    existing.pinKind == pin.kind &&
                    sameEvent
                supersededMovingPin || existingKey.isSameEventAndBlockHashAs(key)
            }
            if (canRetain) {
                values += retainedEntry
            }
            while (values.size > maxEntries) {
                values.removeAt(0)
            }
            RegistryCachePutResult(
                retainedValue = retainedEntry.value.takeIf { canRetain },
                unverifiedConflict = unverifiedConflict,
                verifiedConflict = verifiedConflict,
            )
        }

    internal suspend fun snapshotKeys(): List<RegistryCacheKey> = mutex.withLock {
        values.map { it.value.cacheKey }
    }

    private fun findAndTouch(predicate: (RegistryResolvedValue) -> Boolean): RegistryResolvedValue? {
        val index = values.indexOfFirst { predicate(it.value) }
        if (index < 0) return null
        val entry = values.removeAt(index)
        values += entry
        return entry.value
    }

    private fun RegistryCacheKey.isSameEventAndBlockHashAs(other: RegistryCacheKey): Boolean =
        chainId == other.chainId &&
            registryAddressHex == other.registryAddressHex &&
            eventIdHex == other.eventIdHex &&
            blockHashHex == other.blockHashHex

    private data class CacheEntry(
        val pinKind: RegistryReadPinKind,
        val value: RegistryResolvedValue,
    )

    private companion object {
        const val DEFAULT_MAX_ENTRIES: Int = 16
    }
}

internal class RegistryResolver(
    private val chainId: Long,
    readerAddressHex: String,
    private val primary: JsonRpcEthCallAdapter,
    private val secondary: JsonRpcEthCallAdapter,
    private val etherscan: EtherscanRestAdapter?,
    private val cache: InMemoryRegistryCache,
    private val retryDelay: RetryDelay = DefaultRetryDelay,
    private val jitter: JitterSource = DefaultJitterSource,
    private val maxAttempts: Int = 2,
) {
    private val registryAddress: String = validateReaderAddress(readerAddressHex)
    private val stateMutex = Mutex()
    private val quarantined = mutableSetOf<String>()
    private val conflictedBlocks = mutableSetOf<ConflictedBlockKey>()

    internal suspend fun quarantinedEndpointIds(): Set<String> = stateMutex.withLock {
        quarantined.toSet()
    }

    init {
        require(chainId > 0) { "chainId must be positive" }
        require(maxAttempts > 0) { "maxAttempts must be positive" }
    }

    internal suspend fun resolve(eventId: ByteArray, pin: RegistryReadPin): RegistryResolvedValue {
        require(eventId.size == 32) { "eventId must be exactly 32 bytes" }
        val stableEventId = eventId.copyOf()
        stateMutex.lock()
        try {
            return resolveLocked(stableEventId, pin)
        } finally {
            stateMutex.unlock()
        }
    }

    private suspend fun resolveLocked(eventId: ByteArray, pin: RegistryReadPin): RegistryResolvedValue {
        val eventIdHex = eventId.toPrefixedHex()
        if (pin.kind == RegistryReadPinKind.BLOCK_HASH) {
            val blockHashHex = requireNotNull(pin.blockHashHex)
            rejectConflictedBlock(eventIdHex, blockHashHex)
            val cached = cache.findByBlockHash(
                chainId = chainId,
                registryAddressHex = registryAddress,
                eventIdHex = eventIdHex,
                blockHashHex = blockHashHex,
            )
            if (cached != null) {
                val verifier = listOf(primary, secondary).firstOrNull { it.endpointId !in quarantined }
                    ?: throw RegistryGatewayException(
                        RegistryErrorCode.NO_ENDPOINT,
                        retryable = false,
                        message = "no registry RPC can verify the cached strict block",
                    )
                val canonicalBlock = retry {
                    verifier.resolveCanonicalBlockAtNumber(cached.cacheKey.blockNumber)
                }
                if (canonicalBlock.blockHashHex != blockHashHex) {
                    cache.removeByBlockHash(
                        chainId = chainId,
                        registryAddressHex = registryAddress,
                        eventIdHex = eventIdHex,
                        blockHashHex = blockHashHex,
                    )
                    conflictedBlocks += ConflictedBlockKey(eventIdHex, blockHashHex)
                    throw blockConflictFailure()
                }
                return cached
            }
        }

        val resolvedPin = resolveBlockPin(pin)
        rejectConflictedBlock(eventIdHex, resolvedPin.blockHashHex)
        cache.findAtBlock(
            chainId = chainId,
            registryAddressHex = registryAddress,
            eventIdHex = eventIdHex,
            blockNumber = resolvedPin.blockNumber,
            blockHashHex = resolvedPin.blockHashHex,
            requireEip1898 = resolvedPin.strict,
        )?.let { return it }
        val directReads = mutableListOf<GatewayRead>()
        val failures = mutableListOf<RegistryGatewayException>()
        for (adapter in listOf(primary, secondary)) {
            if (adapter.endpointId in quarantined) continue
            try {
                directReads += retry { adapter.read(eventId, resolvedPin) }
            } catch (error: RegistryGatewayException) {
                failures += error
                if (!error.retryable && error.code in QUARANTINE_FAILURES) {
                    quarantined += adapter.endpointId
                }
            }
        }

        val chosen = when {
            directReads.size >= 2 -> compareDirectReads(directReads[0], directReads[1])
            directReads.size == 1 -> directReads.single()
            etherscan != null && !resolvedPin.strict && etherscan.endpointId !in quarantined -> {
                try {
                    retry { etherscan.read(eventId, resolvedPin) }
                } catch (error: RegistryGatewayException) {
                    if (!error.retryable && error.code in QUARANTINE_FAILURES) {
                        quarantined += etherscan.endpointId
                    }
                    throw error
                }
            }
            failures.isNotEmpty() -> throw failures.last()
            else -> throw RegistryGatewayException(
                RegistryErrorCode.NO_ENDPOINT,
                retryable = false,
                message = "no eligible registry endpoint remains",
            )
        }

        val definitionHash = chosen.context.latestDefinitionDigestHex ?: ZERO_DEFINITION_HASH_HEX
        val value = RegistryResolvedValue(
            context = chosen.context,
            cacheKey = RegistryCacheKey(
                chainId = chainId,
                registryAddressHex = registryAddress,
                eventIdHex = eventIdHex,
                definitionHashHex = definitionHash,
                blockNumber = resolvedPin.blockNumber,
                blockHashHex = resolvedPin.blockHashHex,
            ),
            rawCbor = chosen.rawCbor.copyOf(),
            eip1898Verified = chosen.eip1898Verified,
        )
        val cacheResult = cache.put(pin, value)
        if (cacheResult.unverifiedConflict) {
            etherscan?.let { quarantined += it.endpointId }
        }
        val retainedValue = cacheResult.retainedValue
        if (retainedValue == null) {
            conflictedBlocks += ConflictedBlockKey(eventIdHex, resolvedPin.blockHashHex)
            throw blockConflictFailure()
        }
        return retainedValue
    }

    private fun rejectConflictedBlock(eventIdHex: String, blockHashHex: String) {
        if (ConflictedBlockKey(eventIdHex, blockHashHex) in conflictedBlocks) {
            throw blockConflictFailure()
        }
    }

    private fun blockConflictFailure(): RegistryGatewayException =
        RegistryGatewayException(
            RegistryErrorCode.RESULT_MISMATCH,
            retryable = false,
            message = "registry cache observed conflicting metadata for the same block hash",
        )

    private suspend fun resolveBlockPin(pin: RegistryReadPin): ResolvedBlockPin {
        var primaryFailure: RegistryGatewayException? = null
        if (primary.endpointId !in quarantined) {
            try {
                return retry { primary.resolvePin(pin) }
            } catch (error: RegistryGatewayException) {
                primaryFailure = error
                if (!error.retryable && error.code in QUARANTINE_FAILURES) {
                    quarantined += primary.endpointId
                }
            }
        }
        if (secondary.endpointId !in quarantined) {
            try {
                return retry { secondary.resolvePin(pin) }
            } catch (error: RegistryGatewayException) {
                if (!error.retryable && error.code in QUARANTINE_FAILURES) {
                    quarantined += secondary.endpointId
                }
                throw error
            }
        }
        throw primaryFailure ?: RegistryGatewayException(
            RegistryErrorCode.NO_ENDPOINT,
            retryable = false,
            message = "no registry RPC can resolve the requested block pin",
        )
    }

    private fun compareDirectReads(first: GatewayRead, second: GatewayRead): GatewayRead {
        if (first.rawCbor.contentEquals(second.rawCbor)) return first
        quarantined += first.endpointId
        quarantined += second.endpointId
        throw RegistryGatewayException(
            RegistryErrorCode.RESULT_MISMATCH,
            retryable = false,
            message = "registry endpoints returned different results at the same block hash",
        )
    }

    private suspend fun <T> retry(operation: suspend () -> T): T {
        var attempt = 1
        while (true) {
            try {
                return operation()
            } catch (error: RegistryGatewayException) {
                if (!error.retryable || attempt >= maxAttempts) throw error
                retryDelay.wait(jitter.delayMillis(attempt))
                attempt += 1
            }
        }
    }

    private companion object {
        val QUARANTINE_FAILURES: Set<RegistryErrorCode> = setOf(
            RegistryErrorCode.PROTOCOL_ERROR,
            RegistryErrorCode.DECODING_ERROR,
            RegistryErrorCode.RESULT_MISMATCH,
        )
    }
}

private data class ConflictedBlockKey(
    val eventIdHex: String,
    val blockHashHex: String,
)

private object DefaultRetryDelay : RetryDelay {
    override suspend fun wait(delayMillis: Long) {
        delay(delayMillis)
    }
}

private object DefaultJitterSource : JitterSource {
    override fun delayMillis(attempt: Int): Long {
        val base = 150L * attempt
        return base + Random.Default.nextLong(0, 201)
    }
}

private const val ZERO_DEFINITION_HASH_HEX: String =
    "0x0000000000000000000000000000000000000000000000000000000000000000"
