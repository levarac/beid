// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import BeidSharedKit
import XCTest
@testable import Beid

// MARK: - The promise this file pins
//
// beid#653 stores, per record, which peer was present in which window, under
// a random per-record token. The owner authorized that ON THE DEVICE ONLY
// (DECISIONS 2026-09-27, line (a)): the tokens and the presence must never
// reach a window report, the unsent-window ledger, a signature input, the
// submission payload, any other store, or a backup. The display ids the
// tokens stand in for must not be persisted anywhere at all.
//
// THIS FILE IS THE WITNESS. It is modelled on
// `SignalStrengthNeverRecordedTests` (beid#652) and follows the same two
// strategies and the same standard:
//
//   BEHAVIOURAL — drive a real session through `handleDetection`, read the
//   tokens back out of the presence store, then search the SERIALIZED BYTES
//   of everything else the session produced for every token and every
//   display id, in text and hex form.
//
//   STRUCTURAL — assert over the field names the presence codec and record
//   actually emit, over the store's error type, and over the app source.
//
// Every absence assertion is paired with a positive anchor (the artifact
// exists, is non-empty, and belongs to this session), because "the ledger
// contains no token" is also true of an unwritten ledger.
//
// If a test here goes red, the fix is to take the presence data back out of
// wherever it went, not to relax the assertion (docs/decisions/
// issue-653-design.md §3).

// MARK: - Helpers

/// Whether `haystack` contains `needle` other than as the interior of a
/// longer hexadecimal run (the UUID lesson of
/// `SignalStrengthNeverRecordedTests.containsValueOccurrence`). Used for the
/// 8-character display ids, which could otherwise match a random hex run by
/// chance. Tokens are 32 characters, so they are searched without a guard:
/// a guard could only hide a real leak concatenated into a longer field.
private func containsValueOccurrence(of needle: String, in haystack: String) -> Bool {
  guard !needle.isEmpty else { return false }
  let lowered = haystack.lowercased()
  let target = needle.lowercased()
  var searchRange = lowered.startIndex..<lowered.endIndex
  while let found = lowered.range(of: target, range: searchRange) {
    let before = found.lowerBound == lowered.startIndex
      ? nil : lowered[lowered.index(before: found.lowerBound)]
    let after = found.upperBound == lowered.endIndex ? nil : lowered[found.upperBound]
    if !(before?.isHexDigit ?? false) && !(after?.isHexDigit ?? false) {
      return true
    }
    searchRange = lowered.index(after: found.lowerBound)..<lowered.endIndex
  }
  return false
}

private func containsByteSequence(_ needle: [UInt8], in haystack: Data) -> Bool {
  guard !needle.isEmpty, haystack.count >= needle.count else { return false }
  let bytes = [UInt8](haystack)
  var start = 0
  while start <= bytes.count - needle.count {
    if Array(bytes[start..<(start + needle.count)]) == needle {
      return true
    }
    start += 1
  }
  return false
}

private func hexEncodedUTF8(of text: String) -> String {
  text.utf8.map { String(format: "%02x", $0) }.joined()
}

private func dataFromHex(_ hex: String) -> Data? {
  guard hex.count % 2 == 0 else { return nil }
  var bytes: [UInt8] = []
  var index = hex.startIndex
  while index < hex.endIndex {
    let next = hex.index(index, offsetBy: 2)
    guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
    bytes.append(byte)
    index = next
  }
  return Data(bytes)
}

/// Hex-encoded text fields decoded back to UTF-8, as the shared ledger codec
/// writes them.
private func hexDecodedCorpus(of text: String) -> String {
  let separators = CharacterSet(charactersIn: "\t\n,\":{}[] ")
  return text.components(separatedBy: separators)
    .filter { $0.count >= 2 && $0.count % 2 == 0 && $0.allSatisfy(\.isHexDigit) }
    .compactMap { dataFromHex($0).flatMap { String(data: $0, encoding: .utf8) } }
    .joined(separator: "\n")
}

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

