package org.levarac.parallax.registry

import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.yield
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

class RegistryResolverTest {
    @Test
    fun retriesOnlyTimeoutRateLimitAndServerResponses() = runTest {
        val retryableCases = listOf(
            "timeout" to TransportOutcome.Fail(RegistryTransportTimeoutException()),
            "HTTP 429" to TransportOutcome.Respond(RegistryHttpResponse(429, "rate limited")),
            "HTTP 500" to TransportOutcome.Respond(RegistryHttpResponse(500, "server failed")),
        )

        for ((label, firstRead) in retryableCases) {
            val primaryTransport = RecordingRegistryTransport(
                listOf(
                    TransportOutcome.Respond(RegistryTestFixtures.headerResponse()),
                    firstRead,
                    TransportOutcome.Respond(RegistryTestFixtures.callResponse()),
                ),
            )
            val secondaryTransport = RecordingRegistryTransport(RegistryTestFixtures.callResponse())
            val retryDelay = RecordingRetryDelay()
            val jitter = RecordingJitter(37)
            val resolver = resolver(primaryTransport, secondaryTransport, retryDelay, jitter = jitter)

            val resolved = resolver.resolve(RegistryTestFixtures.eventId, safeRegistryReadPin())

            assertContentEquals(RegistryTestFixtures.cbor(), resolved.rawCbor, label)
            assertEquals(3, primaryTransport.requests.size, label)
            assertEquals(1, secondaryTransport.requests.size, label)
            assertEquals(listOf(37L), retryDelay.delays, label)
            assertEquals(listOf(1), jitter.attempts, label)
        }
    }

    @Test
    fun doesNotRetryUnknownTransport400RevertAbiOrCborFailures() = runTest {
        val nonRetryableCases = listOf(
            "unknown transport failure" to TransportOutcome.Fail(IllegalStateException("connection failed")),
            "HTTP 400" to TransportOutcome.Respond(RegistryHttpResponse(400, "bad request")),
            "contract revert" to TransportOutcome.Respond(
                RegistryHttpResponse(
                    200,
                    """{"jsonrpc":"2.0","id":2,"error":{"code":3,"message":"execution reverted"}}""",
                ),
            ),
            "invalid ABI" to TransportOutcome.Respond(
                RegistryHttpResponse(200, """{"jsonrpc":"2.0","id":2,"result":"0x1234"}"""),
            ),
            "invalid CBOR" to TransportOutcome.Respond(
                RegistryTestFixtures.callResponse(byteArrayOf(0)),
            ),
        )

        for ((label, firstRead) in nonRetryableCases) {
            val primaryTransport = RecordingRegistryTransport(
                listOf(
                    TransportOutcome.Respond(RegistryTestFixtures.headerResponse()),
                    firstRead,
                    TransportOutcome.Respond(RegistryTestFixtures.callResponse()),
                ),
            )
            val secondaryTransport = RecordingRegistryTransport(RegistryTestFixtures.callResponse())
            val retryDelay = RecordingRetryDelay()
            val jitter = RecordingJitter(91)
            val resolver = resolver(primaryTransport, secondaryTransport, retryDelay, jitter = jitter)

            val resolved = resolver.resolve(RegistryTestFixtures.eventId, safeRegistryReadPin())

            assertContentEquals(RegistryTestFixtures.cbor(), resolved.rawCbor, label)
            assertEquals(2, primaryTransport.requests.size, label)
            assertEquals(1, secondaryTransport.requests.size, label)
            assertTrue(retryDelay.delays.isEmpty(), label)
            assertTrue(jitter.attempts.isEmpty(), label)
        }
    }

