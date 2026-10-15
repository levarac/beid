// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import os

/// One closed observation window and the Proof of the session it was closed
/// in (beid#701). `windowId` is the id the window already has everywhere —
/// `ReportSubmissionCapture.id`, `ReportSubmissionRecord.id`,
/// `WindowReport.id` and the ledger window id are all the same value.
/// Nothing else is stored: no time, no event code, no ENIN, no ordinal.
struct ReportProofLink: Codable, Equatable {
  let windowId: UUID
  let proofId: UUID
}

/// No associated values on purpose: logging `String(describing:)` of one of
/// these can never print a window or Proof id.
enum ReportProofLinkStoreError: Error, Equatable {
  case conflictingLink
  case unreadable
}

/// On-device table of which report (window) belongs to which Proof
/// (beid#701, `docs/decisions/issue-701-design.md`).
///
/// Display metadata only. It is deliberately a separate file rather than a
/// field on `ReportSubmissionCapture`/`ReportSubmissionRecord`: those are
/// exact-byte submission state, and a display-only failure here must never
/// be able to latch or block the submission queue. This store is never
/// passed to `ReportSubmissionRuntime`, and nothing in it is signed, sent or
/// published. Native-only for the same reason as `RecordSchemaEnvelope`'s
/// sibling stores: one reader, on one device.
///
/// `SensingCoordinator.closeWindow` is the only writer, at the one moment
/// the link is known for certain. Records written before this file existed
/// stay unlinked forever; nothing infers a link from an event code or ENIN.
///
/// **Deletion rule.** No production path deletes a Proof or a report record
/// today, so this store has no delete API. Any future change that deletes a
/// Proof or a report record must delete the matching link rows in the same
/// change.
///
/// **Backup.** Unlike the other Documents stores (#704 owns that broader
/// question), this file is excluded from device backup (OD-5 (b)). The flag
/// is re-applied after every rename, because the rename replaces the file
/// the flag was set on, and once more after a successful load, so a file
/// left backed up by an earlier failure is corrected on the next launch.
@MainActor
final class ReportProofLinkStore: ObservableObject {
  enum ReadError: Error, Equatable {
    case unreadable
  }

  @Published private(set) var links: [ReportProofLink] = []

  /// True when the most recent attempt to exclude the file from backup
  /// failed, so the table on disk may currently be included in a backup.
  /// Cleared by the next successful attempt.
  private(set) var isBackupExclusionPending = false

  private static let log = Logger(subsystem: "org.levarac.beid", category: "report-links")

  private let fileURL: URL
  private let excludeFromBackup: (URL) throws -> Void
  /// Latched by `load()`. Once set, this instance never writes: replacing an
  /// unreadable file would destroy links that can never be re-derived.
  private var isUnreadable = false

  convenience init(fileURL: URL? = nil) {
    self.init(fileURL: fileURL, excludeFromBackup: ReportProofLinkStore.setExcludedFromBackup)
  }

  /// Test seam for the backup-exclusion failure path.
  init(fileURL: URL?, excludeFromBackup: @escaping (URL) throws -> Void) {
    self.fileURL = fileURL ?? Self.defaultFileURL()
    self.excludeFromBackup = excludeFromBackup
    load()
  }

  private static func defaultFileURL() -> URL {
    let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    return directory.appendingPathComponent("report-proof-links.json")
  }

  private nonisolated static func setExcludedFromBackup(_ url: URL) throws {
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    var mutableURL = url
    try mutableURL.setResourceValues(values)
  }

  /// `nil` means the window is unlinked, which is the answer for every
  /// record written before beid#701. An unreadable file is a failure, never
  /// an authoritative "unlinked".
  func proofId(forWindowId windowId: UUID) -> Result<UUID?, ReadError> {
    guard !isUnreadable else { return .failure(.unreadable) }
    return .success(links.first { $0.windowId == windowId }?.proofId)
  }

  func windowIds(forProofId proofId: UUID) -> Result<Set<UUID>, ReadError> {
    guard !isUnreadable else { return .failure(.unreadable) }
    return .success(Set(links.filter { $0.proofId == proofId }.map(\.windowId)))
  }

  /// Idempotent for the same pair. A different `proofId` for a window that is
  /// already linked throws `conflictingLink` and keeps the stored row.
  func add(windowId: UUID, proofId: UUID) throws {
    guard !isUnreadable else { throw ReportProofLinkStoreError.unreadable }
    if let existing = links.first(where: { $0.windowId == windowId }) {
      guard existing.proofId == proofId else {
        throw ReportProofLinkStoreError.conflictingLink
      }
      return
    }

    let updated = links + [ReportProofLink(windowId: windowId, proofId: proofId)]
    try persist(updated)
    links = updated
    applyBackupExclusion()
  }

  /// Staged write, `fsync`, then `rename`, the same sequence as
  /// `ReportSubmissionStore.persistEncoded`.
  private func persist(_ links: [ReportProofLink]) throws {
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let data = try RecordSchemaEnvelope.encodeRecords(links)
    let stagedURL = fileURL.deletingLastPathComponent().appendingPathComponent(
      ".report-proof-links-\(UUID().uuidString.lowercased()).tmp"
    )
    var stagedFileWasMoved = false
    defer {
      if !stagedFileWasMoved {
        try? FileManager.default.removeItem(at: stagedURL)
      }
    }
    try data.write(to: stagedURL)
    let handle = try FileHandle(forWritingTo: stagedURL)
    try handle.synchronize()
    try handle.close()
    let renameResult = stagedURL.path.withCString { stagedPath in
      fileURL.path.withCString { destinationPath in
        Darwin.rename(stagedPath, destinationPath)
      }
    }
    guard renameResult == 0 else {
      throw NSError(
        domain: NSPOSIXErrorDomain,
        code: Int(errno),
        userInfo: [NSFilePathErrorKey: fileURL.path]
      )
    }
    stagedFileWasMoved = true
  }

  /// A failure here does not fail the write. The link row is already durable
  /// once the rename succeeds, so throwing would tell the caller the link was
  /// not written when it was, and would leave `links` behind the file. The
  /// failure is logged with a fixed string instead, `isBackupExclusionPending`
  /// records it, and the next write or launch tries again.
  private func applyBackupExclusion() {
    do {
      try excludeFromBackup(fileURL)
      isBackupExclusionPending = false
    } catch {
      isBackupExclusionPending = true
      Self.log.error("Unable to exclude the report-to-proof link file from backup")
    }
  }

  private func load() {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
    let decoded: [ReportProofLink]
    do {
      decoded = try RecordSchemaEnvelope.decodeRecords(
        ReportProofLink.self,
        from: Data(contentsOf: fileURL)
      )
    } catch {
      isUnreadable = true
      Self.log.error("Report-to-proof link file is unreadable; links are unavailable and the file is left untouched")
      return
    }
    // Two rows for one window cannot be written by `add`. If they disagree,
    // neither can be trusted, so treat the file as unreadable rather than
    // pick one.
    var proofIdByWindowId: [UUID: UUID] = [:]
    for link in decoded {
      if let existing = proofIdByWindowId[link.windowId], existing != link.proofId {
        isUnreadable = true
        Self.log.error("Report-to-proof link file has conflicting rows; links are unavailable and the file is left untouched")
        return
      }
      proofIdByWindowId[link.windowId] = link.proofId
    }
    links = decoded
    applyBackupExclusion()
  }
}
