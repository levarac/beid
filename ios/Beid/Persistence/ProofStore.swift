// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import Foundation

/// On-device JSON store for collected proofs and terminal signing-discard
/// decisions. Both share one atomic file and acknowledgement authority.
@MainActor
final class ProofStore: ObservableObject {
  @Published private(set) var proofs: [Proof] = []
  @Published private(set) var lastPersistenceError: Error?

  /// Set when `load()` preserved a file that failed to decode, so the event
  /// is not invisible. Broader observability is beid#131's job.
  private(set) var quarantinedFileURL: URL?

  /// Set when the existing file could neither be read nor preserved.
  /// Saving would destroy bytes that were never captured, so this instance
  /// stops writing and keeps its proofs in memory only. Readable for the
  /// same reason `quarantinedFileURL` is: a `print` is invisible in a
  /// shipped build, and a store that silently stops persisting is the shape
  /// of the defect this file exists to fix.
  private(set) var persistenceSuspensionReason: Error?

  var isPersistenceSuspended: Bool { persistenceSuspensionReason != nil }
  private(set) var hasReadableProofs = false
  private var persistedProofIds: Set<UUID> = []

  private let fileURL: URL
  private var orphanDiscards: [OrphanDiscard] = []

  /// Terminal decisions share the parent store and its acknowledgement authority.
  private struct OrphanDiscard: Codable, Equatable {
    let proofId: UUID
    let eventCode: String
    var acknowledged: Bool
  }

  private struct DiscardMetadata: Decodable {
    let orphanDiscards: [OrphanDiscard]
    private enum CodingKeys: String, CodingKey { case orphanDiscards }

    init(from decoder: Decoder) throws {
      if (try? decoder.unkeyedContainer()) != nil {
        orphanDiscards = []
      } else {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        orphanDiscards = try container.decodeIfPresent([OrphanDiscard].self, forKey: .orphanDiscards) ?? []
      }
    }
  }
  private let encodeRecords: ([Proof]) throws -> Data
  private let writeData: (Data, URL) throws -> Void

  init(
    fileURL: URL? = nil,
    encodeRecords: @escaping ([Proof]) throws -> Data = { try RecordSchemaEnvelope.encodeRecords($0) },
    writeData: @escaping (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }
  ) {
    self.fileURL = fileURL ?? Self.defaultFileURL()
    self.encodeRecords = encodeRecords
    self.writeData = writeData
    load()
  }

  private static func defaultFileURL() -> URL {
    let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    return dir.appendingPathComponent("proofs.json")
  }

  @discardableResult
  func add(_ proof: Proof) -> Bool {
    var updated = proofs.filter { $0.id != proof.id }
    updated.insert(proof, at: 0)
    return save(updated)
  }

  /// Memory-only fallback entries cannot support a saved-record claim.
  func proof(withId id: UUID) -> Proof? {
    guard persistedProofIds.contains(id) else { return nil }
    return proofs.first { $0.id == id }
  }

  func hasPersistedProof(withId id: UUID) -> Bool {
    persistedProofIds.contains(id)
  }

  /// A later join may resume once the protected file becomes readable.
  func reloadAfterReadFailure() {
    guard !hasReadableProofs else { return }
    persistenceSuspensionReason = nil
    load()
  }

  /// Updates only the signature lifecycle of an already-stored proof — the
  /// proof's own collected fields are immutable once added. No-op if the
  /// proof was removed since the caller last read it.
  @discardableResult
  func updateSignatureState(for id: UUID, to state: ProofSignatureState) -> Bool {
    guard let index = proofs.firstIndex(where: { $0.id == id }) else { return false }
    var updated = proofs
    updated[index].signatureState = state
    return save(updated)
  }

  /// Updates a recording proof's peer count in place as
  /// `SensingCoordinator` observes more distinct peers — the proof itself
  /// is created once, at the instant `.recording` begins, and never
  /// re-created (`docs/specs/scan-slice2-redesign.md` §4.6). No-op if the
  /// proof was removed since the caller last read it.
  @discardableResult
  func updatePeersVerified(for id: UUID, to peersVerified: Int) -> Bool {
    guard let index = proofs.firstIndex(where: { $0.id == id }) else { return false }
    var updated = proofs
    updated[index].peersVerified = peersVerified
    return save(updated)
  }