/// The tokens a presence text lists, read the way a stranger would: from the
/// `peer` lines, without the shared decoder.
private func tokens(inPresenceText text: String) -> [String] {
  text.split(separator: "\n").compactMap { line in
    let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
    guard fields.count == 3, fields[0] == "peer" else { return nil }
    return String(fields[1])
  }
}

private struct PresenceSubmissionCapture {
  let eventCode: String
  let enin: Int
  let peerRpids: Set<String>
  let reporterRpid: String?
  let participantCommitment: Data?

  var searchableText: String {
    [
      "eventCode=\(eventCode)",
      "enin=\(enin)",
      "peerRpids=\(peerRpids.sorted().joined(separator: ","))",
      "reporterRpid=\(reporterRpid ?? "-")",
      "participantCommitment=\(participantCommitment.map { $0.map { String(format: "%02x", $0) }.joined() } ?? "-")"
    ].joined(separator: "\n")
  }

  var searchableBytes: Data {
    var data = Data(searchableText.utf8)
    if let participantCommitment { data.append(participantCommitment) }
    return data
  }
}

@MainActor
private final class PresenceContainmentSubmissionSpy: WindowReportSubmissionRuntimeProtocol {
  private(set) var captures: [PresenceSubmissionCapture] = []

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
      PresenceSubmissionCapture(
        eventCode: eventCode,
        enin: enin,
        peerRpids: peerRpids,
        reporterRpid: reporterRpid,
        participantCommitment: participantCommitment
      )
    )
  }

  func submitPending() {}

  func submissionState(forEventCode eventCode: String) -> ReportSubmissionState? { nil }

  func excludedWindowCount(forEventCode eventCode: String) -> Int { 0 }
}

@MainActor
private struct PresenceContainmentSession {
  let directory: URL
  let eventCode: String
  let proofId: UUID
  let proof: Proof?
  let displayIds: [String]
  let sortedRpidsByEnin: [Int: [String]]
  let unidentifiedRpid: String
  let reporterRpid: String
  let phaseBeforeReset: ScanPhase
  let liveTokensBeforeReset: [String]
  let presenceText: String?
  let presenceTokens: [String]
  let aggregate: BeidSharedKit.aggregation.SessionAggregate?
  let signedPayloads: [(eventCode: String, bytes: Data)]
  let reports: [WindowReport]
  let selfProofs: [SelfProofRecord]
  let submissionCaptures: [PresenceSubmissionCapture]
  let presenceStore: SigilPresenceStore

  var windowReportsURL: URL { directory.appendingPathComponent("window-reports.json") }
  var selfProofsURL: URL { directory.appendingPathComponent("self-proofs.json") }
  var selfProofCheckpointURL: URL { directory.appendingPathComponent("self-proof-checkpoint.json") }
  var bindingRecordsURL: URL { directory.appendingPathComponent("binding-records.json") }
  var sessionAggregateSnapshotsURL: URL {
    directory.appendingPathComponent("session-aggregate-snapshots.json")
  }
  var ledgerURL: URL { directory.appendingPathComponent("ledger.snapshot") }
  var presenceURL: URL { presenceStore.fileURL }

  /// Token probes, searched as plain substrings: each token and the hex of
  /// its UTF-8.
  var tokenProbes: [String] {
    presenceTokens.flatMap { [$0, hexEncodedUTF8(of: $0)] }
  }

  /// Display-id probes, searched with the hex-neighbour guard.
  var displayIdProbes: [String] {
    displayIds.flatMap { [$0, hexEncodedUTF8(of: $0)] }
  }

  /// Byte probes for binary payloads: each token's UTF-8 and its 16 raw bytes.
  var byteProbes: [[UInt8]] {
    presenceTokens.flatMap { token -> [[UInt8]] in
      [Array(token.utf8), dataFromHex(token).map { [UInt8]($0) } ?? []]
    } + displayIds.map { Array($0.utf8) }
  }

  var fixtureInputStrings: [String] {
    [eventCode, reporterRpid, unidentifiedRpid]
      + displayIds
      + sortedRpidsByEnin.values.flatMap { $0 }
      + sortedRpidsByEnin.keys.map(String.init)
  }
}

// MARK: - Tests

