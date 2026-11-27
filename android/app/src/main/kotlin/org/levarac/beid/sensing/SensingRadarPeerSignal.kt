package org.levarac.beid.sensing

/**
 * One detected peer of the live sensing session, for the radar (beid#722;
 * iOS `SensingView.radarPeers` = `detectedDisplayIDs` with
 * `SensingCoordinator.signalStrength(forNodeId:)`).
 *
 * [displayId] is the shared-normalized display id
 * (`normalizedDisplayIdOrNull`), the node's identity and angle key.
 * [dbm] is the smoothed signal strength, or `null` when the peer has no
 * usable measurement yet (iOS `NodeSignalStrength.unmeasured`): a node with
 * no measurement must never be drawn as if it were close.
 *
 * **Display only and in memory only.** No record, signature, submission,
 * ledger or log line reads this, and nothing persists it.
 */
data class SensingRadarPeerSignal(val displayId: String, val dbm: Double?)
