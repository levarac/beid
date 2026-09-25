// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import BarnardCore
import BeidSharedKit
import XCTest
@testable import Beid

// MARK: - The promise this file pins
//
// beid#652 made signal strength (RSSI) available to sensing-time DRAWING and
// to NOTHING ELSE. `NodeSignalStrength`'s own doc comment states that as a
// property of the call graph: `SensingCoordinator.handleSignalStrength` is a
// *sibling* of `handleDetection`, never a parameter of it, so no RSSI value
// is ever in lexical scope inside the recording call tree.
//
// THIS FILE IS THE WITNESS THAT THE PROPERTY STILL HOLDS. It does not test
// that the radar feature works — `NodeSignalStrengthTests` does that. Every
// test here is a CONTAINMENT test: it asks whether signal strength has
// escaped into something durable, signed, or sent.
//
// If you are reading this because a test here went red, the most likely
// cause is that a change plumbed RSSI — or a value derived from it, such as
// a bucketed "proximity" byte — into a window report, the unsent-window
// ledger, the window signature input, or the submission payload. That is the
// thing beid#652 exists to prevent. The fix is to take it back out, not to
// relax the assertion. If the containment boundary genuinely has to move,
// that is a decision with a decision record, not a test edit.
//
// Two complementary strategies are used, because each catches what the other
// misses:
//
//   BEHAVIOURAL — drive a realistic session through the real detection path,
//   feed distinctive dBm probes through `handleSignalStrength`, then search
//   the SERIALIZED BYTES of everything the session produced. Searching bytes
//   rather than the typed model is the point: a typed-model check only proves
//   a struct has no such field, while bytes also catch a value smuggled
//   through a dictionary, a free-form metadata bag, or a debug field.
//
//   STRUCTURAL — assert over the key/field names the record, ledger and
//   submission codecs actually EMIT. This goes red the day someone adds
//   `let rssi: Int` to a record type, before any producer ever sets it —
//   i.e. when the door opens, not when someone walks through it.
//
// Every assertion here is written to a single standard: **it must not be
// able to pass by a different accident.** "The ledger contains no -77" is
// green for an empty ledger, an unwritten file, a mistyped path, or a
// session that never observed anything. So every byte search in this file is
// paired with load-bearing POSITIVE assertions — the artifact exists, is
// non-empty, and carries an anchor unique to this session — and every
// structural search is paired with an assertion that the emitted key set is
// the real one. Do not delete those positive assertions to "simplify" a
// test; they are what stops it passing vacuously.

// MARK: - Probes

/// One easily-greppable dBm value fed into the display path, plus every
/// serialized spelling it could plausibly reappear in.
///
/// Values are realistic BLE received powers (strictly negative, as
/// `NodeSignalStrength.measured` requires) but arbitrary enough that finding
/// one in a persisted artifact cannot be coincidence — which
/// `testFixtureActuallyFeedsSignalStrengthAndProbesAppearInNoInput` proves
/// rather than assumes.
private struct ContainmentProbe {
  let dBm: Int

  /// `-77` — a JSON number, or the text of a tab-separated field.
  var decimalText: String { String(dBm) }
  /// `-77.0` — the `Double` the coordinator actually stores in
  /// `NodeSignalStrength.measured(dBm:)`.
  var doubleText: String { String(Double(dBm)) }

  /// The spellings to look for in text. `doubleText` is searched separately
  /// from `decimalText` even though it contains it, so a failure message can
  /// say which form was found.
  var textForms: [String] { [decimalText, doubleText] }

  /// The same spellings after UTF-8 hex encoding, which is how the shared
  /// ledger snapshot codec writes its text fields
  /// (`UnsentWindowLedgerSnapshot.kt`'s `encodeUtf8Hex`). Without this form a
  /// raw text scan of `ledger.snapshot` would silently miss a leaked value:
  /// `-77` is stored there as `2d3737`, which contains no `-` and no `77`
  /// adjacency a reader would notice.
  var hexEncodedTextForms: [String] {
    textForms.map { text in
      text.utf8.map { String(format: "%02x", $0) }.joined()
    }
  }

  /// Byte patterns a binary payload could carry the value as.
  ///
  /// **Binary shapes only. The text spellings are deliberately NOT here, and
  /// must not be added back "for completeness" — that is the bug this comment
  /// exists to prevent recurring.** They were here once and made this suite
  /// flake (observed 2026-09-25). The reason is worth understanding before
  /// touching this:
  ///
  /// `containsValueOccurrence` — which every text search goes through — skips
  /// a match whose next character is another hex digit, because a `UUID`
  /// renders as `A1B2C3D4-84FC-…` and literally contains `-84`. Feeding the
  /// same text spellings through `containsByteSequence` re-checked them as
  /// raw bytes with **no such guard**, so the guarded search passed and the
  /// unguarded one failed on the same text. Reproduced deterministically: for
  /// the id `A1B2C3D4-84FC-4E2A-9B31-0123456789AB`,
  /// `containsValueOccurrence(of: "-84")` is `false` while
  /// `containsByteSequence([0x2D, 0x38, 0x34])` is `true`. The colliding token
  /// is random per run, which is why it passed locally and failed in review.
  ///
  /// The fix was to delete the duplicate rather than teach a second searcher
  /// to be careful, because two guards are two things to keep correct. Nothing
  /// is uncovered by this: `assertNoProbeText` already checks every text
  /// spelling **and** its hex-encoded form, with the guard, and it is applied
  /// beside every use of this property except the signature input — where
  /// `testSignedWindowPayloadIsExactlyItsDeclaredInputsAndNothingElse`
  /// reconstructs the payload byte for byte and so rejects a stray `-84` more
  /// strictly than any search could.
  ///
  /// Also deliberately NOT including the one- or two-byte two's-complement
  /// forms (`0xB3`, `0xFFB3` for -77). RSSI fits in a single byte, so those
  /// are real smuggling shapes — but a lone byte pattern collides by chance
  /// with a 32-byte SHA-256 commitment often enough to make this suite flake,
  /// and a suite that flakes gets deleted. The narrow forms are covered
  /// instead by the same byte-for-byte reconstruction test.
  var byteForms: [[UInt8]] {
    var forms: [[UInt8]] = []
    let wide = Int64(dBm)
    let narrow = Int32(dBm)
    forms.append(withUnsafeBytes(of: wide.bigEndian) { Array($0) })
    forms.append(withUnsafeBytes(of: wide.littleEndian) { Array($0) })
    forms.append(withUnsafeBytes(of: narrow.bigEndian) { Array($0) })
    forms.append(withUnsafeBytes(of: narrow.littleEndian) { Array($0) })
    return forms
  }
}

/// Key-name fragments that would name a signal-strength field, matched
/// case-insensitively against emitted key/field names.
///
/// Note that `signature`, `signatureRHex`, `signedAt` and
/// `deviceSignatureRHex` — real keys on the record types checked below — do
/// not contain any of these. `signal` is `s-i-g-n-a-l`; `signature` is
/// `s-i-g-n-a-t`. If you add a token here, check it against the existing key
/// names first or you will make this suite red for the wrong reason.
private let forbiddenSignalStrengthKeyFragments = ["rssi", "signal", "dbm", "strength"]

// MARK: - Byte / text searching

/// Whether `haystack` contains `needle` other than as the interior of a
/// longer hexadecimal run.
///
/// The guard is not fussiness, it is what stops this suite flaking. A random
/// `UUID` renders as `A1B2C3D4-77FC-…`, which literally contains `-77`; a
/// window report file holds several. A genuine leak never looks like that —
/// a JSON number, a JSON string, or a tab-separated field always terminates
/// the value with a non-hex character (`,` `}` `"` `\t` `\n`). So a match
/// whose very next character is another hex digit is part of a longer hex
/// token, not a value.
///
/// The accepted cost: a leak spelled `-77ab` would be missed. That is not a
/// spelling of the probe, so nothing this suite is looking for is lost.
private func containsValueOccurrence(of needle: String, in haystack: String) -> Bool {
  guard !needle.isEmpty else { return false }
  var searchRange = haystack.startIndex..<haystack.endIndex
  while let found = haystack.range(of: needle, range: searchRange) {
    if found.upperBound == haystack.endIndex || !haystack[found.upperBound].isHexDigit {
      return true
    }
    searchRange = haystack.index(after: found.lowerBound)..<haystack.endIndex
  }
  return false
}

