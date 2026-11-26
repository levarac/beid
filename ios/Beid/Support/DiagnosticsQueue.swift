// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import Foundation

struct DiagnosticsQueuedBatch: Equatable {
  let id: UUID
  let body: Data
}

/// Owned by the diagnostics controller and called serially on the main actor.
final class DiagnosticsQueue {
  enum Failure: Error {
    case invalidTrialCode
  }

  private struct Consent: Codable {
    let trial: DiagnosticsTrial
    let debugID: UUID
    var nextSequence: Int64 = 1
    var dropped: Int64 = 0
  }

  private struct StoredBatch {
    let batch: DiagnosticsQueuedBatch
    let createdAt: Int64
    let firstSequence: Int64
    let eventCount: Int
    let previouslyDropped: Int64
  }

  private struct Draft {
    var wire: DiagnosticsWireBatch
    let envelopeBytes: Int
    var eventBytes = 0

    func fits(eventSize: Int, limit: Int) -> Bool {
      envelopeBytes + eventBytes + wire.events.count + eventSize <= limit
    }
  }

  static let batchByteLimit = 32 * 1024
  static let queueByteLimit = 2 * 1024 * 1024
  static let maxAgeMilliseconds: Int64 = 24 * 60 * 60 * 1_000

  private let directory: URL
  private let metadata: DiagnosticsMetadata
  private let batchByteLimit: Int
  private let queueByteLimit: Int
  private let maxAgeMilliseconds: Int64
  private let clock: () -> DiagnosticsTimestamp
  private let encoder = JSONEncoder()
  private let files: FileManager
  private var consent: Consent?
  private var pending: [StoredBatch] = []
  private var draft: Draft?
  private var clockCorrection: DiagnosticsClockCorrection?

  var isEnabled: Bool { consent != nil }
  var generation: UUID? { consent?.debugID }
  var hasSealedBatch: Bool { !pending.isEmpty }
  private var consentURL: URL { directory.appendingPathComponent("consent.json") }

  func alias(forRpid rpid: String) -> DiagnosticsAlias? { consent?.trial.alias(forRpid: rpid) }

  init(
    directory: URL, metadata: DiagnosticsMetadata = .init(),
    batchByteLimit: Int = DiagnosticsQueue.batchByteLimit,
    queueByteLimit: Int = DiagnosticsQueue.queueByteLimit,
    maxAgeMilliseconds: Int64 = DiagnosticsQueue.maxAgeMilliseconds,
    fileManager: FileManager = .default,
    clock: @escaping () -> DiagnosticsTimestamp = DiagnosticsTimestamp.now
  ) {
    self.directory = directory
    self.metadata = metadata
    self.batchByteLimit = batchByteLimit
    self.queueByteLimit = queueByteLimit
    self.maxAgeMilliseconds = maxAgeMilliseconds
    self.clock = clock
    files = fileManager
    encoder.outputFormatting = [.sortedKeys]
    if let data = try? Data(contentsOf: consentURL),
      let saved = try? JSONDecoder().decode(Consent.self, from: data)
    {
      consent = saved
      restoreBatches(for: saved.debugID)
      prune(now: clock().wall, incomingBytes: 0)
    }
  }

  func enable(code: String) throws {
    guard let trial = DiagnosticsTrial(code: code) else { throw Failure.invalidTrialCode }
    try revoke()
    try files.createDirectory(at: directory, withIntermediateDirectories: true)
    var storage = directory
    var properties = URLResourceValues()
    properties.isExcludedFromBackup = true
    try storage.setResourceValues(properties)
    let newConsent = Consent(trial: trial, debugID: UUID())
    try persist(newConsent)
    consent = newConsent
  }

  func revoke() throws {
    consent = nil
    draft = nil
    pending.removeAll()
    clockCorrection = nil
    // Remove the authority to restore the trial before removing its batches.
    do {
      try removeIfPresent(consentURL)
    } catch {
      // The directory can refuse unlinking even when the file is writable.
      // Empty the consent record so a restart cannot decode the old grant.
      let file = try FileHandle(forWritingTo: consentURL)
      defer { try? file.close() }
      try file.truncate(atOffset: 0)
      try file.synchronize()
      throw error
    }
    try removeIfPresent(directory)
  }

  func setClockCorrection(_ correction: DiagnosticsClockCorrection?) {
    guard isEnabled, correction != clockCorrection else { return }
    seal()
    clockCorrection = correction
  }

  @discardableResult
  func record(_ observation: DiagnosticsObservation) -> Bool {
    guard let current = consent else { return false }
    let timestamp = clock()
    if let correction = clockCorrection, !correction.isUsable(at: timestamp) {
      setClockCorrection(nil)
    }
    guard let event = DiagnosticsWireEvent(
      observation, sequence: current.nextSequence, timestamp: timestamp, trial: current.trial
    ), let encodedEvent = try? encoder.encode(event) else { return false }
    if let draft,
      timestamp.needsNewAnchor(relativeTo: draft.wire.anchor) || !draft.fits(eventSize: encodedEvent.count, limit: batchByteLimit)
    {
      seal()
    }
    guard let current = consent else { return false }
    if draft == nil {
      let batch = DiagnosticsWireBatch(
        runID: current.trial.runID, debugID: current.debugID, metadata: metadata,
        anchor: timestamp, correction: clockCorrection, droppedEvents: current.dropped
      )
      guard let envelope = try? encoder.encode(batch) else { return false }
      // Reserve space for the largest nonnegative count after queue eviction.
      let reservedBytes = String(Int64.max).count - String(current.dropped).count
      draft = Draft(wire: batch, envelopeBytes: envelope.count + reservedBytes)
    }
    consent?.nextSequence += 1
    guard draft?.fits(eventSize: encodedEvent.count, limit: batchByteLimit) == true else {
      consent?.dropped += 1
      return false
    }
    draft?.wire.events.append(event)
    draft?.eventBytes += encodedEvent.count
    return true
  }

