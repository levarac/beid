// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import Foundation

/// Generic, file-level version envelope for the proof-bearing on-device
/// JSON stores this project treats as one group (`ProofStore`,
/// `BindingRecordStore`, `SelfProofStore`, `SelfProofCheckpointStore` —
/// beid#155, beid#135).
///
/// ## Why native Swift, not a `shared/` KMP family
///
/// `docs/kmp-shared-foundation.md`'s ownership boundary puts a persistence
/// format in `shared/` when both iOS and Android must produce the same
/// answer for it (see e.g. `UnsentWindowLedgerSnapshot.kt`, shared for
/// exactly that reason). These four files have only one reader today, and
/// the foundation manual's family ledger does not list these types at all —
/// starting a new shared family inside a bug-fix PR would violate that
/// manual's §1 classify-before-code process, not follow it. The trigger is
/// worded by cause, not by a proxy for it: a second platform independently
/// persisting its own binding/self-proof records, in its own format, on its
/// own device (as Android now does) is a second platform, not a second
/// reader of these exact bytes — it does not, by itself, trip this
/// condition. Revisit this placement, starting with that §1 classification
/// process rather than with code, when either becomes true: (a) cross-device
/// sync of these stores (beid#198 — device-to-device data-ownership sync
/// policy, decided but unimplemented) lands, or (b) device-migration
/// backup/restore (dispatch#23) ships — either is a different build, on
/// different hardware, actually reading these same persisted bytes, which
/// is the actual trigger for `shared/` ownership.
///
/// ## Direction this solves
///
/// This makes **new code able to read an old file** (forward migration)
/// only. It does not attempt the reverse: an *older* build surviving a file
/// a *newer* build wrote (e.g. one already containing an enum case this
/// build does not know). That reverse direction is not live today — there
/// is no supported app-downgrade path, and no cross-device sync of these
/// four stores exists yet. If cross-device sync (beid#198) ships, that
/// direction becomes live, and this envelope alone will not cover it: it
/// would need forward-compatible tolerant decoding (e.g. an unknown enum
/// case mapped to an explicit fallback rather than thrown) or a
/// minimum-supported-file-version gate, neither of which exists here.
///
/// ## Not the same tool as a filename-version bump
///
/// `BindingRecordStore` separately uses a *filename* bump
/// (`binding-records.json` → `binding-records-v2.json`, DECISIONS
/// 2026-08-03) to deliberately orphan records that were cryptographically
/// meaningless under the old scheme — those old bytes must never be read as
/// valid again. This envelope is the opposite tool: for data that is merely
/// old but still valid, worth migrating forward rather than discarding.
/// Pick the filename bump, not this envelope, when old records must never
/// be treated as valid; pick this envelope when they still are.
enum RecordSchemaEnvelope {
  static let currentSchemaVersion = 1

  /// A file whose `schemaVersion` this build does not recognize.
  ///
  /// Deliberately **not** a `DecodingError` conformance, even though it is
  /// only ever thrown from inside a decode path. `CorruptStoreQuarantine
  /// .resolve` branches on `loadFailure is DecodingError`: true means
  /// "corrupt — quarantine it," false means "unreadable for some other
  /// reason — leave it in place and suspend writes." An unrecognized
  /// `schemaVersion` is neither corruption nor guaranteed garbage: it could
  /// equally be a file a newer, not-yet-existing build wrote (for example
  /// after a downgrade), which this build simply doesn't understand yet.
  /// We cannot tell that case apart from "the schemaVersion field itself
  /// got corrupted," so this type is routed to the *unpreserved* branch on
  /// purpose. Quarantining would rename the file aside and permanently
  /// orphan it at a `.corrupt-<timestamp>` sibling path — no future build,
  /// including one that *does* understand this version, would ever find it
  /// at the canonical path again. Leaving it in place costs nothing extra:
  /// the user-visible outcome (records read as empty for this launch) is
  /// identical either way, since neither branch populates the in-memory
  /// array — but leaving it in place preserves the chance that a future
  /// build reads it correctly.
  struct UnsupportedSchemaVersion: Error {
    let schemaVersion: Int
  }

  private struct Header: Decodable {
    let schemaVersion: Int
  }

  private struct RecordsEnvelope<T: Codable>: Codable {
    let schemaVersion: Int
    let records: [T]
  }

  private struct RecordEnvelope<T: Codable>: Codable {
    let schemaVersion: Int
    let record: T
  }

  /// Decodes an array-of-records store's file, understanding both today's
  /// versioned envelope (`{"schemaVersion":1,"records":[...]}`) and every
  /// legacy, unversioned file already on a device (a bare `[...]` array
  /// with no `schemaVersion` key at all).
  static func decodeRecords<T: Codable>(_ type: T.Type, from data: Data) throws -> [T] {
    if let header = try? JSONDecoder().decode(Header.self, from: data) {
      switch header.schemaVersion {
      case 1:
        return try JSONDecoder().decode(RecordsEnvelope<T>.self, from: data).records
      default:
        throw UnsupportedSchemaVersion(schemaVersion: header.schemaVersion)
      }
    }
    return try JSONDecoder().decode([T].self, from: data)
  }

  static func encodeRecords<T: Codable>(_ records: [T]) throws -> Data {
    try JSONEncoder().encode(RecordsEnvelope(schemaVersion: currentSchemaVersion, records: records))
  }

  /// Decodes a single-optional-record store's file (`SelfProofCheckpointStore`),
  /// understanding both today's versioned envelope
  /// (`{"schemaVersion":1,"record":{...}}`) and the legacy, unversioned file
  /// (a bare `{...}` object with no `schemaVersion` key).
  static func decodeRecord<T: Codable>(_ type: T.Type, from data: Data) throws -> T {
    if let header = try? JSONDecoder().decode(Header.self, from: data) {
      switch header.schemaVersion {
      case 1:
        return try JSONDecoder().decode(RecordEnvelope<T>.self, from: data).record
      default:
        throw UnsupportedSchemaVersion(schemaVersion: header.schemaVersion)
      }
    }
    return try JSONDecoder().decode(T.self, from: data)
  }

  static func encodeRecord<T: Codable>(_ record: T) throws -> Data {
    try JSONEncoder().encode(RecordEnvelope(schemaVersion: currentSchemaVersion, record: record))
  }
}
