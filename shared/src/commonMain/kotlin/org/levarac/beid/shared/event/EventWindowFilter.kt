package org.levarac.beid.shared.event

// RED STEP — deliberately wrong implementation. Replaced once the vectors have
// been proven to fail against it. Do not commit this state as the slice result.
public fun isEventWindowOpen(
    definition: EventDefinitionFacts,
    atWindowIndex: Long,
): Boolean = definition.eninStart <= definition.eninEnd
