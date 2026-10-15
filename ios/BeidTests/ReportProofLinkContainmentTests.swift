// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import BeidSharedKit
import Foundation
import XCTest
@testable import Beid

/// beid#701 T4 and T5: the report-to-proof link never leaves the device and
/// never enters what is signed, sent or queued for submission.
///
/// T4 is structural: the record types on the submission path have no field a
/// Proof id could go into. T5 is behavioural: after a real linked session,
/// no spelling of that session's Proof id appears in any signed, sent or
/// queued byte. Every absence is paired with a positive control, in the
/// same spirit as `SignalStrengthNeverRecordedTests`: a scan over bytes that
/// were never written, or that carry no id at all, would pass for the wrong
/// reason.
@MainActor
final class ReportProofLinkContainmentTests: XCTestCase {
  private let eventIdHex = String(repeating: "11", count: 32)
  private let definitionDigestHex = String(repeating: "22", count: 32)
  private let receiptKeyHex = "02c6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee5"
  private let receiptPrivateKey = [UInt8](repeating: 0, count: 31) + [2]

  // MARK: - T4 Structural

  /// Adding a `proofId` to any of these types, or to the lab projection,
  /// turns this red the day the field appears, before any producer sets it.
  /// Each type must emit a key known to be its own, so an empty key set
  /// cannot pass.
  func testSubmissionPathRecordTypesHaveNoFieldNamedForAProof() throws {
    func keys<Record: Encodable>(of record: Record) throws -> Set<String> {
      let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record))
      return Set(try XCTUnwrap(object as? [String: Any]).keys)
    }

    let recordKeys = try keys(of: ReportSubmissionRecord(
      id: UUID(),
      eventCode: "EVENT",
      endpoint: "https://example.invalid/observations",
      receiptPublicKeyHex: String(repeating: "ab", count: 33),
      eventIdHex: eventIdHex,
      eventDefinitionDigestHex: definitionDigestHex,
      validFrom: 1,
      validUntil: 2,
      signedObservationHex: String(repeating: "12", count: 64),
      observationDigestHex: String(repeating: "34", count: 32),
      operatorIdHex: String(repeating: "56", count: 32),
      submissionState: .accepted,
      acceptanceReceiptHex: String(repeating: "78", count: 32),
      terminalErrorCode: "rejected"
    ))
    let captureKeys = try keys(of: ReportSubmissionCapture(
      id: UUID(),
      eventCode: "EVENT",
      eventIdHex: eventIdHex,
      enin: 1,
      peerRpids: ["aa"],
      reporterRpid: "bb",
      participantCommitment: Data(repeating: 0x0c, count: 32)
    ))
    let exclusionKeys = try keys(of: ReportSubmissionExclusion(
      id: UUID(),
      eventCode: "EVENT",
      eventIdHex: eventIdHex,
      enin: 1,
      peerCount: 2,
      reasonCode: "legacy-count-only",
      createdAt: Date()
    ))
    let windowReportKeys = try keys(of: WindowReport(
      eventCode: "EVENT",
      enin: 1,
      peerCount: 2,
      commit: Data(repeating: 0x0c, count: 32),
      signature: SensingRecoverableSignature(
        r: Data(repeating: 0x11, count: 32),
        s: Data(repeating: 0x22, count: 32),
        v: 0
      )
    ))
    let labFields = Set(Mirror(reflecting: LabRecordMetadata(
      windowId: "window",
      eventId: "event",
      observationDigest: "digest",
      status: "PREPARED",
      receiptStored: false,
      terminalError: nil
    )).children.compactMap(\.label))

    for (name, fields, ownField) in [
      ("ReportSubmissionRecord", recordKeys, "signedObservationHex"),
      ("ReportSubmissionCapture", captureKeys, "participantCommitment"),
      ("ReportSubmissionExclusion", exclusionKeys, "reasonCode"),
      ("WindowReport", windowReportKeys, "commitHex"),
      ("LabRecordMetadata", labFields, "observationDigest")
    ] {
      XCTAssertTrue(
        fields.contains(ownField),
        "\(name) did not emit \(ownField), so this is not its real field set"
      )
      for field in fields {
        XCTAssertFalse(
          field.lowercased().contains("proof"),
          """
          \(name) has a field named \(field). beid#701 keeps the Proof id and \
          the report-to-proof link out of every submission-path record; the \
          link lives only in ReportProofLinkStore.
          """
        )
      }
    }
  }

  // MARK: - T5 Behavioural

  /// Runs one real linked session through the real coordinator, the real
  /// runtime and a loopback operator, then searches every signed, sent and
  /// queued byte for the session's Proof id.
  func testProofIdNeverReachesSignedSentQueuedOrLabBytes() async throws {
    let directory = try makeReportProofLinkTestDirectory(for: self, named: "beid-report-proof-link-containment")
    let server = try StubOperatorServer(
      eventId: try XCTUnwrap(goldenData(fromHex: eventIdHex)),
      signingPrivateKey: receiptPrivateKey,
      signingPublicKey: try XCTUnwrap(goldenData(fromHex: receiptKeyHex))
    )
    defer { server.stop() }
    let endpoint = try await server.start()
    let submissionFileURL = directory.appendingPathComponent("report-submissions.json")
    let linkFileURL = directory.appendingPathComponent("report-proof-links.json")
    let cryptography = SignatureInputRecordingCryptography(wrapping: TestSensingCryptography())
    let runtime = try makeRuntime(
      endpoint: endpoint,
      cryptography: cryptography,
      fileURL: submissionFileURL,
      bundleDirectory: directory
    )
    #if DEBUG
    // Leave the record SUBMITTING after the POST, as a process death before
    // the receipt write would, so the relaunched runtime below must GET the
    // receipt and its URL is scanned too.
    runtime.receiptPersistenceGate = { false }
    #endif
    let linkStore = ReportProofLinkStore(fileURL: linkFileURL)
    let engine = RecordingEventJoinControl()
    engine.permissionOutcome = .granted
    let registry = FakeEventJoinRegistry()
    registry.answer = .resolves(FakeEventJoinRegistry.admittingResolution(eventIdHex: eventIdHex))
    let coordinator = makeLinkedSensingCoordinator(
      directory: directory,
      sensingCryptography: cryptography,
      reportSubmissionRuntime: runtime,
      reportProofLinkStore: linkStore,
      eventJoinControl: engine,
      eventJoinRegistry: registry
    )
    coordinator.useDemoEventMode = false

    coordinator.startSensing(eventCode: "verified-definition-event", eventIdHex: eventIdHex)
    // Let the permission grant and registry read admit the join first, as
    // `ReportSubmissionOperatorIntegrationTests.driveOneRealWindow` does.
    try await Task.sleep(nanoseconds: 100_000_000)
    let reporterRpid = "01" + String(repeating: "aa", count: 16)
    for index in 0..<BeidConfig.eventConfirmThreshold {
      coordinator.handleDetection(
        enin: 7,
        rpid: "01" + String(format: "%032x", index + 1),
        detectedDisplayId: DetectionFixture.displayId(device: index),
        reporterRpid: reporterRpid
      )
    }
    guard case .recording = coordinator.phase else {
      XCTFail("the containment session never reached .recording, so there is nothing to scan")
      return
    }
    let proofId = try XCTUnwrap(coordinator.currentProofID)
    _ = coordinator.stopSensing()
    try await server.waitFor(postCount: 1)

    #if DEBUG
    let relaunched = try makeRuntime(
      endpoint: endpoint,
      cryptography: cryptography,
      fileURL: submissionFileURL,
      bundleDirectory: directory
    )
    relaunched.submitPending()
    try await server.waitFor(postCount: 1, getCount: 1)
    try await waitForAcceptedRecord(at: submissionFileURL)
    withExtendedLifetime(relaunched) {}
    #endif
    withExtendedLifetime(runtime) {}
    withExtendedLifetime(coordinator) {}

    let record = try XCTUnwrap(ReportSubmissionStore(fileURL: submissionFileURL).records.first)
    let signedObservation = try XCTUnwrap(goldenData(fromHex: record.signedObservationHex))
    let proofNeedles = Self.spellings(of: proofId)
    let windowNeedles = Self.spellings(of: record.id)

    // Positive controls. The link exists, names this window, and the link
    // file really carries the id — so the needles below are the right ones.
    XCTAssertEqual(linkStore.proofId(forWindowId: record.id), .success(proofId))
    let linkFile = try Data(contentsOf: linkFileURL)
    XCTAssertTrue(
      Self.firstMatch(of: proofNeedles, in: linkFile) != nil,
      "the link file does not contain the Proof id, so the needles cannot be trusted"
    )
    // The scanner really reads id-bearing bytes: the signed Observation
    // carries the window id, which is not secret (design premise 6).
    XCTAssertTrue(
      Self.firstMatch(of: windowNeedles, in: signedObservation) != nil,
      "the signed Observation does not contain its window id, so this scan reads the wrong bytes"
    )

    var artifacts: [(name: String, bytes: Data)] = [("signed Observation", signedObservation)]
    XCTAssertGreaterThanOrEqual(
      cryptography.signatureInputs.count,
      2,
      "expected both the legacy WindowReport payload and the Observation to be signed"
    )
    for (index, input) in cryptography.signatureInputs.enumerated() {
      artifacts.append(("signature input \(index)", input))
    }
    XCTAssertEqual(server.postBodies.count, 1)
    for (index, body) in server.postBodies.enumerated() {
      artifacts.append(("POST body \(index)", body))
    }
    #if DEBUG
    XCTAssertTrue(
      server.requestPaths.contains { $0.hasSuffix("/acceptance") },
      "no receipt GET was made, so no GET URL was scanned"
    )
    #endif
    for (index, path) in server.requestPaths.enumerated() {
      artifacts.append(("request path \(index)", Data(path.utf8)))
    }

    XCTAssertTrue(FileManager.default.fileExists(atPath: submissionFileURL.path))
    for name in [
      "report-submissions.json",
      "report-submissions.pending.json",
      "report-submissions.exclusions.json",
      "window-reports.json",
      "ledger.snapshot"
    ] {
      let url = directory.appendingPathComponent(name)
      guard FileManager.default.fileExists(atPath: url.path) else {
        // Only the exclusions file may be absent: this session has no
        // count-only window.
        XCTAssertEqual(name, "report-submissions.exclusions.json", "\(name) was never written")
        continue
      }
      artifacts.append((name, try Data(contentsOf: url)))
    }
    let windowReports = try Data(contentsOf: directory.appendingPathComponent("window-reports.json"))
    XCTAssertTrue(
      Self.firstMatch(of: windowNeedles, in: windowReports) != nil,
      "window-reports.json does not name this window, so it is not this session's file"
    )
    let ledger = try Data(contentsOf: directory.appendingPathComponent("ledger.snapshot"))
    XCTAssertTrue(
      Self.firstMatch(of: windowNeedles, in: ledger) != nil,
      "the ledger does not name this window, so it is not this session's file"
    )

    guard case let .success(projection) = runtime.labRecordProjection() else {
      XCTFail("the lab projection is unreadable, so it cannot be scanned")
      return
    }
    XCTAssertEqual(projection.map(\.windowId), [record.id.uuidString.lowercased()])
    for (index, metadata) in projection.enumerated() {
      for child in Mirror(reflecting: metadata).children {
        artifacts.append((
          "lab projection \(index) \(child.label ?? "?")",
          Data(String(describing: child.value).utf8)
        ))
      }
    }

    for artifact in artifacts {
      XCTAssertFalse(artifact.bytes.isEmpty, "\(artifact.name) is empty, so scanning it proves nothing")
      if let found = Self.firstMatch(of: proofNeedles, in: artifact.bytes) {
        XCTFail(
          """
          \(artifact.name) contains the session's Proof id as \(found). \
          beid#701: the report-to-proof link stays on the device and out of \
          everything signed, sent or queued for submission.
          """
        )
      }
    }
  }

  // MARK: - Helpers

  /// Every spelling a UUID could plausibly be written in: its 16 raw bytes,
  /// its string with and without dashes in both cases, and each string's
  /// UTF-8 hex, which is how the shared ledger codec writes text fields.
  private static func spellings(of id: UUID) -> [(name: String, bytes: Data)] {
    let raw = withUnsafeBytes(of: id.uuid) { Data($0) }
    let upper = id.uuidString.uppercased()
    let lower = id.uuidString.lowercased()
    let texts = [
      ("uppercase with dashes", upper),
      ("lowercase with dashes", lower),
      ("uppercase without dashes", upper.replacingOccurrences(of: "-", with: "")),
      ("lowercase without dashes", lower.replacingOccurrences(of: "-", with: ""))
    ]
    var forms: [(name: String, bytes: Data)] = [("16 raw bytes", raw)]
    for (name, text) in texts {
      forms.append((name, Data(text.utf8)))
      forms.append(("UTF-8 hex of \(name)", Data(goldenHex(Data(text.utf8)).utf8)))
    }
    return forms
  }

  private static func firstMatch(
    of needles: [(name: String, bytes: Data)],
    in haystack: Data
  ) -> String? {
    needles.first { haystack.range(of: $0.bytes) != nil }?.name
  }

  private func makeRuntime(
    endpoint: URL,
    cryptography: any SensingCryptography,
    fileURL: URL,
    bundleDirectory: URL
  ) throws -> ReportSubmissionRuntime {
    let configuration = try XCTUnwrap(
      ExportedKotlinPackages.org.levarac.parallax.submission
        .createSubmissionOperatorConfiguration(
          endpoint: endpoint.absoluteString,
          receiptPublicKeyHex: receiptKeyHex,
          eventIdHex: eventIdHex,
          eventDefinitionDigestHex: definitionDigestHex,
          validFrom: nil,
          validUntil: nil,
          allowInsecureLoopbackForTests: true
        )
    )
    let bundleURL = bundleDirectory.appendingPathComponent(
      "submission-enabled-\(UUID().uuidString).bundle",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
    let plist: [String: Any] = [
      "CFBundleIdentifier": "org.levarac.beid.tests.\(UUID().uuidString)",
      "CFBundlePackageType": "BNDL",
      "BeidReportSubmissionEnabled": "1"
    ]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
      .write(to: bundleURL.appendingPathComponent("Info.plist"))
    return try XCTUnwrap(ReportSubmissionRuntime.makeIfEnabled(
      bundle: try XCTUnwrap(Bundle(url: bundleURL)),
      eventSigningCryptography: cryptography,
      definitionProvider: StaticEventDefinitionContextProvider(configuration: configuration),
      fileURL: fileURL,
      allowInsecureLoopbackForTests: true
    ))
  }

  private func waitForAcceptedRecord(at fileURL: URL) async throws {
    for _ in 0..<1_000 {
      if ReportSubmissionStore(fileURL: fileURL).records.first?.submissionState == .accepted {
        return
      }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    throw StubOperatorError.submissionStateTimedOut(expected: ReportSubmissionState.accepted.rawValue)
  }
}