  /// Persists the terminal decision before its signing input can be removed.
  func discardSelfProofForKeyChange(
    for id: UUID, reason: EventSigningDiscardReason = .keyChanged, acknowledgedEventCodes: Set<String> = []
  ) throws {
    guard let index = proofs.firstIndex(where: { $0.id == id }) else {
      throw CocoaError(.fileReadNoSuchFile)
    }
    guard !proofs[index].selfProofDiscardedForKeyChange else { return }
    var updated = proofs
    updated[index].selfProofDiscardedForKeyChange = true
    updated[index].selfProofDiscardReason = reason
    let eventCode = updated[index].eventCode
    updated[index].signingKeyChangeNoticeAcknowledged = eventCode.map {
      acknowledgedEventCodes.contains($0) || isSigningKeyChangeAcknowledged(forEventCode: $0)
    } ?? false
    try persistDurably(updated)
  }

  func discardOrphanedSelfProof(_ checkpoint: SelfProofCheckpoint, acknowledgedEventCodes: Set<String>) throws {
    guard hasReadableProofs else { throw CocoaError(.fileReadUnknown) }
    guard !orphanDiscards.contains(where: { $0.proofId == checkpoint.proofId }) else { return }
    let decision = OrphanDiscard(
      proofId: checkpoint.proofId, eventCode: checkpoint.eventCode,
      acknowledged: acknowledgedEventCodes.contains(checkpoint.eventCode)
        || isSigningKeyChangeAcknowledged(forEventCode: checkpoint.eventCode)
    )
    try persistDurably(proofs, orphanDiscards: orphanDiscards + [decision])
  }

  func acknowledgeSigningKeyChanges(forEventCodes eventCodes: Set<String>) throws {
    var updated = proofs
    for index in updated.indices {
      if eventCodes.contains(updated[index].eventCode ?? updated[index].id.uuidString) {
        updated[index].signingKeyChangeNoticeAcknowledged = true
      }
    }
    var updatedOrphanDiscards = orphanDiscards
    for index in updatedOrphanDiscards.indices where eventCodes.contains(updatedOrphanDiscards[index].eventCode) {
      updatedOrphanDiscards[index].acknowledged = true
    }
    guard updated != proofs || updatedOrphanDiscards != orphanDiscards else { return }
    try persistDurably(updated, orphanDiscards: updatedOrphanDiscards)
  }

  func isSigningKeyChangeAcknowledged(forEventCode eventCode: String) -> Bool {
    acknowledgedSigningKeyChangeEventCodes.contains(eventCode)
  }

  var acknowledgedSigningKeyChangeEventCodes: Set<String> {
    Set(proofs.filter(\.signingKeyChangeNoticeAcknowledged).map { $0.eventCode ?? $0.id.uuidString })
      .union(orphanDiscards.filter(\.acknowledged).map(\.eventCode))
  }

  var unacknowledgedSigningKeyChangeEventCodes: Set<String> {
    unacknowledgedSigningDiscardEvents(excludingProofId: nil)
  }

  func unacknowledgedSigningDiscardEvents(excludingProofId proofId: UUID?) -> Set<String> {
    Set(proofs.filter {
      $0.selfProofDiscardedForKeyChange && !$0.signingKeyChangeNoticeAcknowledged && $0.id != proofId
    }.map { $0.eventCode ?? $0.id.uuidString })
      .union(orphanDiscards.filter { !$0.acknowledged && $0.proofId != proofId }.map(\.eventCode))
  }

  func signingDiscardReason(forEventCode eventCode: String) -> EventSigningDiscardReason {
    if orphanDiscards.contains(where: { $0.eventCode == eventCode }) { return .unverifiable }
    let discarded = proofs.filter {
      $0.selfProofDiscardedForKeyChange && ($0.eventCode ?? $0.id.uuidString) == eventCode
    }
    return discarded.allSatisfy { $0.selfProofDiscardReason == .keyChanged } ? .keyChanged : .unverifiable
  }

