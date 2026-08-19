package org.levarac.beid.sensing

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
     * Co-presence: cleared whenever [enin] differs from the last-seen ENIN,
     * **before** inserting [rpid] and reading the count — a lingering
     * device's rotated `rpid` from a previous window must never still be
     * counted in this window.
     *
     * Distinct devices: keyed on [detectedDisplayId], lowercased to match
     * observation (Barnard emits lowercase hex today; normalize so a future
     * case change can't split one device into two). Observations with a
     * null [detectedDisplayId] (Barnard B003 unavailable) are excluded
     * entirely — never falling back to [rpid], which rotates and would
     * inflate the distinct count.
     */
    fun record(enin: Long, rpid: String, detectedDisplayId: String?): Boolean {
        if (lastEnin != enin) {
            coPresentRpids.clear()
            lastEnin = enin
        }
        coPresentRpids.add(rpid)

        val displayId = detectedDisplayId?.lowercase() ?: return false
        return distinctDeviceIds.add(displayId)
    }
}
