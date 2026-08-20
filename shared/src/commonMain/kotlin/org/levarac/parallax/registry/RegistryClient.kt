package org.levarac.parallax.registry

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

public class RegistryResolution internal constructor(
    public val isSuccess: Boolean,
    public val context: RegistryEventContext?,
    public val blockNumber: Long,
    public val blockHashHex: String?,
    public val definitionHashHex: String?,
    public val errorCode: String?,
    public val errorMessage: String?,
)

public class EventDefinitionResolution internal constructor(
    public val isSuccess: Boolean,
    public val context: EventDefinitionContext?,
    public val blockNumber: Long,
    public val blockHashHex: String?,
    public val definitionHashHex: String?,
    public val errorCode: String?,
    public val errorMessage: String?,
)

public class RegistryRequest internal constructor(private val job: Job) {
    public fun cancel() {
        job.cancel()
    }
}

public class RegistryClient internal constructor(
    private val resolver: RegistryResolver,
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Default),
    private val definitionFetcher: SignedDefinitionFetcher? = null,
) {
    public fun resolve(
        eventIdHex: String,
        pin: RegistryReadPin,
        completion: (RegistryResolution) -> Unit,
    ): RegistryRequest {
        val job = scope.launch {
            val resolution = try {
                val eventId = eventIdHex.decodeHex(expectedBytes = 32)
                val result = resolver.resolve(eventId, pin)
                RegistryResolution(
                    isSuccess = true,
                    context = result.context,
                    blockNumber = result.cacheKey.blockNumber,
                    blockHashHex = result.cacheKey.blockHashHex,
                    definitionHashHex = result.cacheKey.definitionHashHex,
                    errorCode = null,
                    errorMessage = null,
                )
            } catch (error: CancellationException) {
                RegistryResolution(
                    isSuccess = false,
                    context = null,
                    blockNumber = 0,
                    blockHashHex = null,
                    definitionHashHex = null,
                    errorCode = RegistryErrorCode.CANCELLED.wireName,
                    errorMessage = "registry read was cancelled",
                )
            } catch (error: RegistryGatewayException) {
                RegistryResolution(
                    isSuccess = false,
                    context = null,
                    blockNumber = 0,
                    blockHashHex = null,
                    definitionHashHex = null,
                    errorCode = error.code.wireName,
                    errorMessage = error.message,
                )
            } catch (error: IllegalArgumentException) {
                RegistryResolution(
                    isSuccess = false,
                    context = null,
                    blockNumber = 0,
                    blockHashHex = null,
                    definitionHashHex = null,
                    errorCode = RegistryErrorCode.INVALID_INPUT.wireName,
                    errorMessage = error.message,
                )
            } catch (_: Throwable) {
                RegistryResolution(
                    isSuccess = false,
                    context = null,
                    blockNumber = 0,
                    blockHashHex = null,
                    definitionHashHex = null,
                    errorCode = RegistryErrorCode.PROTOCOL_ERROR.wireName,
                    errorMessage = "registry read failed",
                )
            }
            completion(resolution)
        }
        return RegistryRequest(job)
    }

    /**
     * Reads the pinned registry state, selects its definition at [useTimeEpochSeconds],
     * fetches the signed bytes named by that record, and returns one typed context.
     */
    public fun resolveEventDefinition(
        eventIdHex: String,
        pin: RegistryReadPin,
        useTimeEpochSeconds: Long,
        completion: (EventDefinitionResolution) -> Unit,
    ): RegistryRequest {
        val job = scope.launch {
            val resolution = try {
                val fetcher = definitionFetcher ?: throw DefinitionFetchException(
                    DefinitionFetchError.NOT_CONFIGURED,
                    "signed definition URL template is not configured",
                )
                val eventId = eventIdHex.decodeHex(expectedBytes = 32)
                val result = resolver.resolve(eventId, pin)
                val record = definitionForUseTime(result.context, useTimeEpochSeconds)
                    ?: throw DefinitionFetchException(
                        DefinitionFetchError.VALIDITY_MISMATCH,
                        "no registry definition is valid at the requested time",
                    )
                val context = fetcher.fetch(eventId, record, useTimeEpochSeconds)
                EventDefinitionResolution(
                    isSuccess = true,
                    context = context,
                    blockNumber = result.cacheKey.blockNumber,
                    blockHashHex = result.cacheKey.blockHashHex,
                    definitionHashHex = result.cacheKey.definitionHashHex,
                    errorCode = null,
                    errorMessage = null,
                )
            } catch (error: CancellationException) {
                EventDefinitionResolution(
                    isSuccess = false,
                    context = null,
                    blockNumber = 0,
                    blockHashHex = null,
                    definitionHashHex = null,
                    errorCode = RegistryErrorCode.CANCELLED.wireName,
                    errorMessage = "event definition read was cancelled",
                )
            } catch (error: DefinitionFetchException) {
                EventDefinitionResolution(
                    isSuccess = false,
                    context = null,
                    blockNumber = 0,
                    blockHashHex = null,
                    definitionHashHex = null,
                    errorCode = error.reason.wireName,
                    errorMessage = error.message,
                )
            } catch (error: RegistryGatewayException) {
                EventDefinitionResolution(
                    isSuccess = false,
                    context = null,
                    blockNumber = 0,
                    blockHashHex = null,
                    definitionHashHex = null,
                    errorCode = error.code.wireName,
                    errorMessage = error.message,
                )
            } catch (error: IllegalArgumentException) {
                EventDefinitionResolution(
                    isSuccess = false,
                    context = null,
                    blockNumber = 0,
                    blockHashHex = null,
                    definitionHashHex = null,
                    errorCode = RegistryErrorCode.INVALID_INPUT.wireName,
                    errorMessage = error.message,
                )
            } catch (_: Throwable) {
                EventDefinitionResolution(
                    isSuccess = false,
                    context = null,
                    blockNumber = 0,
                    blockHashHex = null,
                    definitionHashHex = null,
                    errorCode = RegistryErrorCode.PROTOCOL_ERROR.wireName,
                    errorMessage = "event definition read failed",
                )
            }
            completion(resolution)
        }
        return RegistryRequest(job)
    }

    public fun close() {
        scope.cancel()
    }
}

