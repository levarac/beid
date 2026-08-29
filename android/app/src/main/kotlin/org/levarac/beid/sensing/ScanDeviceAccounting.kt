package org.levarac.beid.sensing

import org.levarac.beid.shared.sensing.coPresenceWindowBoundaryCrossed
import org.levarac.beid.shared.sensing.normalizedDisplayIdOrNull

/**
 * Native device-count bookkeeping feeding [applyPhaseDecision]'s
 * `coPresentDeviceCount`/`distinctDeviceCount`/`distinctDeviceCountChanged`
 * arguments — a native/aggregation-family effect, not a shared decision
 * (mirrors iOS's `currentWindowRpids`/`aggregationRuntime` bookkeeping in
 * `SensingCoordinator`, at the essential-invariants level this slice needs,
 * without iOS's full ledger/proof/aggregation machinery).
 *
 * Scoped to one sensing session — call [reset] whenever [ScanPhase] returns
 * to `Idle`/restarts.
 */
class ScanDeviceAccounting {
    private var lastEnin: Long? = null
    private val coPresentRpids = mutableSetOf<String>()
    private val distinctDeviceIds = mutableSetOf<String>()

    val coPresentDeviceCount: Int get() = coPresentRpids.size
    val distinctDeviceCount: Int get() = distinctDeviceIds.size

    fun reset() {
        lastEnin = null
        coPresentRpids.clear()
        distinctDeviceIds.clear()
    }

    /**
     * Files one detection against both counters and returns whether
     * [distinctDeviceCount] moved — the caller's `distinctDeviceCountChanged`
     * argument into [applyPhaseDecision].
     *
     * Co-presence: cleared **before** inserting [rpid] and reading the
     * count whenever [coPresenceWindowBoundaryCrossed] (beid#231) says
     * [enin] crosses a window boundary relative to the last-seen ENIN — a
     * lingering device's rotated `rpid` from a previous window must never
     * still be counted in this window.
     *
     * Distinct devices: keyed on [normalizedDisplayIdOrNull] (beid#231) of
     * [detectedDisplayId]. Observations with a null [detectedDisplayId]
     * (Barnard B003 unavailable) are excluded entirely — never falling back
     * to [rpid], which rotates and would inflate the distinct count.
     */
    fun record(enin: Long, rpid: String, detectedDisplayId: String?): Boolean {
        if (coPresenceWindowBoundaryCrossed(lastEnin, enin)) {
            coPresentRpids.clear()
            lastEnin = enin
        }
        coPresentRpids.add(rpid)

        val displayId = normalizedDisplayIdOrNull(detectedDisplayId) ?: return false
        return distinctDeviceIds.add(displayId)
    }
}