/// Whether `haystack` contains the exact byte sequence `needle`.
private func containsByteSequence(_ needle: [UInt8], in haystack: Data) -> Bool {
  guard !needle.isEmpty, haystack.count >= needle.count else { return false }
  let bytes = [UInt8](haystack)
  let lastStart = bytes.count - needle.count
  var start = 0
  while start <= lastStart {
    if Array(bytes[start..<(start + needle.count)]) == needle {
      return true
    }
    start += 1
  }
  return false
}

/// Every key name appearing anywhere in a decoded JSON value, at any depth.
///
/// Recursive on purpose: a future engineer adding signal strength to a
/// record is at least as likely to nest it under a `diagnostics` or
/// `metadata` object as to put it at the top level, and a top-level-only
/// check would wave that through.
private func allJSONKeys(in object: Any) -> Set<String> {
  var keys: Set<String> = []
  if let dictionary = object as? [String: Any] {
    for (key, value) in dictionary {
      keys.insert(key)
      keys.formUnion(allJSONKeys(in: value))
    }
  } else if let array = object as? [Any] {
    for element in array {
      keys.formUnion(allJSONKeys(in: element))
    }
  }
  return keys
}

/// The field names a tab-separated canonical snapshot emits: the token before
/// the first tab on every non-empty line.
///
/// Reading them out of the codec's actual output — rather than listing them
/// here — is the whole point. A hand-copied field list stops covering new
/// fields the moment one is added, which is precisely the failure this suite
/// exists to prevent.
private func tabSeparatedFieldNames(in snapshotText: String) -> Set<String> {
  var names: Set<String> = []
  for line in snapshotText.split(separator: "\n", omittingEmptySubsequences: true) {
    let name = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)[0]
    names.insert(String(name))
  }
  return names
}

/// UTF-8 hex, the spelling the shared snapshot codecs use for text fields.
private func hexEncodedUTF8(of text: String) -> String {
  text.utf8.map { String(format: "%02x", $0) }.joined()
}

/// Decodes an even-length hex string, or `nil`.
private func dataFromHex(_ hex: String) -> Data? {
  guard hex.count % 2 == 0 else { return nil }
  var bytes: [UInt8] = []
  bytes.reserveCapacity(hex.count / 2)
  var index = hex.startIndex
  while index < hex.endIndex {
    let next = hex.index(index, offsetBy: 2)
    guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
    bytes.append(byte)
    index = next
  }
  return Data(bytes)
}

/// Everything in `snapshotText` that is an even-length hex token, decoded
/// back to text and joined.
///
/// The shared ledger snapshot hex-encodes its text fields, so scanning the
/// file as it sits on disk can only ever find hex. Decoding first is what
/// lets the same decimal probe search cover a value that was written into a
/// hex-encoded field.
private func hexDecodedCorpus(of snapshotText: String) -> String {
  let separators = CharacterSet(charactersIn: "\t\n,")
  let tokens = snapshotText.components(separatedBy: separators)
  var decoded: [String] = []
  for token in tokens where token.count >= 2 && token.count % 2 == 0 {
    guard token.allSatisfy({ $0.isHexDigit }) else { continue }
    guard let data = dataFromHex(token), let text = String(data: data, encoding: .utf8) else {
      continue
    }
    decoded.append(text)
  }
  return decoded.joined(separator: "\n")
}

// MARK: - Submission boundary spy

/// Records exactly what `SensingCoordinator` hands to the submission runtime
/// when a window closes.
///
/// This type conforms to `WindowReportSubmissionRuntimeProtocol` on purpose,
/// and that conformance is itself part of the containment guard: adding an
/// `rssi:` parameter to `captureAndQueueWindow` cannot compile until someone
/// edits this file, at which point they are reading the doc comment at the
/// top of it. The byte searches below cover the other door — a value
/// smuggled through one of the parameters that already exists.
private struct SubmissionCapture {
  let id: UUID
  let eventCode: String
  let eventIdHex: String?
  let enin: Int
  let peerRpids: Set<String>
  let reporterRpid: String?
  let participantCommitment: Data?

  /// Every argument rendered into one searchable text blob, with the field
  /// names included so the key search can see them too.
  var searchableText: String {
    [
      "id=\(id.uuidString)",
      "eventCode=\(eventCode)",
      "eventIdHex=\(eventIdHex ?? "-")",
      "enin=\(enin)",
      "peerRpids=\(peerRpids.sorted().joined(separator: ","))",
      "reporterRpid=\(reporterRpid ?? "-")",
      "participantCommitment=\(participantCommitment.map { $0.map { String(format: "%02x", $0) }.joined() } ?? "-")"
    ].joined(separator: "\n")
  }

  /// The same arguments as raw bytes, so a value that survived as binary
  /// rather than as text is still reachable by a byte search.
  var searchableBytes: Data {
    var data = Data(searchableText.utf8)
    if let participantCommitment {
      data.append(participantCommitment)
    }
    return data
  }
}

@MainActor
private final class SignalStrengthContainmentSubmissionSpy: WindowReportSubmissionRuntimeProtocol {
  private(set) var captures: [SubmissionCapture] = []
  private(set) var submitPendingCallCount = 0

  func captureAndQueueWindow(
    id: UUID,
    eventCode: String,
    eventIdHex: String?,
    enin: Int,
    peerRpids: Set<String>,
    reporterRpid: String?,
    participantCommitment: Data?
  ) {
    captures.append(
      SubmissionCapture(
        id: id,
        eventCode: eventCode,
        eventIdHex: eventIdHex,
        enin: enin,
        peerRpids: peerRpids,
        reporterRpid: reporterRpid,
        participantCommitment: participantCommitment
      )
    )
  }

  func submitPending() {
    submitPendingCallCount += 1
  }

  func submissionState(forEventCode eventCode: String) -> ReportSubmissionState? { nil }

  func excludedWindowCount(forEventCode eventCode: String) -> Int { 0 }
}

// MARK: - Session fixture

/// One dBm probe and the node it was fed to.
private struct ProbedNode {
  let deviceIndex: Int
  let displayId: String
  let probe: ContainmentProbe
}

/// The signature input for one closed window, as the coordinator handed it to
/// the cryptography facade.
private struct SignedWindowPayload {
  let eventCode: String
  let bytes: Data
}

/// Everything one scripted containment session produced.
private struct ContainmentSession {
  let directory: URL
  let eventCode: String
  let enins: [Int]
  let deviceCount: Int
  let reporterRpid: String
  let probedNodes: [ProbedNode]
  /// The per-ENIN RPID sets the fixture fed, sorted exactly the way
  /// `windowReportPayload` sorts them.
  let sortedRpidsByEnin: [Int: [String]]
  /// `signalStrength(forNodeId:)` read for each probed node immediately
  /// before `reset()` — `resetSessionState()` clears the display state, so
  /// after the session there is nothing left to read.
  let measuredBeforeReset: [String: NodeSignalStrength]
  let phaseBeforeReset: ScanPhase
  let signedPayloads: [SignedWindowPayload]
  let reports: [WindowReport]
  let selfProofs: [SelfProofRecord]
  let submissionCaptures: [SubmissionCapture]

