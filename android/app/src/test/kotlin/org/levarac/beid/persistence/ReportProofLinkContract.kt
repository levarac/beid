package org.levarac.beid.persistence

import java.io.File
import java.util.UUID

/** Pair projection keeps the link contract assertions independent of row representation. */
internal class ReportProofLinkContract(file: File, writer: ((File, ByteArray) -> Unit)? = null) {
    val instance = if (writer == null) ReportProofLinkStore(file) else ReportProofLinkStore(file, writer)

    fun add(windowId: UUID, proofId: UUID) = instance.add(windowId, proofId)
    fun links(): List<Pair<UUID, UUID>> = instance.links().map { it.windowId to it.proofId }
    fun proofIdFor(windowId: UUID): UUID? = instance.proofIdFor(windowId)
    fun windowIdsFor(proofId: UUID): Set<UUID> = instance.windowIdsFor(proofId)
}