@MainActor
final class SigilPresenceNeverLeavesDeviceTests: XCTestCase {
  private static let eventCode = "BEID653-CONTAINMENT-EVENT"
  private static let reporterRpid = "c0ffee00c0ffee00c0ffee00"
  /// Distinctive ENINs, so "no ENIN in the presence file" is searchable.
  private static let firstEnin = 2_900_001
  private static let secondEnin = 2_900_002
  /// Display ids unlike `DetectionFixture`'s, so nothing else in the suite
  /// can produce them by accident.
  private static func displayId(device index: Int) -> String {
    String(format: "%08x", UInt32(truncatingIfNeeded: 0x5a6e_0000 &+ index))
  }

  private func makeSession(
    presenceStore existingStore: SigilPresenceStore? = nil
  ) throws -> PresenceContainmentSession {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("beid653-containment-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

    let windowReportStore = WindowReportStore(fileURL: directory.appendingPathComponent("window-reports.json"))
    let selfProofStore = SelfProofStore(fileURL: directory.appendingPathComponent("self-proofs.json"))
    let snapshotStore = SessionAggregateSnapshotStore(
      fileURL: directory.appendingPathComponent("session-aggregate-snapshots.json")
    )
    let presenceStore = existingStore ?? SigilPresenceStore(
      fileURL: directory
        .appendingPathComponent("SigilPresence", isDirectory: true)
        .appendingPathComponent("sigil-presence.json")
    )
    let cryptography = DeterministicSensingCryptography()
    let submissionSpy = PresenceContainmentSubmissionSpy()
    let ledgerURL = directory.appendingPathComponent("ledger.snapshot")

    let coordinator = SensingCoordinator(
      windowReportStore: windowReportStore,
      selfProofStore: selfProofStore,
      selfProofCheckpointStore: SelfProofCheckpointStore(
        fileURL: directory.appendingPathComponent("self-proof-checkpoint.json")
      ),
      bindingRecordStore: BindingRecordStore(
        fileURL: directory.appendingPathComponent("binding-records.json")
      ),
      sessionAggregateSnapshotStore: snapshotStore,
      sigilPresenceStore: presenceStore,
      unsentWindowLedgerFileURL: ledgerURL,
      sensingCryptography: cryptography,
      reportSubmissionRuntime: submissionSpy
    )
    coordinator.useDemoEventMode = false
    var collected: Proof?
    coordinator.onProofCollected = { collected = $0 }

    let deviceCount = max(BeidConfig.eventConfirmThreshold, 4)
    let displayIds = (0..<deviceCount).map(Self.displayId(device:))
    let enins = [Self.firstEnin, Self.secondEnin]
    var sortedRpidsByEnin: [Int: [String]] = [:]
    let unidentifiedRpid = "rpid-unidentified-\(Self.firstEnin)"

    coordinator.startSensing(eventCode: Self.eventCode)
    for enin in enins {
      var rpids: [String] = []
      for device in 0..<deviceCount {
        let rpid = DetectionFixture.rotatingRpid(device: device, enin: enin)
        rpids.append(rpid)
        coordinator.handleDetection(
          enin: enin,
          rpid: rpid,
          detectedDisplayId: displayIds[device],
          reporterRpid: Self.reporterRpid
        )
      }
      if enin == Self.firstEnin {
        // A B003 failure: counted as a window row, never drawn as a peer.
        coordinator.handleDetection(
          enin: enin,
          rpid: unidentifiedRpid,
          detectedDisplayId: nil,
          reporterRpid: Self.reporterRpid
        )
        rpids.append(unidentifiedRpid)
      }
      sortedRpidsByEnin[enin] = rpids.sorted()
    }

    let phaseBeforeReset = coordinator.phase
    let proofId = try XCTUnwrap(coordinator.currentProofID, "the session never created a Proof")
    let liveInput = try XCTUnwrap(coordinator.liveSigilInput, "no live Sigil during recording")
    let liveLayout = BeidSharedKit.sigil.layoutSigil(input: liveInput, size: 200, ground: .NONE)
    let liveTokens = (0..<Int(liveLayout.peerCount)).compactMap {
      liveLayout.peerAt(index: Int32($0))?.peerKey
    }

    coordinator.reset()

    let presenceText = presenceStore.records.first(where: { $0.proofId == proofId })?.presenceText
    return PresenceContainmentSession(
      directory: directory,
      eventCode: Self.eventCode,
      proofId: proofId,
      proof: collected,
      displayIds: displayIds,
      sortedRpidsByEnin: sortedRpidsByEnin,
      unidentifiedRpid: unidentifiedRpid,
      reporterRpid: Self.reporterRpid,
      phaseBeforeReset: phaseBeforeReset,
      liveTokensBeforeReset: liveTokens.sorted(),
      presenceText: presenceText,
      presenceTokens: presenceText.map(tokens(inPresenceText:)) ?? [],
      aggregate: coordinator.sessionAggregateSnapshot(forProofId: proofId),
      signedPayloads: cryptography.calls.compactMap { call -> (eventCode: String, bytes: Data)? in
        guard case let .signWindowReport(eventCode, bytes) = call else { return nil }
        return (eventCode: eventCode, bytes: bytes)
      },
      reports: windowReportStore.reports,
      selfProofs: selfProofStore.records,
      submissionCaptures: submissionSpy.captures,
      presenceStore: presenceStore
    )
  }

  private func assertNoProbe(
    in text: String,
    artifact: String,
    session: PresenceContainmentSession,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let lowered = text.lowercased()
    for probe in session.tokenProbes {
      XCTAssertFalse(
        lowered.contains(probe),
        """
        the Sigil presence token \(probe) was found in \(artifact). beid#653 \
        presence lives on this device, in the presence store, and nowhere \
        else. Take it back out.
        """,
        file: file,
        line: line
      )
    }
    for probe in session.displayIdProbes {
      XCTAssertFalse(
        containsValueOccurrence(of: probe, in: text),
        """
        the display id \(probe) was found in \(artifact). A display id is \
        persisted nowhere (beid#653 stores a random token in its place). \
        Take it back out.
        """,
        file: file,
        line: line
      )
    }
  }

  private func loadArtifact(
    at url: URL,
    anchors: [String],
    artifact: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws -> String {
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: url.path),
      "\(artifact) was never written, so searching it would pass vacuously",
      file: file,
      line: line
    )
    let data = try Data(contentsOf: url)
    XCTAssertFalse(data.isEmpty, "\(artifact) is empty", file: file, line: line)
    let text = try XCTUnwrap(String(data: data, encoding: .utf8), file: file, line: line)
    for anchor in anchors {
      XCTAssertTrue(
        text.lowercased().contains(anchor.lowercased()),
        "\(artifact) does not contain \(anchor): this is not this session's file",
        file: file,
        line: line
      )
    }
    return text
  }

