package org.levarac.beid.registry

import org.levarac.beid.BuildConfig
import org.levarac.parallax.registry.RegistryClient
import org.levarac.parallax.registry.createSepoliaRegistryClient

/** App-owned composition only; the registry package itself has no beid dependency. */
internal object RegistryDependencies {
    fun createClient(): RegistryClient? = createSepoliaRegistryClient(
        readerAddressHex = BuildConfig.EVENT_REGISTRY_READER_ADDRESS,
        etherscanApiKey = BuildConfig.ETHERSCAN_API_KEY.ifBlank { null },
        definitionUrlTemplate = BuildConfig.EVENT_DEFINITION_URL_TEMPLATE.ifBlank { null },
        eventKeySetUrlTemplate = BuildConfig.EVENT_KEY_SET_URL_TEMPLATE.ifBlank { null },
    )
}
