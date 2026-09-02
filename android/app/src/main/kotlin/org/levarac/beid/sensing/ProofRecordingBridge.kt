package org.levarac.beid.sensing

import java.time.Instant
import java.util.UUID
import org.levarac.beid.persistence.ProofRecord
import org.levarac.beid.persistence.ProofRecordStore

/**
 * Adapts native proof-recording events into [ProofRecordStore] writes.
 * Intended to be wired to three callback properties `#235` is adding to
 * [EventJoinCoordinator] (`onProofCollected`/`onPeersVerifiedChanged`/
 * `onProofSignatureStateChanged`) — not yet landed in this worktree, so
 * built and unit-tested standalone here (beid#121) rather than wired at the
 * call site.
 *
 * **Threading**: the exact dispatcher/thread these methods will be invoked
 * on is still being confirmed with `#235` (unresolved as of this writing).
 * These methods MUST be, and are, safe to call from any thread, without
 * assuming a specific one: [ProofRecordStore] holds two locks for this —
 * [org.levarac.beid.persistence.JsonRecordFileStore]'s internal
 * `synchronized(lock)` protects the durable file, and [ProofRecordStore]'s
 * own outer lock makes each of its methods' "durable write, then
 * `recordsFlow` assignment" sequence atomic as a whole, so a
 * [ProofRecordStore.recordsFlow] read can never observe a state older than
 * the durable file for a write that already completed. (An outer-lock-only
 * fix would not be enough on its own either: it's the *pair*, one per
 * layer, that closes the gap — see [ProofRecordStore]'s own kdoc for the
 * two-step-interleaving failure mode this closes.) A real Android callback
 * data race landed in this repo two days before this class was written
 * (commit `1c7db20`), from exactly this kind of unstated threading
 * assumption — do not remove either of [ProofRecordStore]'s locks even
 * once a confirmed single-thread guarantee would make them look redundant;
 * keep this reasoning attached to the call sites it protects.
 */
class ProofRecordingBridge(
    private val proofRecordStore: ProofRecordStore,
    private val now: () -> Instant = Instant::now,
) {
    fun onProofCollected(proofId: UUID, eventCode: String, peersVerified: Int) {
        proofRecordStore.add(
            ProofRecord(
                id = proofId,
                eventCode = eventCode,
                createdAt = now(),
                peersVerified = peersVerified,
            ),
        )
    }

    fun onPeersVerifiedChanged(proofId: UUID, peersVerified: Int) {
        proofRecordStore.updatePeersVerified(proofId, peersVerified)
    }

    fun onProofSignatureStateChanged(proofId: UUID, hasSelfProof: Boolean, hasBinding: Boolean) {
        proofRecordStore.updateSignatureState(proofId, hasSelfProof, hasBinding)
    }
}