  // MARK: 1. Positive anchor

  func testFixtureWritesPresenceAndProbesAppearInNoInput() throws {
    let session = try makeSession()

    guard case .recording = session.phaseBeforeReset else {
      return XCTFail("the session never reached .recording; every absence below would be vacuous")
    }
    let text = try XCTUnwrap(session.presenceText, "no presence row was written for the Proof")
    let aggregate = try XCTUnwrap(session.aggregate, "no aggregate snapshot to compare with")
    XCTAssertEqual(session.presenceTokens.count, session.displayIds.count)
    XCTAssertEqual(session.presenceTokens.count, Int(aggregate.deviceCount))
    XCTAssertTrue(text.contains("windows\t\(aggregate.windowCount)\n"))
    XCTAssertEqual(session.presenceTokens, session.liveTokensBeforeReset,
                   "the live Sigil and the stored one must be the same data")
    for token in session.presenceTokens {
      XCTAssertEqual(token.count, 32)
      XCTAssertTrue(token.allSatisfy { $0.isHexDigit && !$0.isUppercase }, token)
    }
    XCTAssertGreaterThanOrEqual(session.reports.count, 1)
    XCTAssertEqual(session.signedPayloads.count, session.reports.count)
    XCTAssertGreaterThanOrEqual(session.selfProofs.count, 1)
    XCTAssertGreaterThanOrEqual(session.submissionCaptures.count, 1)
    for probe in session.tokenProbes {
      for input in session.fixtureInputStrings {
        XCTAssertFalse(input.lowercased().contains(probe),
                       "token probe \(probe) also occurs in fixture input \(input)")
      }
    }
  }