/**
 * Creates the bundled Sepolia reader. A blank address means deployment is not configured yet and
 * deliberately leaves the feature inactive rather than falling back to a zero address.
 */
public fun createSepoliaRegistryClient(
    readerAddressHex: String,
    etherscanApiKey: String?,
    definitionUrlTemplate: String? = null,
): RegistryClient? {
    if (readerAddressHex.isBlank()) return null
    val readerAddress = try {
        validateReaderAddress(readerAddressHex)
    } catch (_: IllegalArgumentException) {
        return null
    }
    val transport = createPlatformRegistryHttpTransport()
    val definitionFetcher = definitionUrlTemplate
        ?.takeIf { it.isNotBlank() }
        ?.let { template ->
            createDefinitionUrlTemplate(template)?.let { validated ->
                SignedDefinitionFetcher(validated, transport)
            }
        }
    val primary = JsonRpcEthCallAdapter(
        endpointUrl = "https://ethereum-sepolia-rpc.publicnode.com",
        readerAddressHex = readerAddress,
        transport = transport,
    )
    val secondary = JsonRpcEthCallAdapter(
        endpointUrl = "https://public.1rpc.io/sepolia",
        readerAddressHex = readerAddress,
        transport = transport,
    )
    val etherscan = etherscanApiKey
        ?.takeIf { it.isNotBlank() }
        ?.let { key ->
            EtherscanRestAdapter(
                chainId = SEPOLIA_CHAIN_ID,
                readerAddressHex = readerAddress,
                apiKey = key,
                transport = transport,
            )
        }
    return RegistryClient(
        RegistryResolver(
            chainId = SEPOLIA_CHAIN_ID,
            readerAddressHex = readerAddress,
            primary = primary,
            secondary = secondary,
            etherscan = etherscan,
            cache = InMemoryRegistryCache(),
        ),
        definitionFetcher = definitionFetcher,
    )
}

private val DefinitionFetchError.wireName: String
    get() = when (this) {
        DefinitionFetchError.NOT_CONFIGURED -> "definition_not_configured"
        DefinitionFetchError.INVALID_URL_TEMPLATE -> "definition_invalid_url_template"
        DefinitionFetchError.HTTP_ERROR -> "definition_http_error"
        DefinitionFetchError.HASH_MISMATCH -> "definition_hash_mismatch"
        DefinitionFetchError.DECODE_ERROR -> "definition_decode_error"
        DefinitionFetchError.EVENT_ID_MISMATCH -> "definition_event_id_mismatch"
        DefinitionFetchError.VALIDITY_MISMATCH -> "definition_validity_mismatch"
    }

private const val SEPOLIA_CHAIN_ID: Long = 11_155_111L