    @Test
    fun etherscanFallbackRetriesTimeoutRateLimitAndServerResponses() = runTest {
        val retryableCases = listOf(
            "timeout" to TransportOutcome.Fail(RegistryTransportTimeoutException()),
            "HTTP 429" to TransportOutcome.Respond(RegistryHttpResponse(429, "rate limited")),
            "HTTP 500" to TransportOutcome.Respond(RegistryHttpResponse(500, "server failed")),
        )

        for ((label, firstRead) in retryableCases) {
            val primaryTransport = RecordingRegistryTransport(
                RegistryTestFixtures.headerResponse(),
                RegistryHttpResponse(400, "direct unavailable"),
            )
            val secondaryTransport = RecordingRegistryTransport(
                RegistryHttpResponse(400, "direct unavailable"),
            )
            val etherscanTransport = RecordingRegistryTransport(
                listOf(
                    firstRead,
                    TransportOutcome.Respond(RegistryTestFixtures.etherscanResponse()),
                    TransportOutcome.Respond(RegistryTestFixtures.headerResponse()),
                ),
            )
            val retryDelay = RecordingRetryDelay()
            val jitter = RecordingJitter(43)
            val resolver = resolver(
                primaryTransport,
                secondaryTransport,
                retryDelay,
                jitter = jitter,
                etherscanTransport = etherscanTransport,
            )

            val resolved = resolver.resolve(RegistryTestFixtures.eventId, safeRegistryReadPin())

            assertContentEquals(RegistryTestFixtures.cbor(), resolved.rawCbor, label)
            assertEquals(3, etherscanTransport.requests.size, label)
            assertEquals(listOf(43L), retryDelay.delays, label)
            assertEquals(listOf(1), jitter.attempts, label)
        }
    }

    @Test
    fun etherscanFallbackDoesNotRetryUnknownTransport400RevertAbiOrCborFailures() = runTest {
        val nonRetryableCases = listOf(
            EtherscanFailureCase(
                "unknown transport failure",
                RegistryErrorCode.HTTP_ERROR,
                TransportOutcome.Fail(IllegalStateException("connection failed")),
            ),
            EtherscanFailureCase(
                "HTTP 400",
                RegistryErrorCode.HTTP_ERROR,
                TransportOutcome.Respond(RegistryHttpResponse(400, "bad request")),
            ),
            EtherscanFailureCase(
                "contract revert",
                RegistryErrorCode.CONTRACT_ERROR,
                TransportOutcome.Respond(
                    RegistryHttpResponse(
                        200,
                        """{"jsonrpc":"2.0","id":1,"error":{"code":3,"message":"execution reverted"}}""",
                    ),
                ),
            ),
            EtherscanFailureCase(
                "invalid ABI",
                RegistryErrorCode.DECODING_ERROR,
                TransportOutcome.Respond(
                    RegistryHttpResponse(200, """{"jsonrpc":"2.0","id":1,"result":"0x1234"}"""),
                ),
            ),
            EtherscanFailureCase(
                "invalid CBOR",
                RegistryErrorCode.DECODING_ERROR,
                TransportOutcome.Respond(RegistryTestFixtures.etherscanResponse(byteArrayOf(0))),
            ),
        )

        for ((label, expectedCode, firstRead) in nonRetryableCases) {
            val primaryTransport = RecordingRegistryTransport(
                RegistryTestFixtures.headerResponse(),
                RegistryHttpResponse(400, "direct unavailable"),
            )
            val secondaryTransport = RecordingRegistryTransport(
                RegistryHttpResponse(400, "direct unavailable"),
            )
            val etherscanTransport = RecordingRegistryTransport(
                listOf(
                    firstRead,
                    TransportOutcome.Respond(RegistryTestFixtures.etherscanResponse()),
                ),
            )
            val retryDelay = RecordingRetryDelay()
            val jitter = RecordingJitter(97)
            val resolver = resolver(
                primaryTransport,
                secondaryTransport,
                retryDelay,
                jitter = jitter,
                etherscanTransport = etherscanTransport,
            )

            val failure = gatewayFailure {
                resolver.resolve(RegistryTestFixtures.eventId, safeRegistryReadPin())
            }

            assertEquals(expectedCode, failure.code, label)
            assertEquals(1, etherscanTransport.requests.size, label)
            assertTrue(retryDelay.delays.isEmpty(), label)
            assertTrue(jitter.attempts.isEmpty(), label)
        }
    }

