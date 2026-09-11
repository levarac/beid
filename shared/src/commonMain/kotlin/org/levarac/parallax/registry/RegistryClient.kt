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
    /** The actual resolver read's source, requested event and pinned block; absent on failure. */
    public val readKey: RegistryCacheKey? = null,
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

/**
 * Result of [RegistryClient.resolveEventId] — a routing hint, not a trust
 * boundary. [eventIdHex] still requires [RegistryClient.resolveEventDefinition]
 * to be trusted for anything (beid#258 P1-1; dispatch#21 tracks the durable
 * replacement).
 */
public class EventIdLookupResolution internal constructor(
    public val isSuccess: Boolean,
    public val eventIdHex: String?,
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
    private val definitionConfigurationError: DefinitionFetchException? = null,
    private val eventKeySetFetcher: EventKeySetFetcher? = null,
    private val eventKeySetConfigurationError: DefinitionFetchException? = null,
    private val eventCodeLookupFetcher: EventCodeLookupFetcher? = null,
    private val eventCodeLookupConfigurationError: EventCodeLookupException? = null,
    private val eventCodeHashLookupFetcher: EventCodeHashLookupFetcher? = null,
    private val eventCodeHashLookupConfigurationError: EventCodeLookupException? = null,
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
                    readKey = result.cacheKey,
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
                val fetcher = definitionFetcher ?: run {
                    throw definitionConfigurationError ?: DefinitionFetchException(
                        DefinitionFetchError.NOT_CONFIGURED,
                        "signed definition URL template is not configured",
                    )
                }
                val keySetFetcher = eventKeySetFetcher ?: run {
                    throw eventKeySetConfigurationError ?: DefinitionFetchException(
                        DefinitionFetchError.KEY_SET_NOT_CONFIGURED,
                        "EventKeySet URL template is not configured",
                    )
                }
                val eventId = eventIdHex.decodeHex(expectedBytes = 32)
                val result = resolver.resolve(eventId, pin)
                val record = definitionForUseTime(result.context, useTimeEpochSeconds)
                    ?: if (result.context.definitionCount == 0) {
                        throw DefinitionFetchException(
                            DefinitionFetchError.NOT_FOUND,
                            "no registry definition has ever been registered for this event",
                        )
                    } else {
                        throw DefinitionFetchException(
                            DefinitionFetchError.VALIDITY_MISMATCH,
                            "no registry definition is valid at the requested time",
                        )
                    }
                val encodedEventKeySet = keySetFetcher.fetch(result.context.registration.keySetDigestHex)
                val context = fetcher.fetch(
                    eventId = eventId,
                    registration = result.context.registration,
                    record = record,
                    selectedAt = useTimeEpochSeconds,
                    encodedEventKeySet = encodedEventKeySet,
                )
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

    /**
     * Resolves a normalized event code (see `normalizedEventCodeOrNull`) to the
     * registry's canonical Event ID via the deployment-configured operator
     * lookup endpoint (beid#258 P1-1 interim mechanism). This is a routing
     * hint only, never a trust boundary: callers must still pass the returned
     * ID through [resolveEventDefinition], which independently verifies it
     * on-chain and against the authority signature before trusting anything
     * derived from it. See dispatch#21 for the durable, cryptographically-bound
     * replacement.
     */
    public fun resolveEventId(
        code: String,
        completion: (EventIdLookupResolution) -> Unit,
    ): RegistryRequest {
        val job = scope.launch {
            val resolution = try {
                val fetcher = eventCodeLookupFetcher ?: run {
                    throw eventCodeLookupConfigurationError ?: EventCodeLookupException(
                        EventCodeLookupError.NOT_CONFIGURED,
                        "event code lookup URL template is not configured",
                    )
                }
                val eventIdHex = fetcher.fetch(code)
                EventIdLookupResolution(
                    isSuccess = true,
                    eventIdHex = eventIdHex,
                    errorCode = null,
                    errorMessage = null,
                )
            } catch (error: CancellationException) {
                EventIdLookupResolution(
                    isSuccess = false,
                    eventIdHex = null,
                    errorCode = RegistryErrorCode.CANCELLED.wireName,
                    errorMessage = "event code lookup was cancelled",
                )
            } catch (error: EventCodeLookupException) {
                EventIdLookupResolution(
                    isSuccess = false,
                    eventIdHex = null,
                    errorCode = error.reason.wireName,
                    errorMessage = error.message,
                )
            } catch (_: Throwable) {
                EventIdLookupResolution(
                    isSuccess = false,
                    eventIdHex = null,
                    errorCode = RegistryErrorCode.PROTOCOL_ERROR.wireName,
                    errorMessage = "event code lookup failed",
                )
            }
            completion(resolution)
        }
        return RegistryRequest(job)
    }

    /** Operator-attested routing only; callers must verify the returned ID with resolveEventDefinition. */
    public fun resolveEventIdByCodeHash(hashHex: String, completion: (EventIdLookupResolution) -> Unit): RegistryRequest {
        val job = scope.launch {
            val resolution = try {
                val fetcher = eventCodeHashLookupFetcher ?: throw (eventCodeHashLookupConfigurationError
                    ?: EventCodeLookupException(EventCodeLookupError.NOT_CONFIGURED, "event code hash lookup URL template is not configured"))
                EventIdLookupResolution(true, fetcher.fetch(hashHex), null, null)
            } catch (error: CancellationException) {
                EventIdLookupResolution(false, null, RegistryErrorCode.CANCELLED.wireName, "event code hash lookup was cancelled")
            } catch (error: EventCodeLookupException) {
                EventIdLookupResolution(false, null, error.reason.wireName, error.message)
            } catch (_: Throwable) {
                EventIdLookupResolution(false, null, RegistryErrorCode.PROTOCOL_ERROR.wireName, "event code hash lookup failed")
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
    eventKeySetUrlTemplate: String? = null,
    eventCodeLookupUrlTemplate: String? = null,
    eventCodeHashLookupUrlTemplate: String? = null,
): RegistryClient? = createSepoliaRegistryClientWithTransport(
    readerAddressHex = readerAddressHex,
    etherscanApiKey = etherscanApiKey,
    definitionUrlTemplate = definitionUrlTemplate,
    eventKeySetUrlTemplate = eventKeySetUrlTemplate,
    eventCodeLookupUrlTemplate = eventCodeLookupUrlTemplate,
    eventCodeHashLookupUrlTemplate = eventCodeHashLookupUrlTemplate,
    transportFactory = ::createPlatformRegistryHttpTransport,
)

internal fun createSepoliaRegistryClientWithTransport(
    readerAddressHex: String,
    etherscanApiKey: String? = null,
    definitionUrlTemplate: String? = null,
    eventKeySetUrlTemplate: String? = null,
    eventCodeLookupUrlTemplate: String? = null,
    eventCodeHashLookupUrlTemplate: String? = null,
    transportFactory: () -> RegistryHttpTransport,
): RegistryClient? {
    if (readerAddressHex.isBlank()) return null
    val readerAddress = try {
        validateReaderAddress(readerAddressHex)
    } catch (_: IllegalArgumentException) {
        return null
    }
    val transport = transportFactory()
    var definitionConfigurationError: DefinitionFetchException? = null
    var eventKeySetConfigurationError: DefinitionFetchException? = null
    var eventCodeLookupConfigurationError: EventCodeLookupException? = null
    var eventCodeHashLookupConfigurationError: EventCodeLookupException? = null
    val definitionFetcher = definitionUrlTemplate
        ?.takeIf { it.isNotBlank() }
        ?.let { template ->
            val validated = createDefinitionUrlTemplate(template)
            if (validated == null) {
                definitionConfigurationError = DefinitionFetchException(
                    DefinitionFetchError.INVALID_URL_TEMPLATE,
                    "signed definition URL template is invalid",
                )
                null
            } else {
                SignedDefinitionFetcher(validated, transport)
            }
        }
    val eventKeySetFetcher = eventKeySetUrlTemplate
        ?.takeIf { it.isNotBlank() }
        ?.let { template ->
            val validated = createEventKeySetUrlTemplate(template)
            if (validated == null) {
                eventKeySetConfigurationError = DefinitionFetchException(
                    DefinitionFetchError.KEY_SET_INVALID_URL_TEMPLATE,
                    "EventKeySet URL template is invalid",
                )
                null
            } else {
                EventKeySetFetcher(validated, transport)
            }
        }
    val eventCodeLookupFetcher = eventCodeLookupUrlTemplate
        ?.takeIf { it.isNotBlank() }
        ?.let { template ->
            val validated = createEventCodeLookupUrlTemplate(template)
            if (validated == null) {
                eventCodeLookupConfigurationError = EventCodeLookupException(
                    EventCodeLookupError.INVALID_URL_TEMPLATE,
                    "event code lookup URL template is invalid",
                )
                null
            } else {
                EventCodeLookupFetcher(validated, transport)
            }
        }
    val eventCodeHashLookupFetcher = eventCodeHashLookupUrlTemplate?.takeIf { it.isNotBlank() }?.let { template ->
        val validated = createEventCodeHashLookupUrlTemplate(template)
        if (validated == null) {
            eventCodeHashLookupConfigurationError = EventCodeLookupException(EventCodeLookupError.INVALID_URL_TEMPLATE, "event code hash lookup URL template is invalid")
            null
        } else EventCodeHashLookupFetcher(validated, transport)
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
        definitionConfigurationError = definitionConfigurationError,
        eventKeySetFetcher = eventKeySetFetcher,
        eventKeySetConfigurationError = eventKeySetConfigurationError,
        eventCodeLookupFetcher = eventCodeLookupFetcher,
        eventCodeLookupConfigurationError = eventCodeLookupConfigurationError,
        eventCodeHashLookupFetcher = eventCodeHashLookupFetcher,
        eventCodeHashLookupConfigurationError = eventCodeHashLookupConfigurationError,
    )
}

private val DefinitionFetchError.wireName: String
    get() = when (this) {
        DefinitionFetchError.NOT_CONFIGURED -> "definition_not_configured"
        DefinitionFetchError.INVALID_URL_TEMPLATE -> "definition_invalid_url_template"
        DefinitionFetchError.KEY_SET_INVALID_URL_TEMPLATE -> "definition_key_set_invalid_url_template"
        DefinitionFetchError.INVALID_KEY_SET -> "definition_invalid_key_set"
        DefinitionFetchError.KEY_SET_NOT_CONFIGURED -> "definition_key_set_not_configured"
        DefinitionFetchError.KEY_SET_HTTP_ERROR -> "definition_key_set_http_error"
        DefinitionFetchError.KEY_SET_HASH_MISMATCH -> "definition_key_set_hash_mismatch"
        DefinitionFetchError.KEY_SET_PAYLOAD_TOO_LARGE -> "definition_key_set_payload_too_large"
        DefinitionFetchError.HTTP_ERROR -> "definition_http_error"
        DefinitionFetchError.HASH_MISMATCH -> "definition_hash_mismatch"
        DefinitionFetchError.DECODE_ERROR -> "definition_decode_error"
        DefinitionFetchError.EVENT_ID_MISMATCH -> "definition_event_id_mismatch"
        DefinitionFetchError.NOT_FOUND -> "definition_not_found"
        DefinitionFetchError.VALIDITY_MISMATCH -> "definition_validity_mismatch"
        DefinitionFetchError.PAYLOAD_TOO_LARGE -> "definition_payload_too_large"
    }

private val EventCodeLookupError.wireName: String
    get() = when (this) {
        EventCodeLookupError.NOT_CONFIGURED -> "event_code_lookup_not_configured"
        EventCodeLookupError.INVALID_URL_TEMPLATE -> "event_code_lookup_invalid_url_template"
        EventCodeLookupError.HTTP_ERROR -> "event_code_lookup_http_error"
        EventCodeLookupError.NOT_FOUND -> "event_code_lookup_not_found"
        EventCodeLookupError.INVALID_RESPONSE -> "event_code_lookup_invalid_response"
    }

internal const val SEPOLIA_CHAIN_ID: Long = 11_155_111L
