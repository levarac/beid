package org.levarac.beid.sensing

import org.levarac.parallax.registry.EventDefinitionResolution

/**
 * Drives [EventJoinCoordinator]'s beid#374 join gate from an app-module test.
 *
 * ## What this fake deliberately cannot do
 *
 * It cannot answer with a successful read. [EventDefinitionResolution] carries
 * an `internal` constructor scoped to the shared module, so no code in this
 * module — production or test — can build one. This fake can therefore only
 * express a read that FAILED, by answering null, and a read that is still
 * PENDING, by never answering at all.
 *
 * That is the guarantee working rather than a gap in the fixture, and it is
 * exactly the pair the issue's acceptance criterion asks for: calling join
 * while the registry lookup has failed, or while it is delayed, must start
 * neither join nor sensing. A test that wants a *successful* join reaches it
 * by walking the real promotion path into a registry-verified candidate
 * instead, which is a stronger thing to assert than a fabricated success.
 */
internal class FakeEventJoinRegistry(
    private val answer: Answer = Answer.LOOKUP_FAILS,
    private val eventIdHex: String = DEFAULT_EVENT_ID_HEX,
) : EventJoinRegistry {
    enum class Answer {
        /** The operator lookup cannot route this code. */
        LOOKUP_FAILS,

        /** The code routes, but no verifiable definition comes back. */
        DEFINITION_FAILS,

        /** Neither call ever answers — the read is still outstanding. */
        HOLDS,
    }

    var lookupRequests: Int = 0
        private set
    var definitionRequests: Int = 0
        private set

    private var heldLookup: ((String?) -> Unit)? = null
    private var heldDefinition: ((EventDefinitionResolution?) -> Unit)? = null

    override fun resolveEventId(code: String, completion: (String?) -> Unit) {
        lookupRequests += 1
        when (answer) {
            Answer.HOLDS -> heldLookup = completion
            Answer.LOOKUP_FAILS -> completion(null)
            Answer.DEFINITION_FAILS -> completion(eventIdHex)
        }
    }

    override fun resolveEventDefinition(
        eventIdHex: String,
        useTimeEpochSeconds: Long,
        completion: (EventDefinitionResolution?) -> Unit,
    ) {
        definitionRequests += 1
        when (answer) {
            Answer.HOLDS -> heldDefinition = completion
            Answer.LOOKUP_FAILS, Answer.DEFINITION_FAILS -> completion(null)
        }
    }

    /** Answers a held lookup late, the way a slow network eventually would. */
    fun completeHeldLookup(routed: Boolean = true) {
        val completion = heldLookup ?: return
        heldLookup = null
        completion(if (routed) eventIdHex else null)
    }

    /** Answers a held definition read late. It can only ever answer "no evidence". */
    fun completeHeldDefinition() {
        val completion = heldDefinition ?: return
        heldDefinition = null
        completion(null)
    }

    companion object {
        val DEFAULT_EVENT_ID_HEX = "21".repeat(32)
    }
}