  var windowReportsURL: URL { directory.appendingPathComponent("window-reports.json") }
  var selfProofsURL: URL { directory.appendingPathComponent("self-proofs.json") }
  var selfProofCheckpointURL: URL {
    directory.appendingPathComponent("self-proof-checkpoint.json")
  }
  var bindingRecordsURL: URL { directory.appendingPathComponent("binding-records.json") }
  var sessionAggregateSnapshotsURL: URL {
    directory.appendingPathComponent("session-aggregate-snapshots.json")
  }
  var ledgerURL: URL { directory.appendingPathComponent("ledger.snapshot") }

  /// Every string the fixture itself fed into the session. If a probe ever
  /// appeared in one of these, finding that probe in an artifact would prove
  /// nothing — which is what
  /// `testFixtureActuallyFeedsSignalStrengthAndProbesAppearInNoInput` checks.
  var fixtureInputStrings: [String] {
    var strings = [eventCode, reporterRpid]
    strings.append(contentsOf: probedNodes.map(\.displayId))
    strings.append(contentsOf: sortedRpidsByEnin.values.flatMap { $0 })
    strings.append(contentsOf: enins.map(String.init))
    return strings
  }
}

// MARK: - Tests

/// Containment tests for beid#652. See the file header for the promise these
/// pin and for why each byte search is paired with a positive assertion.
@MainActor
final class SignalStrengthNeverRecordedTests: XCTestCase {
  /// The dBm values fed into the display path. One per node, exactly one
  /// sample each, so `handleSignalStrength`'s first-sample seeding makes each
  /// node's published value *equal to its probe* rather than a smoothed blend
  /// — which is what lets the positive assertions below be exact.
  private static let probes = [
    ContainmentProbe(dBm: -77),
    ContainmentProbe(dBm: -63),
    ContainmentProbe(dBm: -41),
    ContainmentProbe(dBm: -59),
    ContainmentProbe(dBm: -84)
  ]

  private static let eventCode = "BEID652-CONTAINMENT-EVENT"
  private static let reporterRpid = "c0ffee00c0ffee00c0ffee00"
  private static let firstEnin = 1
  private static let secondEnin = 2

  // MARK: Fixture

  /// Drives one realistic non-demo session through the real detection path,
  /// interleaving `handleSignalStrength` calls with it, and returns
  /// everything the session produced.
  ///
  /// Scripted rather than randomized so a failure is reproducible, and driven
  /// through `handleDetection`/`handleSignalStrength` rather than Barnard
  /// events because Barnard's event structs have no public initializer
  /// outside their module — the same seam `WindowReportFinalizationTests`
  /// and `SessionAggregateSnapshotPersistHookTests` already use.
  ///
  /// The two ENIN windows are deliberate: the first closes at the ENIN
  /// boundary mid-session and the second at `reset()`, so both the
  /// mid-session and the session-end close paths write artifacts here. The
  /// last probe is fed after the boundary so a sample arriving while a window
  /// is being closed is covered too.
  private func makeContainmentSession() throws -> ContainmentSession {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("beid652-containment-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

    let windowReportStore = WindowReportStore(
      fileURL: directory.appendingPathComponent("window-reports.json")
    )
    let selfProofStore = SelfProofStore(
      fileURL: directory.appendingPathComponent("self-proofs.json")
    )
    let sessionAggregateSnapshotStore = SessionAggregateSnapshotStore(
      fileURL: directory.appendingPathComponent("session-aggregate-snapshots.json")
    )
    let cryptography = DeterministicSensingCryptography()
    let submissionSpy = SignalStrengthContainmentSubmissionSpy()

    let coordinator = SensingCoordinator(
      windowReportStore: windowReportStore,
      selfProofStore: selfProofStore,
      selfProofCheckpointStore: SelfProofCheckpointStore(
        fileURL: directory.appendingPathComponent("self-proof-checkpoint.json")
      ),
      bindingRecordStore: BindingRecordStore(
        fileURL: directory.appendingPathComponent("binding-records.json")
      ),
      sessionAggregateSnapshotStore: sessionAggregateSnapshotStore,
      unsentWindowLedgerFileURL: directory.appendingPathComponent("ledger.snapshot"),
      sensingCryptography: cryptography,
      reportSubmissionRuntime: submissionSpy
    )
    // The real path. Demo mode fabricates its own devices and deliberately
    // produces no window reports, so it would leave this suite with nothing
    // to inspect.
    coordinator.useDemoEventMode = false

    // At least as many devices as probes, and never fewer than the confirm
    // threshold — a session that never reaches `.recording` signs nothing and
    // would make every containment assertion below vacuous.
    let deviceCount = max(BeidConfig.eventConfirmThreshold, Self.probes.count)
    let enins = [Self.firstEnin, Self.secondEnin]
    var sortedRpidsByEnin: [Int: [String]] = [:]
    for enin in enins {
      sortedRpidsByEnin[enin] = (0..<deviceCount)
        .map { DetectionFixture.rotatingRpid(device: $0, enin: enin) }
        .sorted()
    }

    var probedNodes: [ProbedNode] = []
    let sampleClockOrigin = Date(timeIntervalSince1970: 1_800_000_000)

    coordinator.startSensing(eventCode: Self.eventCode)

    // ENIN 1. Each device is detected first, then — and only then — given its
    // probe: `beginEventFoundSessionState` calls `resetSessionState()` on the
    // very first detection, which clears the display state, so a sample fed
    // before that first detection would be wiped and this fixture would
    // quietly stop feeding anything.
    for device in 0..<deviceCount {
      coordinator.handleDetection(
        enin: Self.firstEnin,
        rpid: DetectionFixture.rotatingRpid(device: device, enin: Self.firstEnin),
        detectedDisplayId: DetectionFixture.displayId(device: device),
        reporterRpid: Self.reporterRpid
      )
      guard device < Self.probes.count - 1 else { continue }
      let displayId = DetectionFixture.displayId(device: device)
      coordinator.handleSignalStrength(
        rssi: Self.probes[device].dBm,
        detectedDisplayId: displayId,
        at: sampleClockOrigin.addingTimeInterval(Double(device))
      )
      probedNodes.append(
        ProbedNode(deviceIndex: device, displayId: displayId, probe: Self.probes[device])
      )
    }

    // ENIN 2: the same devices under rotated proximity identifiers. Crossing
    // the boundary closes the first window, signing and persisting it.
    for device in 0..<deviceCount {
      coordinator.handleDetection(
        enin: Self.secondEnin,
        rpid: DetectionFixture.rotatingRpid(device: device, enin: Self.secondEnin),
        detectedDisplayId: DetectionFixture.displayId(device: device),
        reporterRpid: Self.reporterRpid
      )
    }

    // The last probe arrives after the window boundary, on a device that has
    // not been probed yet, so its published value is still exactly the probe.
    let lateDevice = Self.probes.count - 1
    let lateDisplayId = DetectionFixture.displayId(device: lateDevice)
    coordinator.handleSignalStrength(
      rssi: Self.probes[lateDevice].dBm,
      detectedDisplayId: lateDisplayId,
      at: sampleClockOrigin.addingTimeInterval(Double(deviceCount + 10))
    )
    probedNodes.append(
      ProbedNode(
        deviceIndex: lateDevice,
        displayId: lateDisplayId,
        probe: Self.probes[lateDevice]
      )
    )

    var measuredBeforeReset: [String: NodeSignalStrength] = [:]
    for node in probedNodes {
      measuredBeforeReset[node.displayId] = coordinator.signalStrength(forNodeId: node.displayId)
    }
    let phaseBeforeReset = coordinator.phase

    coordinator.reset()

    let signedPayloads = cryptography.calls.compactMap { call -> SignedWindowPayload? in
      guard case let .signWindowReport(eventCode, bytes) = call else { return nil }
      return SignedWindowPayload(eventCode: eventCode, bytes: bytes)
    }

    return ContainmentSession(
      directory: directory,
      eventCode: Self.eventCode,
      enins: enins,
      deviceCount: deviceCount,
      reporterRpid: Self.reporterRpid,
      probedNodes: probedNodes,
      sortedRpidsByEnin: sortedRpidsByEnin,
      measuredBeforeReset: measuredBeforeReset,
      phaseBeforeReset: phaseBeforeReset,
      signedPayloads: signedPayloads,
      reports: windowReportStore.reports,
      selfProofs: selfProofStore.records,
      submissionCaptures: submissionSpy.captures
    )
  }

  // MARK: Shared assertions

  /// Fails if any spelling of any probe appears in `text`.
  private func assertNoProbeText(
    in text: String,
    artifact: String,
    session: ContainmentSession,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    for node in session.probedNodes {
      for form in node.probe.textForms + node.probe.hexEncodedTextForms {
        XCTAssertFalse(
          containsValueOccurrence(of: form, in: text),
          """
          signal strength must never enter a recorded, signed or submitted \
          artifact (beid#652): found \(form) — the dBm fed for node \
          \(node.displayId) — in \(artifact). RSSI is display-only; take it \
          back out rather than relaxing this assertion.
          """,
          file: file,
          line: line
        )
      }
    }
  }

  /// Fails if any key name in `keys` names a signal-strength field.
  private func assertNoSignalStrengthKey(
    in keys: Set<String>,
    artifact: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    for key in keys {
      let lowercased = key.lowercased()
      for fragment in forbiddenSignalStrengthKeyFragments {
        XCTAssertFalse(
          lowercased.contains(fragment),
          """
          \(artifact) emits a field named \(key), which names signal strength \
          (matched "\(fragment)"). beid#652 keeps RSSI out of every record, \
          signature and submission; a field is the door, and this fails the \
          moment the door opens rather than when someone walks through it.
          """,
          file: file,
          line: line
        )
      }
    }
  }

  /// Reads an artifact and asserts it is really there and really this
  /// session's, so a later byte search cannot pass vacuously.
  private func loadArtifact(
    at url: URL,
    anchors: [String],
    artifact: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws -> (text: String, data: Data) {
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: url.path),
      """
      \(artifact) was never written, so every containment assertion over it \
      would pass for the wrong reason (beid#652). The fixture must produce \
      this artifact or this suite protects nothing.
      """,
      file: file,
      line: line
    )
    let data = try Data(contentsOf: url)
    XCTAssertFalse(
      data.isEmpty,
      "\(artifact) is empty; a search over no bytes proves nothing (beid#652)",
      file: file,
      line: line
    )
    let text = try XCTUnwrap(
      String(data: data, encoding: .utf8),
      "\(artifact) is not UTF-8, so this suite cannot search it (beid#652)",
      file: file,
      line: line
    )
    for anchor in anchors {
      XCTAssertTrue(
        text.lowercased().contains(anchor.lowercased()),
        """
        \(artifact) does not contain \(anchor), so this suite is not reading \
        the artifact this session produced (beid#652) — a wrong path or an \
        unwritten file would make every search below pass vacuously.
        """,
        file: file,
        line: line
      )
    }
    return (text, data)
  }

