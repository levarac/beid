package org.levarac.parallax.registry

/** Pure use-time selection over immutable anchor metadata. */
internal object DefinitionSelection {
    internal fun select(
        context: RegistryEventContext,
        useTimeEpochSeconds: Long,
    ): RegistryDefinitionRecord? = context.definitions.firstOrNull { definition ->
        useTimeEpochSeconds >= definition.validFrom && useTimeEpochSeconds <= definition.validUntil
    }
}