    @Test
    fun strictReadsNeverFallBackToEtherscan() = runTest {
        val primaryTransport = RecordingRegistryTransport(
            RegistryTestFixtures.headerResponse(),
            RegistryHttpResponse(500, "server failed"),
            RegistryHttpResponse(500, "server failed again"),
        )
        val secondaryTransport = RecordingRegistryTransport(
            RegistryHttpResponse(500, "server failed"),
            RegistryHttpResponse(500, "server failed again"),
        )
        val etherscanTransport = RecordingRegistryTransport(RegistryTestFixtures.etherscanResponse())
        val retryDelay = RecordingRetryDelay()
        val resolver = resolver(
            primaryTransport,
            secondaryTransport,
            retryDelay,
            etherscanTransport = etherscanTransport,
        )

        val failure = gatewayFailure {
            resolver.resolve(
                RegistryTestFixtures.eventId,
                requireNotNull(strictRegistryReadPin(RegistryTestFixtures.BLOCK_HASH)),
            )
        }

        assertEquals(RegistryErrorCode.SERVER_ERROR, failure.code)
        assertEquals(3, primaryTransport.requests.size)
        assertEquals(2, secondaryTransport.requests.size)
        assertEquals(2, retryDelay.delays.size)
        assertTrue(etherscanTransport.requests.isEmpty())
    }

    @Test
    fun differingDirectResultsAreRejectedAndBothEndpointsStayQuarantined() = runTest {
        val primaryTransport = RecordingRegistryTransport(
            RegistryTestFixtures.headerResponse(),
            RegistryTestFixtures.callResponse(),
        )
        val secondaryTransport = RecordingRegistryTransport(
            RegistryTestFixtures.callResponse(RegistryTestFixtures.cbor(definitionByte = 0x55)),
        )
        val resolver = resolver(primaryTransport, secondaryTransport, RecordingRetryDelay())

        val mismatch = gatewayFailure {
            resolver.resolve(RegistryTestFixtures.eventId, safeRegistryReadPin())
        }

        assertEquals(RegistryErrorCode.RESULT_MISMATCH, mismatch.code)
        assertEquals(
            setOf(RegistryTestFixtures.ENDPOINT, RegistryTestFixtures.SECONDARY_ENDPOINT),
            resolver.quarantinedEndpointIds(),
        )
        val primaryRequestCount = primaryTransport.requests.size
        val secondaryRequestCount = secondaryTransport.requests.size

        val quarantined = gatewayFailure {
            resolver.resolve(RegistryTestFixtures.eventId, safeRegistryReadPin())
        }

        assertEquals(RegistryErrorCode.NO_ENDPOINT, quarantined.code)
        assertEquals(primaryRequestCount, primaryTransport.requests.size)
        assertEquals(secondaryRequestCount, secondaryTransport.requests.size)
    }

    @Test
    fun identicalDirectResultsAreAcceptedAndMovingPinReusesThePinnedResult() = runTest {
        val primaryTransport = RecordingRegistryTransport(
            RegistryTestFixtures.headerResponse(),
            RegistryTestFixtures.callResponse(),
            RegistryTestFixtures.headerResponse(),
        )
        val secondaryTransport = RecordingRegistryTransport(RegistryTestFixtures.callResponse())
        val cache = InMemoryRegistryCache()
        val resolver = resolver(
            primaryTransport,
            secondaryTransport,
            RecordingRetryDelay(),
            cache = cache,
        )

        val first = resolver.resolve(RegistryTestFixtures.eventId, safeRegistryReadPin())
        val firstPrimaryCount = primaryTransport.requests.size
        val firstSecondaryCount = secondaryTransport.requests.size
        val second = resolver.resolve(RegistryTestFixtures.eventId.copyOf(), safeRegistryReadPin())

        assertContentEquals(first.rawCbor, second.rawCbor)
        assertTrue(resolver.quarantinedEndpointIds().isEmpty())
        assertEquals(firstPrimaryCount + 1, primaryTransport.requests.size)
        assertEquals(firstSecondaryCount, secondaryTransport.requests.size)

        val key = cache.snapshotKeys().single()
        assertEquals(CHAIN_ID, key.chainId)
        assertEquals(RegistryTestFixtures.READER, key.registryAddressHex)
        assertEquals(RegistryTestFixtures.eventId.toPrefixedHex(), key.eventIdHex)
        assertEquals(RegistryTestFixtures.LATEST_DIGEST, key.definitionHashHex)
        assertEquals(0x1234L, key.blockNumber)
        assertEquals(RegistryTestFixtures.BLOCK_HASH, key.blockHashHex)
    }

