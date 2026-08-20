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

public class RegistryRequest internal constructor(private val job: Job) {
    public fun cancel() {
        job.cancel()
    }
}

public class RegistryClient internal constructor(
    private val resolver: RegistryResolver,
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Default),
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
): RegistryClient? {
    if (readerAddressHex.isBlank()) return null
    val readerAddress = try {
        validateReaderAddress(readerAddressHex)
    } catch (_: IllegalArgumentException) {
        return null
    }
    val transport = createPlatformRegistryHttpTransport()
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
    )
}

private const val SEPOLIA_CHAIN_ID: Long = 11_155_111L
