package org.levarac.beid.sensing

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runCurrent
import org.levarac.parallax.registry.EventJoinMode

/**
 * The one way an app-module test reaches a joined session (beid#374).
 *
 * ## Why this exists and why it is shaped like this
 *
 * Join now requires a `RegistryVerifiedJoinContext`, and that type is issued
 * only by `shared/` from evidence this module cannot fabricate. There is
 * deliberately no shortcut: no test-visible constructor, no factory, no
 * internal-made-visible-for-testing anything. A test that wants a joined
 * session must therefore do what a real device does — observe an envelope
 * barnard genuinely verifies, let the registry answer, and let the shared
 * reducer promote the candidate to `REGISTRY_VERIFIED`.
 *
 * That is more setup than the old `joinEvent("SOME-CODE")` line it replaces,
 * and it buys something the old line never had: every test downstream of it
 * now exercises the real promotion path end to end, rather than a fake
 * registry answer that agreed by construction.
 *
 * ## Why the clock is what it is
 *
 * barnard's conformance vector is signed over a specific ENIN window, and the
 * registry definition must agree with it exactly or the envelope is never
 * promoted. That fixes the definition's validity window, and the join issuer
 * re-checks that window against *now* at the moment of the tap. So a test
 * clock sitting at zero — the `TestScope` default — is outside the window and
 * the issuer correctly refuses. [VECTOR_NOW_EPOCH_MILLIS] places the clock inside
 * the vector's own window while still letting `advanceTimeBy` move it, so
 * cadence and expiry tests keep working.
 */
@OptIn(ExperimentalCoroutinesApi::class)
internal object NearbyEventPromotionFixture {
    /**
     * barnard's own B005 v2 conformance vector, `v1_*` from
     * `test-vectors/b005-envelope-v2.txt` at tag v0.8.0: authority-direct
     * mode, hop zero, genuinely signed. Copied rather than synthesised because
     * the gate only ever sees envelopes barnard verified, and nothing this
     * repository can fabricate would get that far.
     */
    const val CONTAINER_HEX = "03000100011111111111111111111111111111111111111111222222222222222222222222222222222222222233333333333333333333333333333333333333333333333333333333333333330102f9308a019258c31049344f85f89d5229b531c845836f99b08601f113bce036f900012c005b8d76005b8d8a005b8d82029adc61d60dda843e3a4261726e6172642052656c617920436f6e666f726d616e6365204576656e742030313233343536373839206162636465666768696a6b6c6d6e6f00f3e5c7db67db1a676b3e488b9f7805bdb0c7078a97cd65a01b2ba8630bc7bb334a594053371a53830a4cac5f57e74cbd1d684ca822859ca5fa510ef28b203b5000"

    const val ENVELOPE_HEX = "011111111111111111111111111111111111111111222222222222222222222222222222222222222233333333333333333333333333333333333333333333333333333333333333330102f9308a019258c31049344f85f89d5229b531c845836f99b08601f113bce036f900012c005b8d76005b8d8a005b8d82029adc61d60dda843e3a4261726e6172642052656c617920436f6e666f726d616e6365204576656e742030313233343536373839206162636465666768696a6b6c6d6e6f00f3e5c7db67db1a676b3e488b9f7805bdb0c7078a97cd65a01b2ba8630bc7bb334a594053371a53830a4cac5f57e74cbd1d684ca822859ca5fa510ef28b203b5000"

    const val EVENT_ID_HEX = "5d5891b92a9a6597aa2c58586fd2fdf3974f40f732b9a319ec9f3fc4d7ab3195"
    const val KEY_SET_DIGEST = "cba59e50c7666ef2468a14f2e53f04decfd078933cd245a9a2d77532eb23b700"
    const val EVENT_CODE_HASH = "9adc61d60dda843e"
    const val VALID_FROM_ENIN = 5_999_990L
    const val VALID_THROUGH_ENIN = 6_000_010L
    const val ENIN_SECONDS = 300L

    /** Inside the vector's signed relay window `[validFrom, relayExpires)`. */
    const val ENIN = 6_000_000L

    /** The definition digest and pinned block the promotion retains. */
    const val DEFINITION_HASH_HEX = "ab6f2c1d9e4b8a7350c1d2e3f405162738495a6b7c8d9e0f1a2b3c4d5e6f7081"
    const val BLOCK_HASH_HEX = "cd9e8f7a6b5c4d3e2f10112233445566778899aabbccddeeff00112233445566"

    val CONTAINER: ByteArray = CONTAINER_HEX.fixtureHexBytes()
    val ENVELOPE: ByteArray = ENVELOPE_HEX.fixtureHexBytes()
    val EVENT_CODE_HASH_BYTES: ByteArray = EVENT_CODE_HASH.fixtureHexBytes()

    /**
     * A wall-clock instant inside the vector's signed window. Tests add
     * `testScheduler.currentTime` to this so virtual time still advances.
     */
    const val VECTOR_NOW_EPOCH_MILLIS: Long = ENIN * ENIN_SECONDS * 1_000L