    @Test
    fun strictBlockHashResolveIsCacheOnlyAfterTheFirstPinnedRead() = runTest {
        val primaryTransport = RecordingRegistryTransport(
            RegistryTestFixtures.headerResponse(),
            RegistryTestFixtures.callResponse(),
        )
        val secondaryTransport = RecordingRegistryTransport(RegistryTestFixtures.callResponse())
        val resolver = resolver(primaryTransport, secondaryTransport, RecordingRetryDelay())
        val strictPin = requireNotNull(strictRegistryReadPin(RegistryTestFixtures.BLOCK_HASH))

        val first = resolver.resolve(RegistryTestFixtures.eventId, strictPin)
        val firstPrimaryCount = primaryTransport.requests.size
        val firstSecondaryCount = secondaryTransport.requests.size
        val second = resolver.resolve(RegistryTestFixtures.eventId.copyOf(), strictPin)

        assertContentEquals(first.rawCbor, second.rawCbor)
        assertEquals(firstPrimaryCount, primaryTransport.requests.size)
        assertEquals(firstSecondaryCount, secondaryTransport.requests.size)
    }

    @Test
    fun strictReadReusesASafeDirectEip1898ResultFromTheCache() = runTest {
        val primaryTransport = RecordingRegistryTransport(
            RegistryTestFixtures.headerResponse(),
            RegistryTestFixtures.callResponse(),
        )
        val secondaryTransport = RecordingRegistryTransport(RegistryTestFixtures.callResponse())
        val resolver = resolver(primaryTransport, secondaryTransport, RecordingRetryDelay())

        val safe = resolver.resolve(RegistryTestFixtures.eventId, safeRegistryReadPin())
        val strict = resolver.resolve(
            RegistryTestFixtures.eventId,
            requireNotNull(strictRegistryReadPin(safe.cacheKey.blockHashHex)),
        )

        assertContentEquals(safe.rawCbor, strict.rawCbor)
        assertEquals(2, primaryTransport.requests.size)
        assertEquals(1, secondaryTransport.requests.size)
    }

    @Test
    fun strictReadNeverReusesANumberPinnedEtherscanFallbackFromTheCache() = runTest {
        val primaryTransport = RecordingRegistryTransport(
            RegistryTestFixtures.headerResponse(),
            RegistryHttpResponse(400, "direct unavailable"),
            RegistryTestFixtures.headerResponse(),
            RegistryTestFixtures.callResponse(),
        )
        val secondaryTransport = RecordingRegistryTransport(
            RegistryHttpResponse(400, "direct unavailable"),
            RegistryTestFixtures.callResponse(),
        )
        val etherscanTransport = RecordingRegistryTransport(
            RegistryTestFixtures.etherscanResponse(),
            RegistryTestFixtures.headerResponse(),
        )
        val cache = InMemoryRegistryCache()
        val resolver = resolver(
            primaryTransport,
            secondaryTransport,
            RecordingRetryDelay(),
            etherscanTransport = etherscanTransport,
            cache = cache,
        )

        val safe = resolver.resolve(RegistryTestFixtures.eventId, safeRegistryReadPin())
        val strict = resolver.resolve(
            RegistryTestFixtures.eventId,
            requireNotNull(strictRegistryReadPin(safe.cacheKey.blockHashHex)),
        )

        assertContentEquals(safe.rawCbor, strict.rawCbor)
        assertEquals(4, primaryTransport.requests.size)
        assertEquals(2, secondaryTransport.requests.size)
        assertEquals(2, etherscanTransport.requests.size)
        assertTrue(primaryTransport.requests[2].body!!.contains("\"method\":\"eth_getBlockByHash\""))
        assertTrue(primaryTransport.requests[3].body!!.contains("\"requireCanonical\":true"))
        assertTrue(resolver.quarantinedEndpointIds().isEmpty())
        val cachedStrict = requireNotNull(
            cache.findByBlockHash(
                chainId = CHAIN_ID,
                registryAddressHex = RegistryTestFixtures.READER,
                eventIdHex = RegistryTestFixtures.eventId.toPrefixedHex(),
                blockHashHex = safe.cacheKey.blockHashHex,
            ),
        )
        assertTrue(cachedStrict.eip1898Verified)
        assertEquals(1, cache.snapshotKeys().size)
    }

