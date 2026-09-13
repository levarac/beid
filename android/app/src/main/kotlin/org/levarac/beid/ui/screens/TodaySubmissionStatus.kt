package org.levarac.beid.ui.screens

import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOn
import org.levarac.beid.persistence.UnsentWindowLedgerStore
import org.levarac.beid.shared.report.UnsentWindowSubmissionSummary
import org.levarac.beid.shared.report.summarizeUnsentWindowSubmissions
import org.levarac.beid.shared.report.decodeUnsentWindowLedgerSnapshot

/** Native read effect. Reopens the canonical file: production stores have no
 * cross-instance flow, and the drain is owned by a different runtime instance.
 * Invalid data must not be presented as an empty queue. Never quarantine or
 * mutate storage merely to render this screen.
 */
internal fun readTodaySubmissionStatus(filesDir: File): UnsentWindowSubmissionSummary? = try {
    val file = UnsentWindowLedgerStore.defaultFile(filesDir)
    if (!file.exists()) UnsentWindowSubmissionSummary()
    else decodeUnsentWindowLedgerSnapshot(file.readText(Charsets.UTF_8))
        .ledger?.let(::summarizeUnsentWindowSubmissions)
} catch (_: java.io.IOException) {
    null
}

internal fun observeTodaySubmissionStatus(filesDir: File) = flow {
    while (true) {
        emit(readTodaySubmissionStatus(filesDir))
        delay(1_000)
    }
}.flowOn(Dispatchers.IO)