    /**
     * The registry's answer for the vector, expressed the way a registry
     * carries it. The window is the vector's own, converted from ENINs to Unix
     * seconds, because barnard converts back and requires exact agreement —
     * widening it here would make the envelope disagree and nothing would ever
     * be promoted.
     *
     * The digest and the pinned block ARE free to vary: barnard's agreement
     * compares the definition's own fields -- event id, key-set digest, join
     * mode, event-code hash and window -- and not the registry metadata about
     * which definition record carried them. That is what lets a test stand up
     * two different definitions for the one event this module can promote.
     */
    fun definition(
        definitionHashHex: String = DEFINITION_HASH_HEX,
        blockHashHex: String = BLOCK_HASH_HEX,
    ): NearbyEventDefinitionVerification = NearbyEventDefinitionVerification(
        isSuccess = true,
        joinMode = EventJoinMode.OPEN,
        eventIdHex = EVENT_ID_HEX,
        eventCodeHashHex = EVENT_CODE_HASH,
        validFromEpochSeconds = VALID_FROM_ENIN * ENIN_SECONDS,
        validUntilEpochSeconds = (VALID_THROUGH_ENIN + 1) * ENIN_SECONDS - 1,
        keySetDigestHex = KEY_SET_DIGEST,
        definitionHashHex = definitionHashHex,
        blockHashHex = blockHashHex,
    )
}

/**
 * Drives the real promotion: a genuinely verified envelope, then the
 * registry answer that agrees with it. Leaves the candidate at
 * `REGISTRY_VERIFIED` with its definition digest, pinned block and
 * validity window retained.
 */
@OptIn(ExperimentalCoroutinesApi::class)
internal fun TestScope.promoteVectorCandidate(
    engine: FakeEventJoinEngine,
    registry: FakeNearbyEventRegistry,
    definitionHashHex: String = NearbyEventPromotionFixture.DEFINITION_HASH_HEX,
    blockHashHex: String = NearbyEventPromotionFixture.BLOCK_HASH_HEX,
) {
    engine.emitVerifiedEnvelopeV2(
        "peripheral-vector",
        NearbyEventPromotionFixture.CONTAINER,
        NearbyEventPromotionFixture.ENIN,
    )
    runCurrent()
    registry.completeLookup(NearbyEventIdLookup(true, NearbyEventPromotionFixture.EVENT_ID_HEX, null))
    runCurrent()
    registry.completeDefinition(NearbyEventPromotionFixture.definition(definitionHashHex, blockHashHex))
    runCurrent()
}

/**
 * Promotes the vector candidate and joins it through the real gate.
 *
 * This is the replacement for `coordinator.joinEvent("SOME-CODE")` in every
 * test that needs a live session. It obtains its capability from the shared
 * issuer by walking the promotion path, so a test that reaches a joined
 * session here has proven the path works rather than assumed it.
 */
@OptIn(ExperimentalCoroutinesApi::class)
internal fun TestScope.joinPromotedVectorEvent(
    coordinator: EventJoinCoordinator,
    engine: FakeEventJoinEngine,
    registry: FakeNearbyEventRegistry,
    definitionHashHex: String = NearbyEventPromotionFixture.DEFINITION_HASH_HEX,
    blockHashHex: String = NearbyEventPromotionFixture.BLOCK_HASH_HEX,
) {
    promoteVectorCandidate(engine, registry, definitionHashHex, blockHashHex)
    coordinator.joinNearbyEvent(NearbyEventPromotionFixture.EVENT_CODE_HASH)
    runCurrent()
}

/**
 * The discovery seam's test double, holding one lookup and one definition
 * completion so a test decides when the registry answers.
 *
 * Promoted out of `EventJoinCoordinatorRelayLifecycleTest`, its original
 * file-private home, because every suite that needs a joined session now needs
 * one of these.
 */
internal class FakeNearbyEventRegistry : NearbyEventRegistry {
    private var lookupCompletion: ((NearbyEventIdLookup) -> Unit)? = null
    private var definitionCompletion: ((NearbyEventDefinitionVerification) -> Unit)? = null

    override fun resolveEventIdByCodeHash(
        hashHex: String,
        completion: (NearbyEventIdLookup) -> Unit,
    ): NearbyEventRegistryRequest {
        lookupCompletion = completion
        return NearbyEventRegistryRequest {}
    }

    override fun resolveEventDefinition(
        eventIdHex: String,
        useTimeEpochSeconds: Long,
        completion: (NearbyEventDefinitionVerification) -> Unit,
    ): NearbyEventRegistryRequest {
        definitionCompletion = completion
        return NearbyEventRegistryRequest {}
    }

    fun completeLookup(result: NearbyEventIdLookup) {
        // Verified v2 candidates carry the already-checked event ID directly;
        // that production path intentionally skips the legacy hash lookup.
        lookupCompletion?.invoke(result)
    }

    fun completeDefinition(result: NearbyEventDefinitionVerification) {
        requireNotNull(definitionCompletion) { "no definition read was started" }(result)
    }
}

internal fun String.fixtureHexBytes(): ByteArray =
    chunked(2).map { it.toInt(16).toByte() }.toByteArray()