  // MARK: 2. Ledger

  func testLedgerBytesContainNoTokenOrDisplayId() throws {
    let session = try makeSession()
    let anchors = session.reports.map { hexEncodedUTF8(of: $0.id.uuidString.lowercased()) }
    XCTAssertFalse(anchors.isEmpty)
    XCTAssertFalse(session.presenceTokens.isEmpty)
    let ledger = try loadArtifact(at: session.ledgerURL, anchors: anchors, artifact: "the ledger")
    assertNoProbe(in: ledger, artifact: "the unsent-window ledger", session: session)
    assertNoProbe(in: hexDecodedCorpus(of: ledger), artifact: "the ledger's hex fields", session: session)
  }

  // MARK: 3. Every other store

  func testEveryOtherStoreContainsNoTokenOrDisplayId() throws {
    let session = try makeSession()
    XCTAssertFalse(session.presenceTokens.isEmpty)
    let proofAnchor = session.proofId.uuidString

    for (url, anchors, name) in [
      (session.windowReportsURL, [session.eventCode], "window-reports.json"),
      (session.selfProofsURL, [session.eventCode], "self-proofs.json"),
      (session.sessionAggregateSnapshotsURL, [proofAnchor], "session-aggregate-snapshots.json"),
    ] {
      let text = try loadArtifact(at: url, anchors: anchors, artifact: name)
      assertNoProbe(in: text, artifact: name, session: session)
      assertNoProbe(in: hexDecodedCorpus(of: text), artifact: "hex fields of \(name)", session: session)
    }
    for (url, name) in [
      (session.bindingRecordsURL, "binding-records.json"),
      (session.selfProofCheckpointURL, "self-proof-checkpoint.json"),
    ] where FileManager.default.fileExists(atPath: url.path) {
      let text = try XCTUnwrap(String(data: Data(contentsOf: url), encoding: .utf8))
      assertNoProbe(in: text, artifact: name, session: session)
    }

    // The Proof itself (ProofStore's row).
    let proof = try XCTUnwrap(session.proof, "the session emitted no Proof")
    XCTAssertEqual(proof.id, session.proofId)
    let proofJSON = try XCTUnwrap(String(data: JSONEncoder().encode(proof), encoding: .utf8))
    assertNoProbe(in: proofJSON, artifact: "the Proof record", session: session)

    // Nothing else in the session directory, apart from the presence store
    // itself, may hold a probe either — including files this list forgot.
    let presenceDirectory = session.presenceURL.deletingLastPathComponent().standardizedFileURL
    let enumerator = FileManager.default.enumerator(at: session.directory, includingPropertiesForKeys: nil)
    var scanned = 0
    while let url = enumerator?.nextObject() as? URL {
      guard url.standardizedFileURL.deletingLastPathComponent() != presenceDirectory,
            url.standardizedFileURL != presenceDirectory,
            let data = try? Data(contentsOf: url),
            let text = String(data: data, encoding: .utf8)
      else { continue }
      scanned += 1
      assertNoProbe(in: text, artifact: url.lastPathComponent, session: session)
    }
    XCTAssertGreaterThanOrEqual(scanned, 3, "the directory walk found almost nothing to scan")
  }

  // MARK: 4. Signing inputs

  func testSignedWindowPayloadIsExactlyItsDeclaredInputsAndNothingElse() throws {
    let session = try makeSession()
    XCTAssertGreaterThanOrEqual(session.reports.count, 1)
    guard session.reports.count == session.signedPayloads.count else {
      return XCTFail("reports and signatures cannot be paired")
    }
    for (index, report) in session.reports.enumerated() {
      let payload = session.signedPayloads[index].bytes
      let commit = try XCTUnwrap(dataFromHex(report.commitHex))
      let rpids = try XCTUnwrap(session.sortedRpidsByEnin[report.enin])
      var expected = Data(session.eventCode.utf8)
      expected.append(contentsOf: withUnsafeBytes(of: Int64(report.enin).bigEndian) { Array($0) })
      expected.append(commit)
      for rpid in rpids {
        expected.append(contentsOf: Array(rpid.utf8))
      }
      XCTAssertEqual(
        payload,
        expected,
        """
        the signed window payload is not exactly "event code ‖ ENIN ‖ \
        commitment ‖ sorted peer RPIDs" (beid#653): nothing else may be \
        signed, and a presence token least of all.
        """
      )
    }
  }