    @Test
    fun verifiedDirectReadReplacesAConflictingEtherscanValueAtTheSameBlock() = runTest {
        val etherscanCbor = RegistryTestFixtures.cbor(definitionByte = 0x44)
        val directCbor = RegistryTestFixtures.cbor(definitionByte = 0x55)
        val primaryTransport = RecordingRegistryTransport(
            RegistryTestFixtures.headerResponse(),
            RegistryHttpResponse(400, "direct unavailable"),
            RegistryTestFixtures.headerResponse(),
            RegistryTestFixtures.callResponse(directCbor),
            RegistryTestFixtures.headerResponse(),
        )
        val secondaryTransport = RecordingRegistryTransport(
            RegistryHttpResponse(400, "direct unavailable"),
            RegistryTestFixtures.callResponse(directCbor),
        )
        val etherscanTransport = RecordingRegistryTransport(
            RegistryTestFixtures.etherscanResponse(etherscanCbor),
            RegistryTestFixtures.headerResponse(),
        )
        val cache = InMemoryRegistryCache()
        val resolver = resolver(
            primaryTransport,
            secondaryTransport,
            RecordingRetryDelay(),
            etherscanTransport = etherscanTransport,
            cache = cache,
        )

        val fallback = resolver.resolve(RegistryTestFixtures.eventId, safeRegistryReadPin())
        val strict = resolver.resolve(
            RegistryTestFixtures.eventId,
            requireNotNull(strictRegistryReadPin(fallback.cacheKey.blockHashHex)),
        )
        val safeAfterStrict = resolver.resolve(RegistryTestFixtures.eventId, safeRegistryReadPin())

        assertEquals(RegistryTestFixtures.LATEST_DIGEST, fallback.context.latestDefinitionDigestHex)
        assertEquals("0x${"55".repeat(32)}", strict.context.latestDefinitionDigestHex)
        assertContentEquals(directCbor, safeAfterStrict.rawCbor)
        val keys = cache.snapshotKeys()
        assertEquals(1, keys.size)
        assertEquals("0x${"55".repeat(32)}", keys.single().definitionHashHex)
        assertEquals(setOf("etherscan-v2"), resolver.quarantinedEndpointIds())
        assertEquals(5, primaryTransport.requests.size)
        assertEquals(2, secondaryTransport.requests.size)
        assertEquals(2, etherscanTransport.requests.size)
    }

    @Test
    fun verifiedDirectReadQuarantinesEtherscanWhenTheSameHashHasDifferentNumberMetadata() = runTest {
        val primaryTransport = RecordingRegistryTransport(
            RegistryTestFixtures.headerResponse(),
            RegistryHttpResponse(400, "direct unavailable"),
            RegistryTestFixtures.headerResponse(blockNumberHex = "0x1235"),
            RegistryTestFixtures.callResponse(),
        )
        val secondaryTransport = RecordingRegistryTransport(
            RegistryHttpResponse(400, "direct unavailable"),
            RegistryTestFixtures.callResponse(),
        )
        val etherscanTransport = RecordingRegistryTransport(
            RegistryTestFixtures.etherscanResponse(),
            RegistryTestFixtures.headerResponse(),
        )
        val cache = InMemoryRegistryCache()
        val resolver = resolver(
            primaryTransport,
            secondaryTransport,
            RecordingRetryDelay(),
            etherscanTransport = etherscanTransport,
            cache = cache,
        )

        val fallback = resolver.resolve(RegistryTestFixtures.eventId, safeRegistryReadPin())
        val strict = resolver.resolve(
            RegistryTestFixtures.eventId,
            requireNotNull(strictRegistryReadPin(fallback.cacheKey.blockHashHex)),
        )

        assertContentEquals(fallback.rawCbor, strict.rawCbor)
        assertTrue(strict.eip1898Verified)
        assertEquals(0x1235L, strict.cacheKey.blockNumber)
        assertEquals(setOf("etherscan-v2"), resolver.quarantinedEndpointIds())
        assertEquals(0x1235L, cache.snapshotKeys().single().blockNumber)
        assertEquals(4, primaryTransport.requests.size)
        assertEquals(2, secondaryTransport.requests.size)
        assertEquals(2, etherscanTransport.requests.size)
    }

