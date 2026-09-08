package org.levarac.beid.sensing

import org.levarac.parallax.registry.EventDefinitionResolution
import org.levarac.parallax.registry.RegistryClient
import org.levarac.parallax.registry.safeRegistryReadPin

/**
 * The join gate's registry seam (beid#374) — the effect boundary
 * [EventJoinCoordinator] crosses to reach
 * [org.levarac.parallax.registry.RegistryClient], whose constructor is
 * `internal` to the shared module and so cannot be stood in for from this
 * app's tests.
 *
 * ## Why the completion is nullable
 *
 * Both completions hand back a shared type this module cannot construct
 * ([EventDefinitionResolution] and, for the lookup, the Event ID a verified
 * read produced). `null` means the read did not produce evidence. That single
 * decision is what makes the seam safe to fake: an app-module test can express
 * a read that FAILED, by answering null, and a read that is still PENDING, by
 * never answering at all — and it cannot express a read that SUCCEEDED,
 * because it cannot build the evidence. Only production, holding a real
 * `RegistryClient`, can do that.
 *
 * That asymmetry is the guarantee working rather than a hole in the tests. It
 * is also precisely what the issue's acceptance criterion needs from the
 * Android side: calling join with the registry failed or delayed must start
 * neither join nor sensing, and both of those are expressible here.
 *
 * Deliberately separate from [NearbyEventRegistry] even though the two answer
 * from the same client. Discovery resolves candidates it observed on the
 * radio, keyed by event-code hash, and may have many resolutions in flight;
 * the join gate resolves the one event a user asked to join. Sharing one seam
 * would let a test's single-slot fake serve both, so a discovery resolution
 * and a join resolution would silently overwrite each other's completion.
 */
internal interface EventJoinRegistry {
    /**
     * Operator-attested routing only, exactly as
     * [RegistryClient.resolveEventId] documents it. The returned ID means
     * nothing until [resolveEventDefinition] verifies it; `null` is a lookup
     * that did not route.
     */
    fun resolveEventId(code: String, completion: (String?) -> Unit)

    /** `null` is a read that produced no verifiable definition. */
    fun resolveEventDefinition(
        eventIdHex: String,
        useTimeEpochSeconds: Long,
        completion: (EventDefinitionResolution?) -> Unit,
    )
}

internal class RegistryClientEventJoinRegistry(
    private val client: RegistryClient,
) : EventJoinRegistry {
    override fun resolveEventId(code: String, completion: (String?) -> Unit) {
        client.resolveEventId(code) { lookup ->
            completion(lookup.eventIdHex?.takeIf { lookup.isSuccess })
        }
    }

    override fun resolveEventDefinition(
        eventIdHex: String,
        useTimeEpochSeconds: Long,
        completion: (EventDefinitionResolution?) -> Unit,
    ) {
        client.resolveEventDefinition(eventIdHex, safeRegistryReadPin(), useTimeEpochSeconds) { resolution ->
            completion(resolution.takeIf { it.isSuccess })
        }
    }
}