  func testSignedWindowPayloadBytesContainNoTokenOrDisplayId() throws {
    let session = try makeSession()
    XCTAssertGreaterThanOrEqual(session.signedPayloads.count, 1)
    XCTAssertFalse(session.presenceTokens.isEmpty)
    for (index, payload) in session.signedPayloads.enumerated() {
      XCTAssertEqual(payload.eventCode, session.eventCode)
      XCTAssertFalse(payload.bytes.isEmpty)
      for probe in session.byteProbes where !probe.isEmpty {
        XCTAssertFalse(containsByteSequence(probe, in: payload.bytes),
                       "a presence token or display id was signed in window \(index)")
      }
    }
  }

  // MARK: 5. Submission payload

  func testSubmissionPayloadContainsNoTokenOrDisplayId() throws {
    let session = try makeSession()
    XCTAssertGreaterThanOrEqual(session.submissionCaptures.count, 1)
    XCTAssertFalse(session.presenceTokens.isEmpty)
    for (index, capture) in session.submissionCaptures.enumerated() {
      XCTAssertEqual(capture.eventCode, session.eventCode)
      XCTAssertEqual(capture.peerRpids.sorted(), try XCTUnwrap(session.sortedRpidsByEnin[capture.enin]),
                     "capture \(index) does not carry the peers this fixture fed")
      assertNoProbe(in: capture.searchableText, artifact: "submission capture \(index)", session: session)
      for probe in session.byteProbes where !probe.isEmpty {
        XCTAssertFalse(containsByteSequence(probe, in: capture.searchableBytes),
                       "a presence token or display id is in submission capture \(index)")
      }
    }
  }

  // MARK: 6. The presence store holds tokens and ranks only

  func testPresenceStoreHoldsNoDisplayIdRpidEninOrEventCode() throws {
    let session = try makeSession()
    let text = try loadArtifact(
      at: session.presenceURL,
      anchors: [session.proofId.uuidString] + session.presenceTokens,
      artifact: "the presence store"
    )
    var forbidden = session.displayIds + [session.eventCode, session.reporterRpid, session.unidentifiedRpid]
    forbidden += session.sortedRpidsByEnin.values.flatMap { $0 }
    forbidden += session.sortedRpidsByEnin.keys.map(String.init)
    for value in forbidden {
      XCTAssertFalse(containsValueOccurrence(of: value, in: text),
                     "the presence store holds \(value); it may hold tokens and window ranks only")
      XCTAssertFalse(containsValueOccurrence(of: hexEncodedUTF8(of: value), in: text))
    }
  }

  func testPresenceCodecAndRecordEmitOnlyTheirDeclaredFields() throws {
    let session = try makeSession()
    let text = try XCTUnwrap(session.presenceText)
    let codecFields = Set(text.split(separator: "\n").map { String($0.split(separator: "\t")[0]) })
    XCTAssertEqual(codecFields, ["beid-sigil-presence", "windows", "peers", "peer", "end"])

    let fileData = try Data(contentsOf: session.presenceURL)
    let keys = allJSONKeys(in: try JSONSerialization.jsonObject(with: fileData))
    XCTAssertEqual(keys, ["schemaVersion", "records", "proofId", "presenceText", "createdAt"])
    for name in keys.union(codecFields) {
      for fragment in ["rssi", "signal", "dbm", "display", "rpid", "enin", "mutual", "event"] {
        XCTAssertFalse(name.lowercased().contains(fragment), "\(name) names \(fragment)")
      }
    }
  }

  // MARK: 7. Unlinkable across records; the session is dropped at reset