  private func persistDurably(_ updated: [Proof], orphanDiscards updatedOrphanDiscards: [OrphanDiscard]? = nil) throws {
    if let persistenceSuspensionReason { throw persistenceSuspensionReason }
    let decisions = updatedOrphanDiscards ?? orphanDiscards
    let encodedRecords = try encodeRecords(updated)
    guard var snapshot = try JSONSerialization.jsonObject(with: encodedRecords) as? [String: Any] else {
      throw CocoaError(.coderInvalidValue)
    }
    snapshot["orphanDiscards"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(decisions))
    let data = try JSONSerialization.data(withJSONObject: snapshot)
    try writeData(data, fileURL)
    proofs = updated
    orphanDiscards = decisions
    persistedProofIds = Set(updated.map(\.id))
    hasReadableProofs = true
    lastPersistenceError = nil
  }

  private func load() {
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      proofs = []
      orphanDiscards = []
      persistedProofIds = []
      hasReadableProofs = true
      return
    }
    var loaded: [Proof]
    do {
      let data = try Data(contentsOf: fileURL)
      loaded = try RecordSchemaEnvelope.decodeRecords(Proof.self, from: data)
      orphanDiscards = try JSONDecoder().decode(DiscardMetadata.self, from: data).orphanDiscards
    } catch {
      // A file that fails to decode used to be discarded silently and then
      // destroyed by the next save, taking every stored proof with it
      // (beid#135). Preserve it first, then continue empty.
      let outcome = CorruptStoreQuarantine.resolve(
        loadFailure: error,
        fileURL: fileURL,
        storeDescription: "proof store"
      )
      quarantinedFileURL = outcome.quarantinedFileURL
      persistenceSuspensionReason = outcome.persistenceSuspensionReason
      return
    }

    // `.connecting`/`.awaitingApproval` are only meaningful while this
    // process is alive and actively waiting on a wallet response. If the
    // process was killed mid-wait (e.g. iOS jetsam while the user is
    // backgrounded approving in their wallet app — the prime scenario,
    // since that's exactly what the flow asks the user to do) and the
    // proof reloads still "awaiting approval", there is no live request to
    // ever resolve it: it would spin forever with no retry affordance.
    // Sanitize to `.deferred` on load so it's always retryable, matching
    // the "proof is untouched and safe to retry" contract in
    // `ProofSignature.swift`.
    var didSanitize = false
    for index in loaded.indices {
      switch loaded[index].signatureState {
      case .connecting, .awaitingApproval:
        loaded[index].signatureState = .deferred
        didSanitize = true
      case .notRequested, .signed, .deferred, .rejected, .failed:
        break
      }
    }

    proofs = loaded
    persistedProofIds = Set(loaded.map(\.id))
    hasReadableProofs = true
    if didSanitize {
      save(loaded)
    }
  }

  @discardableResult
  private func save(_ updated: [Proof]) -> Bool {
    if let reason = persistenceSuspensionReason {
      // Preserve the established memory-only fallback, while reporting failure.
      proofs = updated
      lastPersistenceError = reason
      return false
    }
    do {
      try persistDurably(updated)
      return true
    } catch {
      lastPersistenceError = error
      return false
    }
  }

  /// Test-only reset: clears in-memory state and deletes any persisted
  /// file, so a `-beid-ui-test` launch (see `AppCoordinator.init`) starts
  /// from an empty store regardless of what an earlier UI-test run left in
  /// this simulator's installed-app container — beid#244. Proofs
  /// accumulating undetected across independent test launches (each
  /// `app.launch()` reuses one on-disk `proofs.json`) silently changed
  /// which destination `ItemDetailView.participationSummaryRow` rendered,
  /// without failing anything. Not called on a caller-injected `ProofStore`
  /// (unit tests always construct their own via `fileURL:`).
  func resetForUITesting() {
    proofs = []
    orphanDiscards = []
    quarantinedFileURL = nil
    persistenceSuspensionReason = nil
    hasReadableProofs = true
    persistedProofIds = []
    lastPersistenceError = nil
    try? FileManager.default.removeItem(at: fileURL)
  }
}