    @Test
    fun conflictingVerifiedNumberMetadataForTheSameHashFailsClosed() = runTest {
        val primaryTransport = RecordingRegistryTransport(
            RegistryTestFixtures.headerResponse(),
            RegistryTestFixtures.callResponse(),
            RegistryTestFixtures.headerResponse(blockNumberHex = "0x1235"),
            RegistryTestFixtures.callResponse(),
        )
        val secondaryTransport = RecordingRegistryTransport(
            RegistryTestFixtures.callResponse(),
            RegistryTestFixtures.callResponse(),
        )
        val cache = InMemoryRegistryCache()
        val resolver = resolver(
            primaryTransport,
            secondaryTransport,
            RecordingRetryDelay(),
            cache = cache,
        )
        resolver.resolve(
            RegistryTestFixtures.eventId,
            requireNotNull(strictRegistryReadPin(RegistryTestFixtures.BLOCK_HASH)),
        )

        val failure = gatewayFailure {
            resolver.resolve(RegistryTestFixtures.eventId, safeRegistryReadPin())
        }

        assertEquals(RegistryErrorCode.RESULT_MISMATCH, failure.code)
        val primaryRequestCount = primaryTransport.requests.size
        val secondaryRequestCount = secondaryTransport.requests.size
        val repeatedStrictFailure = gatewayFailure {
            resolver.resolve(
                RegistryTestFixtures.eventId,
                requireNotNull(strictRegistryReadPin(RegistryTestFixtures.BLOCK_HASH)),
            )
        }
        assertEquals(RegistryErrorCode.RESULT_MISMATCH, repeatedStrictFailure.code)
        assertEquals(primaryRequestCount, primaryTransport.requests.size)
        assertEquals(secondaryRequestCount, secondaryTransport.requests.size)
        assertTrue(resolver.quarantinedEndpointIds().isEmpty())
        assertTrue(cache.snapshotKeys().isEmpty())
        assertEquals(4, primaryTransport.requests.size)
        assertEquals(2, secondaryTransport.requests.size)
    }

    @Test
    fun movingSafePinObservesANewBlockAndDoesNotReturnTheOldCachedDefinition() = runTest {
        val newerCbor = RegistryTestFixtures.cbor(definitionByte = 0x55)
        val primaryTransport = RecordingRegistryTransport(
            RegistryTestFixtures.headerResponse(),
            RegistryTestFixtures.callResponse(),
            RegistryTestFixtures.headerResponse(
                blockHash = RegistryTestFixtures.OTHER_BLOCK_HASH,
                blockNumberHex = "0x1235",
            ),
            RegistryTestFixtures.callResponse(newerCbor),
        )
        val secondaryTransport = RecordingRegistryTransport(
            RegistryTestFixtures.callResponse(),
            RegistryTestFixtures.callResponse(newerCbor),
        )
        val resolver = resolver(primaryTransport, secondaryTransport, RecordingRetryDelay())

        val first = resolver.resolve(RegistryTestFixtures.eventId, safeRegistryReadPin())
        val second = resolver.resolve(RegistryTestFixtures.eventId, safeRegistryReadPin())

        assertEquals(RegistryTestFixtures.LATEST_DIGEST, first.context.latestDefinitionDigestHex)
        assertEquals("0x${"55".repeat(32)}", second.context.latestDefinitionDigestHex)
        assertEquals(RegistryTestFixtures.OTHER_BLOCK_HASH, second.cacheKey.blockHashHex)
        assertEquals(0x1235L, second.cacheKey.blockNumber)
        assertEquals(4, primaryTransport.requests.size)
        assertEquals(2, secondaryTransport.requests.size)
    }

    @Test
    fun malformedPrimaryHeaderIsQuarantinedAndSecondaryHeaderIsUsed() = runTest {
        val malformedHeader = RegistryHttpResponse(
            200,
            """{"jsonrpc":"2.0","id":1,"result":{"number":[],"hash":"${RegistryTestFixtures.BLOCK_HASH}"}}""",
        )
        val primaryTransport = RecordingRegistryTransport(malformedHeader)
        val secondaryTransport = RecordingRegistryTransport(
            RegistryTestFixtures.headerResponse(),
            RegistryTestFixtures.callResponse(),
        )
        val resolver = resolver(primaryTransport, secondaryTransport, RecordingRetryDelay())

        val resolved = resolver.resolve(RegistryTestFixtures.eventId, safeRegistryReadPin())

        assertContentEquals(RegistryTestFixtures.cbor(), resolved.rawCbor)
        assertEquals(setOf(RegistryTestFixtures.ENDPOINT), resolver.quarantinedEndpointIds())
        assertEquals(1, primaryTransport.requests.size)
        assertEquals(2, secondaryTransport.requests.size)
    }