  // MARK: - 1. The fixture is not vacuous

  /// The load-bearing test the rest of this file rests on.
  ///
  /// Every containment assertion here is of the form "X is absent from Y".
  /// That is green for free if the probes were never fed, if the session
  /// never reached `.recording`, if nothing was ever written, or if the probe
  /// values were bound to be absent anyway. This test rules all four out
  /// before any absence is claimed.
  ///
  /// The cheapest wrong implementation it defeats: a `handleSignalStrength`
  /// that silently drops every sample. That version passes every other test
  /// in this file perfectly, and protects nothing.
  func testFixtureActuallyFeedsSignalStrengthAndProbesAppearInNoInput() throws {
    let session = try makeContainmentSession()

    guard case .recording = session.phaseBeforeReset else {
      XCTFail(
        """
        the containment session never reached .recording, so it signed and \
        persisted nothing and every absence assertion in this file would be \
        vacuous (beid#652)
        """
      )
      return
    }

    // The probes really reached the display path, and with their exact
    // values: one sample per node means `handleSignalStrength` seeds the
    // smoother directly, so the published dBm is the probe itself.
    for node in session.probedNodes {
      let measured = try XCTUnwrap(
        session.measuredBeforeReset[node.displayId],
        "node \(node.displayId) was never read back from the display path (beid#652)"
      )
      XCTAssertEqual(
        measured,
        .measured(dBm: Double(node.probe.dBm)),
        """
        node \(node.displayId) never received \(node.probe.dBm) dBm, so \
        asserting that value is absent from the ledger proves nothing \
        (beid#652)
        """
      )
    }

    // The session produced artifacts to search.
    XCTAssertGreaterThanOrEqual(
      session.reports.count,
      1,
      "the containment session persisted no window report (beid#652)"
    )
    XCTAssertEqual(
      session.signedPayloads.count,
      session.reports.count,
      """
      every persisted window report is signed exactly once, so a mismatch \
      means this suite is not looking at the same set of windows the session \
      recorded (beid#652)
      """
    )
    XCTAssertGreaterThanOrEqual(
      session.selfProofs.count,
      1,
      "the containment session produced no self-proof record (beid#652)"
    )
    XCTAssertGreaterThanOrEqual(
      session.submissionCaptures.count,
      1,
      "the containment session queued no window for submission (beid#652)"
    )

    // A probe found in an artifact must be attributable to the display path
    // and to nothing else. If a probe spelling also occurred in an input the
    // fixture feeds, every search in this file would be ambiguous.
    for node in session.probedNodes {
      for form in node.probe.textForms + node.probe.hexEncodedTextForms {
        for input in session.fixtureInputStrings {
          XCTAssertFalse(
            containsValueOccurrence(of: form, in: input),
            """
            the probe spelling \(form) also occurs in the fixture input \
            "\(input)", so finding it in an artifact would not prove signal \
            strength leaked (beid#652). Change the probe value, not the \
            assertion.
            """
          )
        }
      }
    }
  }

  // MARK: - 2. Behavioural containment — the persisted artifacts

  /// The unsent-window ledger, byte for byte.
  ///
  /// The ledger is the surface beid#652 names first, because it is where a
  /// per-window value would most naturally be "just stashed alongside" the
  /// window it belongs to. Its snapshot is searched in two encodings: as it
  /// sits on disk, and again after hex-decoding its fields — the shared codec
  /// hex-encodes text (`UnsentWindowLedgerSnapshot.kt`), so a raw scan alone
  /// would read right past `2d3737` and call it clean.
  ///
  /// Cheapest wrong implementations defeated: an empty or never-written
  /// ledger (the file must exist, be non-empty, and contain this session's
  /// own window ids), and a value hidden inside a hex-encoded field (the
  /// decoded corpus).
  func testLedgerBytesContainNoSignalStrength() throws {
    let session = try makeContainmentSession()

    // Anchor on the hex-encoded window ids of the reports this session
    // persisted: if these are present, this is unambiguously this session's
    // ledger and it really recorded the windows.
    let anchors = session.reports.map {
      hexEncodedUTF8(of: $0.id.uuidString.lowercased())
    }
    XCTAssertFalse(
      anchors.isEmpty,
      "no window ids to anchor the ledger search on (beid#652)"
    )
    let ledger = try loadArtifact(
      at: session.ledgerURL,
      anchors: anchors,
      artifact: "the unsent-window ledger snapshot"
    )

    assertNoProbeText(
      in: ledger.text,
      artifact: "the unsent-window ledger snapshot",
      session: session
    )
    assertNoProbeText(
      in: hexDecodedCorpus(of: ledger.text),
      artifact: "the hex-decoded fields of the unsent-window ledger snapshot",
      session: session
    )
    assertNoSignalStrengthKey(
      in: tabSeparatedFieldNames(in: ledger.text),
      artifact: "the unsent-window ledger snapshot"
    )
  }

