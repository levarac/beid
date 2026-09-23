package org.levarac.beid.sensing

import org.levarac.beid.shared.jointestsupport.createEventDefinitionResolutionForTesting
import org.levarac.beid.shared.jointestsupport.createFailedEventDefinitionResolutionForTesting
import org.levarac.parallax.registry.EventDefinitionResolution
import org.levarac.parallax.registry.EventJoinMode

/**
 * Drives [EventJoinCoordinator]'s beid#374 join gate from an app-module test.
 *
 * ## What this fake can and cannot answer
 *
 * It used to be unable to answer with a successful read at all:
 * [EventDefinitionResolution] carries an `internal` constructor scoped to the
 * shared module, so nothing in this module could build one. The doc here said
 * so, and treated it as the guarantee working rather than a gap.
 *
 * **It was a gap.** The consequence was that the gate's *admitting* branch and
 * its "read succeeded but the definition is not eligible" branch had no test
 * on either platform — a regression that refused every event, or admitted an
 * ineligible one, would have kept both suites green. beid#473 added a shared
 * factory (`createEventDefinitionResolutionForTesting`) and this fake now uses
 * it for [Answer.DEFINITION_NOT_ELIGIBLE].
 *
 * A failed read is built with the shared test factory and then filtered to the
 * nullable seam, mirroring [RegistryClientEventJoinRegistry]. The fake thus
 * exercises the same non-null resolution shape production delivers before the
 * adapter applies its safety filter.
 *
 * A test that wants a *successful* join still reaches it by walking the real
 * promotion path into a registry-verified candidate, which is a stronger thing
 * to assert than a fabricated success.
 */
internal class FakeEventJoinRegistry(
    private val answer: Answer = Answer.LOOKUP_FAILS,
    private val eventIdHex: String = DEFAULT_EVENT_ID_HEX,
    /**
     * The registry wire name this fake reports alongside a failure (beid#463).
     * Defaults to `null` — an unnamed failure — so every existing test keeps
     * asserting the behaviour it was written for, and a test that cares about
     * *why* has to say which failure it is simulating rather than inheriting
     * one.
     */
    private val errorCode: String? = null,
) : EventJoinRegistry {
    enum class Answer {
        /** The operator lookup cannot route this code. */
        LOOKUP_FAILS,

        /** The code routes, but no verifiable definition comes back. */
        DEFINITION_FAILS,

        /** Neither call ever answers — the read is still outstanding. */
        HOLDS,

        /**
         * The read succeeds and the definition is real, and the gate refuses it
         * anyway because it is not open admission.
         *
         * This is the branch iOS calls `definitionNotEligible`. It was
         * unreachable from a test until beid#473, so "a successful read is not
         * by itself permission to join" was asserted nowhere (beid#434).
         */
        DEFINITION_NOT_ELIGIBLE,
    }

    var lookupRequests: Int = 0
        private set
    var definitionRequests: Int = 0
        private set

    private var heldLookup: ((String?, String?) -> Unit)? = null
    private var heldDefinition: ((EventDefinitionResolution?, String?) -> Unit)? = null

    override fun resolveEventId(code: String, completion: (String?, String?) -> Unit) {
        lookupRequests += 1
        when (answer) {
            Answer.HOLDS -> heldLookup = completion
            Answer.LOOKUP_FAILS -> completion(null, errorCode)
            Answer.DEFINITION_FAILS, Answer.DEFINITION_NOT_ELIGIBLE -> completion(eventIdHex, null)
        }
    }

    override fun resolveEventDefinition(
        eventIdHex: String,
        useTimeEpochSeconds: Long,
        completion: (EventDefinitionResolution?, String?) -> Unit,
    ) {
        definitionRequests += 1
        when (answer) {
            Answer.HOLDS -> heldDefinition = completion
            Answer.LOOKUP_FAILS -> completion(null, errorCode)
            Answer.DEFINITION_FAILS -> {
                val resolution = createFailedEventDefinitionResolutionForTesting(
                    errorCode = errorCode,
                    errorMessage = "fake definition read failed",
                )
                completion(resolution.takeIf { it.isSuccess }, resolution.errorCode)
            }
            Answer.DEFINITION_NOT_ELIGIBLE -> completion(ineligibleResolution(useTimeEpochSeconds), null)
        }
    }

    /** Answers a held lookup late, the way a slow network eventually would. */
    fun completeHeldLookup(routed: Boolean = true) {
        val completion = heldLookup ?: return
        heldLookup = null
        completion(if (routed) eventIdHex else null, if (routed) null else errorCode)
    }

    /** Answers a held definition read late. It can only ever answer "no evidence". */
    fun completeHeldDefinition() {
        val completion = heldDefinition ?: return
        heldDefinition = null
        completion(null, errorCode)
    }

    /**
     * A definition the gate refuses for one reason: it is [EventJoinMode.GATED],
     * not open admission. Everything else about it is valid and inside its
     * validity window, so a refusal here can only have come from the eligibility
     * rule and not from missing evidence.
     */
    private fun ineligibleResolution(nowEpochSeconds: Long): EventDefinitionResolution =
        createEventDefinitionResolutionForTesting(
            eventIdHex = eventIdHex,
            definitionHashHex = "bb".repeat(32),
            blockHashHex = "cc".repeat(32),
            validFromEpochSeconds = nowEpochSeconds - 86_400,
            validUntilEpochSeconds = nowEpochSeconds + 86_400,
            joinMode = EventJoinMode.GATED,
        )

    companion object {
        val DEFAULT_EVENT_ID_HEX = "21".repeat(32)
    }
}