    @Test
    fun concurrentResolvesSerializeSharedStateAndReuseTheSamePinnedResult() = runTest {
        val primaryTransport = YieldingRegistryTransport(
            RegistryTestFixtures.headerResponse(),
            RegistryTestFixtures.callResponse(),
            RegistryTestFixtures.headerResponse(),
        )
        val secondaryTransport = YieldingRegistryTransport(RegistryTestFixtures.callResponse())
        val resolver = resolver(primaryTransport, secondaryTransport, RecordingRetryDelay())

        val results = listOf(
            async { resolver.resolve(RegistryTestFixtures.eventId, safeRegistryReadPin()) },
            async { resolver.resolve(RegistryTestFixtures.eventId.copyOf(), safeRegistryReadPin()) },
        ).awaitAll()

        assertContentEquals(results[0].rawCbor, results[1].rawCbor)
        assertEquals(3, primaryTransport.requests.size)
        assertEquals(1, secondaryTransport.requests.size)
        assertTrue(resolver.quarantinedEndpointIds().isEmpty())
    }

    @Test
    fun cacheReplacesMovingEntriesAndEvictsTheLeastRecentlyUsedEntryAtItsBound() = runTest {
        val cache = InMemoryRegistryCache(maxEntries = 2)
        val firstSafe = cachedValue(eventByte = 0x01, blockNumber = 1, blockByte = 0x21)
        val newerSafe = cachedValue(eventByte = 0x01, blockNumber = 2, blockByte = 0x22)
        cache.put(safeRegistryReadPin(), firstSafe)
        cache.put(safeRegistryReadPin(), newerSafe)

        assertEquals(listOf(newerSafe.cacheKey.blockHashHex), cache.snapshotKeys().map { it.blockHashHex })

        val strictA = cachedValue(eventByte = 0x02, blockNumber = 3, blockByte = 0x23)
        cache.put(requireNotNull(strictRegistryReadPin(strictA.cacheKey.blockHashHex)), strictA)
        cache.findAtBlock(
            chainId = CHAIN_ID,
            registryAddressHex = RegistryTestFixtures.READER,
            eventIdHex = newerSafe.cacheKey.eventIdHex,
            blockNumber = newerSafe.cacheKey.blockNumber,
            blockHashHex = newerSafe.cacheKey.blockHashHex,
        )
        val strictB = cachedValue(eventByte = 0x03, blockNumber = 4, blockByte = 0x24)
        cache.put(requireNotNull(strictRegistryReadPin(strictB.cacheKey.blockHashHex)), strictB)

        val retainedHashes = cache.snapshotKeys().map { it.blockHashHex }.toSet()
        assertEquals(2, retainedHashes.size)
        assertTrue(newerSafe.cacheKey.blockHashHex in retainedHashes)
        assertTrue(strictB.cacheKey.blockHashHex in retainedHashes)
        assertTrue(strictA.cacheKey.blockHashHex !in retainedHashes)
    }

    @Test
    fun cacheNeverDowngradesAVerifiedBlockToAConflictingUnverifiedValue() = runTest {
        val cache = InMemoryRegistryCache()
        val verified = cachedValue(
            eventByte = 0x01,
            blockNumber = 1,
            blockByte = 0x21,
            definitionByte = 0x55,
            eip1898Verified = true,
        )
        val unverified = cachedValue(
            eventByte = 0x01,
            blockNumber = 1,
            blockByte = 0x21,
            definitionByte = 0x44,
            eip1898Verified = false,
        )
        cache.put(requireNotNull(strictRegistryReadPin(verified.cacheKey.blockHashHex)), verified)

        val result = cache.put(safeRegistryReadPin(), unverified)

        assertTrue(result.unverifiedConflict)
        val retainedValue = requireNotNull(result.retainedValue)
        assertContentEquals(verified.rawCbor, retainedValue.rawCbor)
        assertTrue(retainedValue.eip1898Verified)
        val retained = cache.snapshotKeys().single()
        assertEquals(verified.cacheKey.definitionHashHex, retained.definitionHashHex)
    }