  /// Every other file the session wrote: window reports, self-proofs, and the
  /// session aggregate snapshot.
  ///
  /// Searched as bytes rather than through the typed model on purpose. A
  /// typed check proves only that a struct has no such stored property;
  /// searching what was actually written also catches a value smuggled
  /// through a dictionary, a free-form metadata bag, or a debug field that
  /// the type does not advertise.
  ///
  /// Cheapest wrong implementation defeated: reading a path that was never
  /// written. Each file must exist, be non-empty, and carry this session's
  /// event code or proof id.
  func testPersistedRecordBytesContainNoSignalStrength() throws {
    let session = try makeContainmentSession()

    let windowReports = try loadArtifact(
      at: session.windowReportsURL,
      anchors: [session.eventCode],
      artifact: "window-reports.json"
    )
    assertNoProbeText(in: windowReports.text, artifact: "window-reports.json", session: session)

    let selfProofs = try loadArtifact(
      at: session.selfProofsURL,
      anchors: [session.eventCode],
      artifact: "self-proofs.json"
    )
    assertNoProbeText(in: selfProofs.text, artifact: "self-proofs.json", session: session)

    let aggregateAnchors = session.selfProofs.map { $0.proofId.uuidString }
    XCTAssertFalse(
      aggregateAnchors.isEmpty,
      """
      no proof id to anchor the session-aggregate search on, so that search \
      would run without proof it is reading this session's file (beid#652)
      """
    )
    let aggregates = try loadArtifact(
      at: session.sessionAggregateSnapshotsURL,
      anchors: aggregateAnchors,
      artifact: "session-aggregate-snapshots.json"
    )
    assertNoProbeText(
      in: aggregates.text,
      artifact: "session-aggregate-snapshots.json",
      session: session
    )
    assertNoProbeText(
      in: hexDecodedCorpus(of: aggregates.text),
      artifact: "the hex-decoded fields of session-aggregate-snapshots.json",
      session: session
    )

    // Every key name in each JSON artifact, at any nesting depth.
    for (url, name) in [
      (session.windowReportsURL, "window-reports.json"),
      (session.selfProofsURL, "self-proofs.json"),
      (session.sessionAggregateSnapshotsURL, "session-aggregate-snapshots.json")
    ] {
      let data = try Data(contentsOf: url)
      let decoded = try JSONSerialization.jsonObject(with: data)
      let keys = allJSONKeys(in: decoded)
      XCTAssertFalse(
        keys.isEmpty,
        "\(name) decoded to no keys at all, so a key search over it proves nothing (beid#652)"
      )
      assertNoSignalStrengthKey(in: keys, artifact: name)
    }

    // The self-proof checkpoint is deliberately NOT required to exist:
    // `finalizeSelfProofIfNeeded()` clears it once the real record is
    // written. It is still searched when present, because a crash-gap
    // checkpoint is as much a durable record as anything else here.
    if FileManager.default.fileExists(atPath: session.selfProofCheckpointURL.path),
       let data = try? Data(contentsOf: session.selfProofCheckpointURL),
       let text = String(data: data, encoding: .utf8) {
      assertNoProbeText(in: text, artifact: "self-proof-checkpoint.json", session: session)
    }
  }

  // MARK: - 3. Behavioural containment — the signature input

  /// The exact bytes handed to `SensingCryptography.signWindowReport`.
  ///
  /// This is the surface where a leak would be worst: a value that reaches
  /// here is not merely stored, it is attested to by the event signing key.
  ///
  /// Cheapest wrong implementation defeated: a session that signed nothing,
  /// which would make "the signed bytes contain no -77" trivially true.
  func testSignedWindowPayloadBytesContainNoSignalStrength() throws {
    let session = try makeContainmentSession()

    XCTAssertGreaterThanOrEqual(
      session.signedPayloads.count,
      1,
      """
      the containment session signed no window at all, so asserting that the \
      signature input carries no signal strength proves nothing (beid#652)
      """
    )

    for (index, payload) in session.signedPayloads.enumerated() {
      XCTAssertEqual(
        payload.eventCode,
        session.eventCode,
        "signature \(index) was taken over a different session's event (beid#652)"
      )
      XCTAssertFalse(
        payload.bytes.isEmpty,
        "signature input \(index) is empty; a search over no bytes proves nothing (beid#652)"
      )
      for node in session.probedNodes {
        for form in node.probe.byteForms {
          XCTAssertFalse(
            containsByteSequence(form, in: payload.bytes),
            """
            signal strength must never be signed (beid#652): the dBm fed for \
            node \(node.displayId) appears in window signature input \(index). \
            A signed value is attested evidence, not a drawing hint.
            """
          )
        }
      }
    }
  }

  /// The signature input reconstructed byte for byte from its declared
  /// inputs, with nothing left over.
  ///
  /// This is the strictest test in the file and the one that covers what byte
  /// searching structurally cannot. RSSI fits in a single byte, and a lone
  /// byte appended to a payload is indistinguishable from noise to any
  /// search — but not to an exact reconstruction. `windowReportPayload` is
  /// `eventCode ‖ Int64(enin) big-endian ‖ commit ‖ sorted peer RPIDs`, and
  /// the commitment is read back out of the report the same close produced,
  /// so there is no opaque region left for anything to hide in.
  ///
  /// Cheapest wrong implementations defeated: a single RSSI byte appended,
  /// prepended, or interleaved (length and content both change); and an RSSI
  /// folded into the event code or an RPID inside the coordinator, since the
  /// expectation is rebuilt from what the fixture fed rather than from what
  /// the coordinator reported.
  func testSignedWindowPayloadIsExactlyItsDeclaredInputsAndNothingElse() throws {
    let session = try makeContainmentSession()

    XCTAssertGreaterThanOrEqual(session.reports.count, 1, "no window was closed (beid#652)")
    guard session.reports.count == session.signedPayloads.count else {
      XCTFail(
        """
        \(session.reports.count) window reports were persisted but \
        \(session.signedPayloads.count) signatures were taken, so this test \
        cannot pair them and would otherwise inspect the wrong bytes (beid#652)
        """
      )
      return
    }

    for (index, report) in session.reports.enumerated() {
      let payload = session.signedPayloads[index].bytes
      let commit = try XCTUnwrap(
        dataFromHex(report.commitHex),
        "window report \(index) has an undecodable commitment (beid#652)"
      )
      let rpids = try XCTUnwrap(
        session.sortedRpidsByEnin[report.enin],
        """
        window report \(index) is filed under ENIN \(report.enin), which this \
        fixture never drove — the session under test is not the one scripted \
        here (beid#652)
        """
      )

      var expected = Data(session.eventCode.utf8)
      expected.append(
        contentsOf: withUnsafeBytes(of: Int64(report.enin).bigEndian) { Array($0) }
      )
      expected.append(commit)
      for rpid in rpids {
        expected.append(contentsOf: Array(rpid.utf8))
      }

      XCTAssertEqual(
        payload.count,
        expected.count,
        """
        the signed window payload is \(payload.count) bytes where its declared \
        inputs are \(expected.count) (beid#652). Signal strength fits in one \
        byte, so any surplus at all is the thing this test exists to catch.
        """
      )
      XCTAssertEqual(
        payload,
        expected,
        """
        the signed window payload is not exactly \
        "event code ‖ ENIN ‖ commitment ‖ sorted peer RPIDs" (beid#652). \
        Nothing else may be signed, and signal strength least of all.
        """
      )
    }
  }

  // MARK: - 4. Behavioural containment — the submission payload

