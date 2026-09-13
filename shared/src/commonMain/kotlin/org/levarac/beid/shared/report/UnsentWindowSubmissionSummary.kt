package org.levarac.beid.shared.report

/** Counts durable closed observation windows, across all saved events and days.
 * Open or unpersisted windows are excluded. Acceptance means a durable ledger
 * acknowledgement, never merely a proof record or an attempted network request.
 * A permanently held report has the existing ledger deadline Long.MAX_VALUE.
 * This projection is read-only and cannot schedule, acknowledge, or retry work.
 */
public data class UnsentWindowSubmissionSummary(
    public val queued: Int = 0,
    public val sending: Int = 0,
    public val retrying: Int = 0,
    public val stopped: Int = 0,
    public val accepted: Int = 0,
)

public fun summarizeUnsentWindowSubmissions(ledger: UnsentWindowLedger): UnsentWindowSubmissionSummary {
    var summary = UnsentWindowSubmissionSummary()
    val reports = ledger.state.reports.associateBy { it.submissionKey }
    for (window in ledger.state.windows) {
        val closed = window.closedRevision ?: continue
        if (closed > ledger.state.durableRevision) continue
        val report = reports[window.reportKey]
        summary = when {
            report == null || report.updatedRevision > ledger.state.durableRevision ->
                summary.copy(queued = summary.queued + 1)
            report.status == LedgerReportStatus.ACKNOWLEDGED -> summary.copy(accepted = summary.accepted + 1)
            report.status == LedgerReportStatus.IN_FLIGHT -> summary.copy(sending = summary.sending + 1)
            report.retryNotBeforeEpochMilliseconds == Long.MAX_VALUE -> summary.copy(stopped = summary.stopped + 1)
            else -> summary.copy(retrying = summary.retrying + 1)
        }
    }
    return summary
}