  func nextBatch(sealingDraft: Bool = true) -> DiagnosticsQueuedBatch? {
    guard isEnabled else { return nil }
    if sealingDraft { seal() }
    let now = clock().wall
    prune(now: now, incomingBytes: 0)
    return pending.first { now - $0.createdAt < maxAgeMilliseconds }?.batch
  }

  @discardableResult
  func removeBatch(_ id: UUID) -> Bool {
    guard let index = pending.firstIndex(where: { $0.batch.id == id }) else { return true }
    do {
      try removeIfPresent(batchURL(id))
      pending.remove(at: index)
      return true
    } catch {
      // A later request can retry the exact same bytes.
      return false
    }
  }

  func seal() {
    guard var batch = draft?.wire, let first = batch.events.first else { return }
    draft = nil
    guard consent != nil else { return }
    let now = clock().wall
    guard now - batch.anchor.wall < maxAgeMilliseconds,
      let estimated = try? encoder.encode(batch), estimated.count <= queueByteLimit
    else {
      consent?.dropped += Int64(batch.events.count)
      saveConsent()
      return
    }
    let reserved = String(Int64.max).count - String(batch.droppedEvents).count
    prune(now: now, incomingBytes: estimated.count + reserved)
    guard var updated = consent else { return }
    batch.droppedEvents = updated.dropped
    do {
      let body = try encoder.encode(batch)
      guard body.count <= batchByteLimit, body.count <= queueByteLimit,
        pending.reduce(body.count, { $0 + $1.batch.body.count }) <= queueByteLimit
      else {
        updated.dropped += Int64(batch.events.count)
        consent = updated
        saveConsent()
        return
      }
      // Persist the allocation before a new batch can survive a crash.
      try persist(updated)
      try write(body, to: batchURL(batch.batchID))
      pending.append(StoredBatch(
        batch: DiagnosticsQueuedBatch(id: batch.batchID, body: body), createdAt: batch.anchor.wall,
        firstSequence: first.seq, eventCount: batch.events.count, previouslyDropped: batch.droppedEvents
      ))
      updated.dropped = 0
      consent = updated
      saveConsent()
    } catch {
      consent?.dropped += Int64(batch.events.count)
      saveConsent()
    }
  }

  private func prune(now: Int64, incomingBytes: Int) {
    let currentCount = pending.count
    var bytes = pending.reduce(incomingBytes, { $0 + $1.batch.body.count })
    var index = 0
    while index < pending.count {
      let stored = pending[index]
      if bytes <= queueByteLimit && now - stored.createdAt < maxAgeMilliseconds {
        index += 1
        continue
      }
      do {
        try removeIfPresent(batchURL(stored.batch.id))
        pending.remove(at: index)
        bytes -= stored.batch.body.count
        consent?.dropped += Int64(stored.eventCount) + stored.previouslyDropped
      } catch {
        // An unreadable/undeletable expired batch is never sent.
        index += 1
      }
    }
    if pending.count != currentCount { saveConsent() }
  }

  private func restoreBatches(for debugID: UUID) {
    let urls = (try? files.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
    pending = urls.compactMap { url in
      let name = url.deletingPathExtension().lastPathComponent
      guard url.pathExtension == "json", let id = UUID(uuidString: name),
        let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= batchByteLimit,
        let data = try? Data(contentsOf: url),
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
        json["batch_id"] as? String == id.uuidString.lowercased(),
        json["debug_id"] as? String == debugID.uuidString.lowercased(),
        let clock = json["clock_sync"] as? [String: Any], let wall = clock["wall_ms"] as? Int64,
        let events = json["events"] as? [[String: Any]],
        let first = events.first?["seq"] as? Int64,
        let dropped = json["dropped_events"] as? Int64
      else { return nil }
      return StoredBatch(
        batch: DiagnosticsQueuedBatch(id: id, body: data), createdAt: wall, firstSequence: first,
        eventCount: events.count, previouslyDropped: dropped
      )
    }.sorted { $0.firstSequence < $1.firstSequence }
  }

  private func batchURL(_ id: UUID) -> URL {
    directory.appendingPathComponent(id.uuidString.lowercased()).appendingPathExtension("json")
  }

  private func saveConsent() {
    guard let consent else { return }
    try? persist(consent)
  }

  private func persist(_ consent: Consent) throws {
    try write(encoder.encode(consent), to: consentURL)
  }

  private func write(_ data: Data, to url: URL) throws {
    #if os(iOS)
    try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    #else
    try data.write(to: url, options: .atomic)
    #endif
  }

  private func removeIfPresent(_ url: URL) throws {
    do {
      try files.removeItem(at: url)
    } catch let error as CocoaError where error.code == .fileNoSuchFile {
      return
    }
  }
}