  /// What the coordinator hands across the submission boundary when a window
  /// closes.
  ///
  /// Note the other half of this guard is the compiler, not an assertion:
  /// `SignalStrengthContainmentSubmissionSpy` conforms to
  /// `WindowReportSubmissionRuntimeProtocol`, so adding an `rssi:` parameter
  /// to `captureAndQueueWindow` cannot build until someone opens this file.
  /// The assertions below cover the remaining door — a value smuggled
  /// through a parameter that already exists.
  ///
  /// Cheapest wrong implementation defeated: a session that queued nothing,
  /// and a spy that recorded nothing — the captured RPID set is checked
  /// against what the fixture actually fed.
  func testSubmissionPayloadBytesContainNoSignalStrength() throws {
    let session = try makeContainmentSession()

    XCTAssertGreaterThanOrEqual(
      session.submissionCaptures.count,
      1,
      """
      no window was ever queued for submission, so asserting that the \
      submission payload carries no signal strength proves nothing (beid#652)
      """
    )

    for (index, capture) in session.submissionCaptures.enumerated() {
      XCTAssertEqual(
        capture.eventCode,
        session.eventCode,
        "submission capture \(index) belongs to another session (beid#652)"
      )
      let expectedRpids = try XCTUnwrap(
        session.sortedRpidsByEnin[capture.enin],
        """
        submission capture \(index) is filed under ENIN \(capture.enin), which \
        this fixture never drove (beid#652)
        """
      )
      XCTAssertEqual(
        capture.peerRpids.sorted(),
        expectedRpids,
        """
        submission capture \(index) does not carry the peers this fixture fed, \
        so searching it for signal strength is searching the wrong thing \
        (beid#652)
        """
      )

      assertNoProbeText(
        in: capture.searchableText,
        artifact: "submission capture \(index)",
        session: session
      )
      for node in session.probedNodes {
        for form in node.probe.byteForms {
          XCTAssertFalse(
            containsByteSequence(form, in: capture.searchableBytes),
            """
            signal strength must never be submitted (beid#652): the dBm fed \
            for node \(node.displayId) appears in submission capture \(index). \
            What leaves the device is evidence about co-presence, not about \
            how loud a radio was.
            """
          )
        }
      }
      assertNoSignalStrengthKey(
        in: Set(
          capture.searchableText
            .split(separator: "\n")
            .map { String($0.split(separator: "=", maxSplits: 1)[0]) }
        ),
        artifact: "submission capture \(index)"
      )
    }
  }

  // MARK: - 5. Structural containment — the record types have nowhere to put it

  /// The encoded key set of every durable record type on the recording,
  /// signing and submission paths.
  ///
  /// This is the test that fails on the day the door opens rather than the
  /// day someone walks through it: adding `let rssi: Int` to any of these
  /// types turns this red immediately, before a single producer sets it and
  /// long before any behavioural test could notice. Keys are read out of what
  /// each codec actually emits — a hand-maintained field list would stop
  /// covering new fields, which is the exact failure this suite exists to
  /// prevent.
  ///
  /// Cheapest wrong implementation defeated: a type whose encoder emits
  /// nothing (or that fails to encode), which would make "no key names signal
  /// strength" true of an empty set. Each type must emit a key known to
  /// belong to it.
  func testPersistedRecordTypesHaveNoFieldNamedForSignalStrength() throws {
    let encoder = JSONEncoder()

    func keys<Record: Encodable>(of record: Record, named name: String) throws -> Set<String> {
      let data = try encoder.encode(record)
      let decoded = try JSONSerialization.jsonObject(with: data)
      let keys = allJSONKeys(in: decoded)
      XCTAssertFalse(
        keys.isEmpty,
        "\(name) encoded to no keys, so a key search over it proves nothing (beid#652)"
      )
      return keys
    }

    let deviceSignature = BarnardCoreRecoverableSignature(
      r: [UInt8](repeating: 1, count: 32),
      s: [UInt8](repeating: 2, count: 32),
      v: 0
    )

    let windowReportKeys = try keys(
      of: WindowReport(
        eventCode: Self.eventCode,
        enin: Self.firstEnin,
        peerCount: 3,
        commit: Data(repeating: 0x0c, count: 32),
        signature: SensingRecoverableSignature(
          r: Data(repeating: 0x11, count: 32),
          s: Data(repeating: 0x22, count: 32),
          v: 0
        )
      ),
      named: "WindowReport"
    )
    XCTAssertTrue(
      windowReportKeys.contains("commitHex"),
      "WindowReport did not encode its own commitment, so this key set is not its real one (beid#652)"
    )
    assertNoSignalStrengthKey(in: windowReportKeys, artifact: "WindowReport")

    let selfProofKeys = try keys(
      of: SelfProofRecord(
        proofId: UUID(),
        eventCode: Self.eventCode,
        eventIdHash: Data(repeating: 0xAB, count: 32),
        eventSigningPublicKey: Data(repeating: 0x02, count: 33),
        eninStart: 100,
        eninEnd: 200,
        ownerPublicKey: Data(repeating: 0x03, count: 33),
        signature: deviceSignature
      ),
      named: "SelfProofRecord"
    )
    XCTAssertTrue(
      selfProofKeys.contains("eventIdHashHex"),
      "SelfProofRecord did not encode its event id hash (beid#652)"
    )
    assertNoSignalStrengthKey(in: selfProofKeys, artifact: "SelfProofRecord")

    let bindingKeys = try keys(
      of: BindingRecord(
        proofId: UUID(),
        eventCode: Self.eventCode,
        walletAddress: "0x0000000000000000000000000000000000000001",
        eventSigningPublicKey: Data(repeating: 0x02, count: 33),
        ownerPublicKey: Data(repeating: 0x03, count: 33),
        chainId: 1,
        nonce: Data(repeating: 0x04, count: 16),
        issuedAt: "2026-01-01T00:00:00Z",
        walletSignatureHex: String(repeating: "0a", count: 65),
        deviceSignature: deviceSignature
      ),
      named: "BindingRecord"
    )
    XCTAssertTrue(
      bindingKeys.contains("walletSignatureHex"),
      "BindingRecord did not encode its wallet signature (beid#652)"
    )
    assertNoSignalStrengthKey(in: bindingKeys, artifact: "BindingRecord")

    let aggregateKeys = try keys(
      of: SessionAggregateSnapshotRecord(
        proofId: UUID(),
        snapshotText: "beid-session-aggregate-snapshot\t1\nend\n"
      ),
      named: "SessionAggregateSnapshotRecord"
    )
    XCTAssertTrue(
      aggregateKeys.contains("proofId"),
      "SessionAggregateSnapshotRecord did not encode its proof id (beid#652)"
    )
    assertNoSignalStrengthKey(in: aggregateKeys, artifact: "SessionAggregateSnapshotRecord")

    let submissionRecordKeys = try keys(
      of: ReportSubmissionRecord(
        id: UUID(),
        eventCode: Self.eventCode,
        endpoint: "https://example.invalid/observations",
        receiptPublicKeyHex: String(repeating: "ab", count: 33),
        eventIdHex: String(repeating: "cd", count: 32),
        eventDefinitionDigestHex: String(repeating: "ef", count: 32),
        validFrom: 1,
        validUntil: 2,
        signedObservationHex: String(repeating: "12", count: 64),
        observationDigestHex: String(repeating: "34", count: 32)
      ),
      named: "ReportSubmissionRecord"
    )
    XCTAssertTrue(
      submissionRecordKeys.contains("signedObservationHex"),
      "ReportSubmissionRecord did not encode its signed observation (beid#652)"
    )
    assertNoSignalStrengthKey(in: submissionRecordKeys, artifact: "ReportSubmissionRecord")

    let captureKeys = try keys(
      of: ReportSubmissionCapture(
        id: UUID(),
        eventCode: Self.eventCode,
        eventIdHex: String(repeating: "cd", count: 32),
        enin: Self.firstEnin,
        peerRpids: ["aa", "bb"],
        reporterRpid: Self.reporterRpid,
        participantCommitment: Data(repeating: 0x0c, count: 32)
      ),
      named: "ReportSubmissionCapture"
    )
    XCTAssertTrue(
      captureKeys.contains("reporterRpid"),
      "ReportSubmissionCapture did not encode its reporter RPID (beid#652)"
    )
    assertNoSignalStrengthKey(in: captureKeys, artifact: "ReportSubmissionCapture")

    let exclusionKeys = try keys(
      of: ReportSubmissionExclusion(
        id: UUID(),
        eventCode: Self.eventCode,
        eventIdHex: String(repeating: "cd", count: 32),
        enin: Self.firstEnin,
        peerCount: 3,
        reasonCode: "legacy-count-only",
        createdAt: Date()
      ),
      named: "ReportSubmissionExclusion"
    )
    XCTAssertTrue(
      exclusionKeys.contains("reasonCode"),
      "ReportSubmissionExclusion did not encode its reason code (beid#652)"
    )
    assertNoSignalStrengthKey(in: exclusionKeys, artifact: "ReportSubmissionExclusion")
  }