  func testASecondRecordOfTheSameDevicesGetsUnrelatedTokens() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("beid653-unlinkable-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let store = SigilPresenceStore(fileURL: directory.appendingPathComponent("sigil-presence.json"))

    let first = try makeSession(presenceStore: store)
    let second = try makeSession(presenceStore: store)
    XCTAssertNotEqual(first.proofId, second.proofId)
    XCTAssertEqual(first.displayIds, second.displayIds, "the same devices were seen both times")
    XCTAssertEqual(first.presenceTokens.count, first.displayIds.count)
    XCTAssertEqual(second.presenceTokens.count, second.displayIds.count)
    XCTAssertTrue(
      Set(first.presenceTokens).isDisjoint(with: second.presenceTokens),
      "a token was reused across records: tokens must be random per record, never derived"
    )
  }

  func testTheLiveSigilIsGoneAfterTheSessionEnds() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("beid653-live-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let coordinator = SensingCoordinator(
      loadingFromDirectory: directory,
      sensingCryptography: DeterministicSensingCryptography()
    )
    XCTAssertNil(coordinator.liveSigilInput, "no Proof yet, so no live Sigil")
    _ = coordinator.reset()
    XCTAssertNil(coordinator.liveSigilInput)
  }

  // MARK: 8. Backup

  func testPresenceFileAndDirectoryAreExcludedFromBackup() throws {
    let session = try makeSession()
    XCTAssertNotNil(session.presenceText)
    let file = try session.presenceURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
    XCTAssertEqual(file.isExcludedFromBackup, true, "the presence file must not reach a device backup")
    let directory = try session.presenceURL.deletingLastPathComponent()
      .resourceValues(forKeys: [.isExcludedFromBackupKey])
    XCTAssertEqual(directory.isExcludedFromBackup, true, "the presence directory must not reach a device backup")
  }

  func testProductionPresenceLivesInItsOwnApplicationSupportDirectory() {
    let url = SigilPresenceStore.defaultFileURL()
    XCTAssertEqual(url.lastPathComponent, "sigil-presence.json")
    XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "SigilPresence")
    XCTAssertTrue(url.path.contains("/Library/Application Support/"), url.path)
    XCTAssertFalse(url.path.contains("/Documents/"), "Documents is backed up")
  }

  // MARK: 9. Structural: logs and source

  func testTheStoreErrorCarriesNoPayload() throws {
    for error in [SigilPresenceStoreError.unencodable, .conflictingPresence] {
      XCTAssertTrue(Mirror(reflecting: error).children.isEmpty, "\(error) carries a payload")
    }
    let source = try String(contentsOf: Self.appSource("Beid/Persistence/SigilPresenceStore.swift"), encoding: .utf8)
    let start = try XCTUnwrap(source.range(of: "enum SigilPresenceStoreError: Error {"))
    let end = try XCTUnwrap(source.range(of: "\n}\n", range: start.upperBound..<source.endIndex))
    let body = source[start.upperBound..<end.lowerBound]
    for line in body.split(separator: "\n") where line.trimmingCharacters(in: .whitespaces).hasPrefix("case ") {
      XCTAssertFalse(line.contains("("), "SigilPresenceStoreError gained an associated value: \(line)")
    }
  }

  /// `SigilLayout.peerAt(index:)` is the only way to read a token back out of
  /// a layout. Production draws primitives and counts only; nothing may read
  /// a token to show, log or send it.
  func testNoProductionCodeReadsSigilPeerKeys() throws {
    let root = Self.appSource("Beid")
    let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
    var scanned = 0
    while let url = enumerator?.nextObject() as? URL {
      guard url.pathExtension == "swift" else { continue }
      scanned += 1
      let source = try String(contentsOf: url, encoding: .utf8)
      XCTAssertFalse(source.contains("peerAt("), "\(url.lastPathComponent) reads a Sigil peer key")
    }
    XCTAssertGreaterThan(scanned, 50, "the source walk found almost no app source")
  }

  private static func appSource(_ relativePath: String) -> URL {
    guard let resources = Bundle(for: SigilPresenceNeverLeavesDeviceTests.self).resourceURL else {
      preconditionFailure("the test bundle has no resource directory")
    }
    return resources.appendingPathComponent(relativePath)
  }
}