    @Test
    fun cacheUsesBlockHashIdentityWhenProviderNumberMetadataConflicts() = runTest {
        val cache = InMemoryRegistryCache()
        val first = cachedValue(eventByte = 0x01, blockNumber = 1, blockByte = 0x21)
        val conflictingNumber = cachedValue(eventByte = 0x01, blockNumber = 2, blockByte = 0x21)
        val strictPin = requireNotNull(strictRegistryReadPin(first.cacheKey.blockHashHex))
        cache.put(strictPin, first)

        val result = cache.put(strictPin, conflictingNumber)

        assertTrue(result.verifiedConflict)
        assertNull(result.retainedValue)
        assertTrue(cache.snapshotKeys().isEmpty())
    }

    private fun resolver(
        primaryTransport: RegistryHttpTransport,
        secondaryTransport: RegistryHttpTransport,
        retryDelay: RetryDelay,
        jitter: JitterSource = RecordingJitter(0),
        etherscanTransport: RegistryHttpTransport? = null,
        cache: InMemoryRegistryCache = InMemoryRegistryCache(),
    ): RegistryResolver = RegistryResolver(
        chainId = CHAIN_ID,
        readerAddressHex = RegistryTestFixtures.READER,
        primary = JsonRpcEthCallAdapter(
            RegistryTestFixtures.ENDPOINT,
            RegistryTestFixtures.READER,
            primaryTransport,
        ),
        secondary = JsonRpcEthCallAdapter(
            RegistryTestFixtures.SECONDARY_ENDPOINT,
            RegistryTestFixtures.READER,
            secondaryTransport,
        ),
        etherscan = etherscanTransport?.let {
            EtherscanRestAdapter(
                chainId = CHAIN_ID,
                readerAddressHex = RegistryTestFixtures.READER,
                apiKey = "public-api-key",
                transport = it,
            )
        },
        cache = cache,
        retryDelay = retryDelay,
        jitter = jitter,
        maxAttempts = 2,
    )

    private companion object {
        const val CHAIN_ID: Long = 11_155_111L
    }
}

private class RecordingRetryDelay : RetryDelay {
    val delays: MutableList<Long> = mutableListOf()

    override suspend fun wait(delayMillis: Long) {
        delays += delayMillis
    }
}

private class RecordingJitter(
    private val value: Long,
) : JitterSource {
    val attempts: MutableList<Int> = mutableListOf()

    override fun delayMillis(attempt: Int): Long {
        attempts += attempt
        return value
    }
}

private data class EtherscanFailureCase(
    val label: String,
    val expectedCode: RegistryErrorCode,
    val outcome: TransportOutcome,
)

private fun cachedValue(
    eventByte: Int,
    blockNumber: Long,
    blockByte: Int,
    definitionByte: Int = 0x44,
    eip1898Verified: Boolean = true,
): RegistryResolvedValue {
    val cbor = RegistryTestFixtures.cbor(definitionByte = definitionByte)
    val context = RegistryCborCodec.decode(cbor)
    val eventIdHex = "0x" + eventByte.toString(16).padStart(2, '0').repeat(32)
    val blockHashHex = "0x" + blockByte.toString(16).padStart(2, '0').repeat(32)
    return RegistryResolvedValue(
        context = context,
        cacheKey = RegistryCacheKey(
            chainId = 11_155_111,
            registryAddressHex = RegistryTestFixtures.READER,
            eventIdHex = eventIdHex,
            definitionHashHex = requireNotNull(context.latestDefinitionDigestHex),
            blockNumber = blockNumber,
            blockHashHex = blockHashHex,
        ),
        rawCbor = cbor,
        eip1898Verified = eip1898Verified,
    )
}

private class YieldingRegistryTransport(
    vararg responses: RegistryHttpResponse,
) : RegistryHttpTransport {
    val requests: MutableList<RegistryHttpRequest> = mutableListOf()
    private val remaining: ArrayDeque<RegistryHttpResponse> = ArrayDeque(responses.toList())

    override suspend fun execute(request: RegistryHttpRequest): RegistryHttpResponse {
        requests += request
        yield()
        return remaining.removeFirstOrNull()
            ?: error("unexpected registry HTTP request: ${request.method} ${request.url}")
    }
}