  /// The shared unsent-window ledger codec's own emitted field names.
  ///
  /// Read from `encodeUnsentWindowLedgerSnapshot`'s real output — the text
  /// this session's ledger store persisted — rather than from a list written
  /// here, so a field added to the shared ledger in `shared/` is covered the
  /// day it appears, with no iOS-side edit.
  ///
  /// Cheapest wrong implementation defeated: an empty or truncated snapshot,
  /// whose field-name set would contain nothing to object to. The known field
  /// names must all be present.
  func testSharedLedgerSnapshotCodecEmitsNoFieldNamedForSignalStrength() throws {
    let session = try makeContainmentSession()
    let ledger = try loadArtifact(
      at: session.ledgerURL,
      anchors: [],
      artifact: "the unsent-window ledger snapshot"
    )
    let fieldNames = tabSeparatedFieldNames(in: ledger.text)

    for expected in [
      "beid-ledger-snapshot",
      "revision",
      "ledger-id",
      "next-window-sequence",
      "next-report-sequence",
      "windows",
      "window",
      "reports",
      "end"
    ] {
      XCTAssertTrue(
        fieldNames.contains(expected),
        """
        the ledger snapshot emitted no "\(expected)" field, so this is not the \
        codec's real output and a search over its field names proves nothing \
        (beid#652)
        """
      )
    }
    assertNoSignalStrengthKey(
      in: fieldNames,
      artifact: "the shared unsent-window ledger snapshot codec"
    )
  }

  /// The shared window-observation draft codec's own emitted field names.
  ///
  /// The draft is the shared submission-side record type. No iOS production
  /// path builds one today — Android's accumulator does — so no behavioural
  /// test on this platform would ever reveal a field added to it. That is
  /// exactly why it is checked structurally here: a per-window record type
  /// that iOS cannot observe is the easiest place for a signal-strength field
  /// to land unnoticed, and both platforms must keep the same promise.
  ///
  /// Cheapest wrong implementation defeated: a draft that failed to build,
  /// leaving an empty snapshot whose field-name set has nothing to object to.
  func testSharedWindowObservationDraftCodecEmitsNoFieldNamedForSignalStrength() throws {
    let created = BeidSharedKit.report.createWindowObservationDraft(
      windowId: "beid652-containment-window",
      enin: Int64(Self.firstEnin),
      eventCode: Self.eventCode,
      eventIdHex: String(repeating: "ab", count: 32),
      eventDefinitionDigestHex: String(repeating: "cd", count: 32),
      participantCommitmentHex: String(repeating: "ef", count: 32),
      reporterRpidHex: Self.reporterRpid
    )
    XCTAssertTrue(
      created.isSuccess,
      """
      the containment draft was rejected (\(created.errorCode ?? "no code")), so \
      there is no codec output to inspect and this test would pass vacuously \
      (beid#652)
      """
    )
    let draft = try XCTUnwrap(created.draft, "no draft to encode (beid#652)")

    let appended = BeidSharedKit.report.addWindowObservationDraftRpid(
      draft: draft,
      observedRpidHex: "0123456789ab"
    )
    XCTAssertTrue(appended.isSuccess, "the containment draft rejected an observed RPID (beid#652)")
    let populated = try XCTUnwrap(appended.draft, "no populated draft to encode (beid#652)")

    let snapshotText = BeidSharedKit.report.encodeWindowObservationDraftSnapshot(draft: populated)
    XCTAssertFalse(
      snapshotText.isEmpty,
      "the draft codec emitted nothing, so a field-name search proves nothing (beid#652)"
    )

    let fieldNames = tabSeparatedFieldNames(in: snapshotText)
    for expected in [
      "beid-window-observation-draft",
      "window",
      "enin",
      "event-code",
      "event-id",
      "event-definition-digest",
      "participant-commitment",
      "reporter-rpid",
      "observed-rpids",
      "rpid",
      "end"
    ] {
      XCTAssertTrue(
        fieldNames.contains(expected),
        """
        the draft snapshot emitted no "\(expected)" field, so this is not the \
        codec's real output (beid#652)
        """
      )
    }
    assertNoSignalStrengthKey(
      in: fieldNames,
      artifact: "the shared window-observation draft codec"
    )
  }

  // MARK: - 6. Containment of the display path itself

  /// A coordinator driven to `.recording` over an isolated directory, with
  /// nothing fed to the display path yet.
  private struct RecordingFixture {
    let coordinator: SensingCoordinator
    let directory: URL
    let submissionSpy: SignalStrengthContainmentSubmissionSpy
    let windowReportStore: WindowReportStore
    let deviceCount: Int
    let detectedDisplayIds: [String]
  }

  private func makeRecordingFixture(eventCode: String) throws -> RecordingFixture {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("beid652-display-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

    let windowReportStore = WindowReportStore(
      fileURL: directory.appendingPathComponent("window-reports.json")
    )
    let submissionSpy = SignalStrengthContainmentSubmissionSpy()
    let coordinator = SensingCoordinator(
      windowReportStore: windowReportStore,
      selfProofStore: SelfProofStore(
        fileURL: directory.appendingPathComponent("self-proofs.json")
      ),
      selfProofCheckpointStore: SelfProofCheckpointStore(
        fileURL: directory.appendingPathComponent("self-proof-checkpoint.json")
      ),
      bindingRecordStore: BindingRecordStore(
        fileURL: directory.appendingPathComponent("binding-records.json")
      ),
      sessionAggregateSnapshotStore: SessionAggregateSnapshotStore(
        fileURL: directory.appendingPathComponent("session-aggregate-snapshots.json")
      ),
      unsentWindowLedgerFileURL: directory.appendingPathComponent("ledger.snapshot"),
      sensingCryptography: DeterministicSensingCryptography(),
      reportSubmissionRuntime: submissionSpy
    )
    coordinator.useDemoEventMode = false

    let deviceCount = max(BeidConfig.eventConfirmThreshold, 3)
    var detectedDisplayIds: [String] = []
    coordinator.startSensing(eventCode: eventCode)
    for device in 0..<deviceCount {
      let displayId = DetectionFixture.displayId(device: device)
      detectedDisplayIds.append(displayId)
      coordinator.handleDetection(
        enin: Self.firstEnin,
        rpid: DetectionFixture.rotatingRpid(device: device, enin: Self.firstEnin),
        detectedDisplayId: displayId,
        reporterRpid: Self.reporterRpid
      )
    }

    return RecordingFixture(
      coordinator: coordinator,
      directory: directory,
      submissionSpy: submissionSpy,
      windowReportStore: windowReportStore,
      deviceCount: deviceCount,
      detectedDisplayIds: detectedDisplayIds
    )
  }

  /// The four scalars a session's counting is made of, so they can be
  /// compared before and after a burst of signal strength.
  private struct SessionCounts: Equatable {
    let devicesVerified: Int
    let unidentifiedRpidCount: Int
    let aggregateDeviceCount: Int
    let aggregateWindowCount: Int
    let aggregateMutualDeviceCount: Int
    let aggregateMutualObservationCount: Int

    @MainActor
    init(_ coordinator: SensingCoordinator) {
      devicesVerified = coordinator.devicesVerified
      unidentifiedRpidCount = coordinator.unidentifiedRpidCount
      aggregateDeviceCount = Int(coordinator.sessionAggregate?.deviceCount ?? -1)
      aggregateWindowCount = Int(coordinator.sessionAggregate?.windowCount ?? -1)
      aggregateMutualDeviceCount = Int(coordinator.sessionAggregate?.mutualDeviceCount ?? -1)
      aggregateMutualObservationCount =
        Int(coordinator.sessionAggregate?.mutualObservationCount ?? -1)
    }
  }

  /// Signal strength moves the drawing and nothing else.
  ///
  /// `devicesVerified`, `unidentifiedRpidCount`, the session aggregate and
  /// the scan phase are the session's *decisions*. A sample arriving must
  /// leave every one of them exactly where it was — a radius is not evidence
  /// that a device was there, and must never be allowed to become a reason to
  /// count one.
  ///
  /// Cheapest wrong implementation defeated: a `handleSignalStrength` that
  /// early-returns on everything. It would leave all this state untouched and
  /// pass — which is why the burst is required to have visibly changed the
  /// display state that it *is* allowed to change.
  func testHandleSignalStrengthMovesNoSessionCountsOrScanPhase() throws {
    let fixture = try makeRecordingFixture(eventCode: "BEID652-DISPLAY-ONLY-EVENT")
    let coordinator = fixture.coordinator

    guard case .recording = coordinator.phase else {
      XCTFail("expected .recording before feeding signal strength (beid#652)")
      return
    }
    let countsBefore = SessionCounts(coordinator)
    let phaseBefore = coordinator.phase
    XCTAssertTrue(
      coordinator.nodeSignalStrengths.isEmpty,
      """
      the fixture published a signal strength before this test fed one, so a \
      later change cannot be attributed to the burst (beid#652)
      """
    )

    // A realistic burst: several samples per node, spread over event time so
    // both the coalesced and the immediate republish paths run.
    let origin = Date(timeIntervalSince1970: 1_800_000_000)
    var elapsed = 0.0
    for round in 0..<4 {
      for (index, displayId) in fixture.detectedDisplayIds.enumerated() {
        elapsed += 0.4
        coordinator.handleSignalStrength(
          rssi: Self.probes[(round + index) % Self.probes.count].dBm,
          detectedDisplayId: displayId,
          at: origin.addingTimeInterval(elapsed)
        )
      }
    }

    // The burst was real: the display state it is allowed to move did move.
    XCTAssertFalse(
      coordinator.nodeSignalStrengths.isEmpty,
      """
      no signal strength was published at all, so this test's "nothing else \
      moved" assertions hold for the wrong reason (beid#652)
      """
    )
    for displayId in fixture.detectedDisplayIds {
      guard case .measured = coordinator.signalStrength(forNodeId: displayId) else {
        XCTFail(
          """
          node \(displayId) never became .measured, so the burst this test \
          relies on did not happen (beid#652)
          """
        )
        return
      }
    }

    // And nothing that decides anything moved with it.
    XCTAssertEqual(
      SessionCounts(coordinator),
      countsBefore,
      """
      signal strength changed this session's counting (beid#652). RSSI is \
      display-only: it may move a radius, never a device count, an \
      unidentified-RPID tally, or the session aggregate.
      """
    )
    XCTAssertEqual(
      coordinator.phase,
      phaseBefore,
      """
      signal strength changed the scan phase (beid#652). Phase transitions \
      belong to BeidSharedKit.sensing and to detections; a radio's loudness \
      is not a reason to confirm, lose, or end an event.
      """
    )
  }

  /// A strength for a display id no detection ever introduced creates
  /// nothing.
  ///
  /// The tempting shortcut this forbids is "the node is on screen, so give it
  /// a row". An RSSI sample is not attribution: it says a radio was audible,
  /// not that a beid device was verified. A device that exists only because
  /// it was loud would be counted, recorded, signed and submitted on no
  /// evidence at all.
  ///
  /// Cheapest wrong implementation defeated: a `handleSignalStrength` that
  /// ignores the phantom id entirely. It would create nothing and pass — so
  /// the phantom node is required to have become `.measured`, proving the
  /// sample was accepted and still produced no record.
  func testSignalStrengthForUndetectedDisplayIdCreatesNoRecordedDevice() throws {
    let fixture = try makeRecordingFixture(eventCode: "BEID652-PHANTOM-NODE-EVENT")
    let coordinator = fixture.coordinator
    let phantomDisplayId = "deadbeef"
    XCTAssertFalse(
      fixture.detectedDisplayIds.contains(phantomDisplayId),
      "the phantom id must be one no detection introduced (beid#652)"
    )

    let countsBefore = SessionCounts(coordinator)
    let phaseBefore = coordinator.phase
    let probe = Self.probes[0]

    let origin = Date(timeIntervalSince1970: 1_800_000_000)
    coordinator.handleSignalStrength(
      rssi: probe.dBm,
      detectedDisplayId: phantomDisplayId,
      at: origin
    )

    // The sample was accepted — so what follows is a statement about
    // containment, not about the call having been ignored.
    XCTAssertEqual(
      coordinator.signalStrength(forNodeId: phantomDisplayId),
      .measured(dBm: Double(probe.dBm)),
      """
      the phantom node's sample was never accepted, so "it created no device" \
      holds for the wrong reason (beid#652)
      """
    )

    XCTAssertEqual(
      SessionCounts(coordinator),
      countsBefore,
      """
      a signal strength for a display id no detection ever introduced changed \
      this session's counting (beid#652). Being audible is not being verified.
      """
    )
    XCTAssertEqual(coordinator.phase, phaseBefore, "a phantom node changed the scan phase (beid#652)")

    coordinator.reset()

    let reports = fixture.windowReportStore.reports
    XCTAssertGreaterThanOrEqual(
      reports.count,
      1,
      "the phantom-node session persisted no window report, so there is nothing to inspect (beid#652)"
    )
    for (index, report) in reports.enumerated() {
      XCTAssertEqual(
        report.peerCount,
        fixture.deviceCount,
        """
        window report \(index) counts \(report.peerCount) peers where only \
        \(fixture.deviceCount) were ever detected (beid#652) — a node known \
        only by its signal strength must never become a recorded peer.
        """
      )
    }
    for (index, capture) in fixture.submissionSpy.captures.enumerated() {
      XCTAssertFalse(
        capture.searchableText.contains(phantomDisplayId),
        """
        submission capture \(index) names a node introduced only by a signal \
        strength sample (beid#652)
        """
      )
    }

    // The phantom node's identity must not have reached any durable artifact
    // either — not as a device, and not as a stray key.
    for name in [
      "window-reports.json",
      "self-proofs.json",
      "session-aggregate-snapshots.json",
      "ledger.snapshot"
    ] {
      let url = fixture.directory.appendingPathComponent(name)
      guard FileManager.default.fileExists(atPath: url.path),
            let data = try? Data(contentsOf: url),
            let text = String(data: data, encoding: .utf8)
      else {
        continue
      }
      XCTAssertFalse(
        text.lowercased().contains(phantomDisplayId),
        "\(name) names a node that only ever had a signal strength (beid#652)"
      )
      XCTAssertFalse(
        hexDecodedCorpus(of: text).lowercased().contains(phantomDisplayId),
        """
        \(name) carries, hex-encoded, a node that only ever had a signal \
        strength (beid#652)
        """
      )
    }
  }
}
