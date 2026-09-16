// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import Barnard
import BarnardCore
import BeidSharedKit
import XCTest
@testable import Beid

/// Contract test for levarac/dispatch#50's pre-delivery criterion: a device
/// that never heard the venue source receives the event info through a relay,
/// joins, and ends up with an observation record handed to the submission
/// runtime seam.
///
/// ## What makes the input relayed
///
/// Spec 134 re-broadcast copies the signed envelope byte for byte and changes
/// only the container's hop count. The relayed copy here is barnard's own
/// `encodeContainer(relayHopCount: 1, …)` around barnard's B005 v2
/// conformance-vector envelope (`test-vectors/b005-envelope-v2.txt`, `v1_*`):
/// genuinely signed, genuinely hop 1, and arriving from a relayer peripheral.
/// No hop-zero container is ever handed to the coordinator, which is what
/// "never saw the source" means at this seam.
///
/// ## What it drives, and what it does not
///
/// barnard's real `verify` produces the verified envelope, and the agreement
/// closure evaluates barnard's real `registryAgreement` against the definition
/// the coordinator itself builds from the registry answer, so the promotion
/// only happens if the relayed copy genuinely agrees. The join goes through
/// the real capability gate, detections cross the confirm threshold, and
/// ending the session closes the window into the report store and hands it to
/// the submission runtime through `WindowReportSubmissionRuntimeProtocol`.
///
/// Not driven:
/// - `SensingCoordinator.handle(_:)`'s `.eventInfoEnvelopeV2` case, including
///   the agreement closure it builds. `BarnardEventInfoEnvelopeV2Event` has no
///   public initializer, so this test enters at `handleEventInfoEnvelopeV2(...)`
///   with the fields that case passes and a copy of its closure's expression
///   written here. A regression confined to the production closure would not
///   turn this test red. The test also passes `observedAtEpochMillis`, which
///   that case leaves to its default; the default reads the injected
///   `nearbyDiscoveryClock`, which returns the same value.
/// - The real `ReportSubmissionRuntime`. The runtime here is
///   `RelayedWindowSubmissionSpy`, which only records the
///   `captureAndQueueWindow` hand-off, so the real runtime's queue and send
///   are not exercised.
///
/// Real-radio relay between physical devices is the ship gate's job
/// (levarac/dispatch#62), not this test's.
@MainActor
final class RelayedEventInfoContractTests: XCTestCase {
  /// barnard's `v1_envelope`: authority-direct mode, signed over ENINs
  /// 5_999_990...6_000_010 with relay expiry 6_000_002.
  private static let sourceEnvelopeHex =
    "011111111111111111111111111111111111111111222222222222222222222222222222222222222233333333333333333333333333333333333333333333333333333333333333330102f9308a019258c31049344f85f89d5229b531c845836f99b08601f113bce036f900012c005b8d76005b8d8a005b8d82029adc61d60dda843e3a4261726e6172642052656c617920436f6e666f726d616e6365204576656e742030313233343536373839206162636465666768696a6b6c6d6e6f00f3e5c7db67db1a676b3e488b9f7805bdb0c7078a97cd65a01b2ba8630bc7bb334a594053371a53830a4cac5f57e74cbd1d684ca822859ca5fa510ef28b203b5000"
  private static let eventIdHex =
    "5d5891b92a9a6597aa2c58586fd2fdf3974f40f732b9a319ec9f3fc4d7ab3195"
  private static let keySetDigestHex =
    "cba59e50c7666ef2468a14f2e53f04decfd078933cd245a9a2d77532eb23b700"
  private static let eventCodeHashHex = "9adc61d60dda843e"
  /// The vector's window in Unix seconds: `validFrom * 300` through
  /// `(validThrough + 1) * 300 - 1`. barnard requires exact agreement.
  private static let validFromEpochSeconds: Int64 = 1_799_997_000
  private static let validUntilEpochSeconds: Int64 = 1_800_003_299
  /// ENIN 6_000_000, inside `[validFrom, relayExpires)`.
  private static let currentEnin: Int64 = 6_000_000
  private static let nowEpochMillis: Int64 = 1_800_000_000_000
  private static let relayerPeripheralId = "peripheral-relaying-participant"

  func testRelayedEventInfoFromAParticipantReachesJoinAndAQueuedRecord() async throws {
    let sourceEnvelope = try XCTUnwrap(Self.bytes(fromHex: Self.sourceEnvelopeHex))
    let relayedContainer = try XCTUnwrap(
      BarnardB005EnvelopeV2.encodeContainer(relayHopCount: 1, signedEnvelope: sourceEnvelope)
    )
    let verified = try XCTUnwrap(
      BarnardB005EnvelopeV2.verify(
        container: relayedContainer,
        currentEnin: Self.currentEnin,
        nameValidator: BarnardB005NativeDisplayNameNormalizer()
      )
    )
    // Guards the premise: if this ever stopped being a verifiable hop-1 copy,
    // the rest of the test would silently exercise a direct receipt instead.
    XCTAssertEqual(verified.relayHopCount, 1)

    let registry = FakeEventJoinRegistry()
    registry.answer = .resolves(
      BeidSharedKit.jointestsupport.createEventDefinitionResolutionForTesting(
        eventIdHex: "0x" + Self.eventIdHex,
        definitionHashHex: "0x" + String(repeating: "b", count: 64),
        blockHashHex: "0x" + String(repeating: "c", count: 64),
        eventCodeHashHex: Self.eventCodeHashHex,
        validFromEpochSeconds: Self.validFromEpochSeconds,
        validUntilEpochSeconds: Self.validUntilEpochSeconds,
        joinMode: ExportedKotlinPackages.org.levarac.parallax.registry.EventJoinMode.OPEN,
        keySetDigestHex: Self.keySetDigestHex
      )
    )
    let engine = RecordingEventJoinControl()
    engine.permissionOutcome = .granted
    let submission = RelayedWindowSubmissionSpy()
    let (coordinator, reportStore) = makeCoordinator(
      engine: engine,
      registry: registry,
      submission: submission
    )

    // The fields `handle(_:)`'s `.eventInfoEnvelopeV2` case passes, with a
    // copy of its agreement closure, plus an explicit `observedAtEpochMillis`
    // equal to what that case's default reads from `nearbyDiscoveryClock`.
    coordinator.handleEventInfoEnvelopeV2(
      peripheralId: Self.relayerPeripheralId,
      eventDisplayName: verified.eventDisplayName,
      eventCodeHash: Data(verified.eventCodeHash),
      rawContainer: Data(relayedContainer),
      verifiedEventIdHex: "0x" + Self.hex(verified.eventId),
      registryAgreement: { definition in
        BarnardB005EnvelopeV2.registryAgreement(verified, definition: definition) == .agrees
      },
      observedAtEpochMillis: Self.nowEpochMillis
    )
    try await waitUntil("the relayed candidate is registry-verified") {
      coordinator.nearbyEventCandidates.candidateAt(index: 0)?.receiverState == .REGISTRY_VERIFIED
    }

    let candidate = try XCTUnwrap(coordinator.nearbyEventCandidates.candidateAt(index: 0))
    XCTAssertEqual(candidate.sourceAt(index: 0)?.peripheralId, Self.relayerPeripheralId)
    XCTAssertNil(candidate.sourceAt(index: 1), "only the relayer was ever heard")
    XCTAssertEqual(candidate.rawEnvelopeContainerHex, Self.hex(relayedContainer))

    coordinator.joinNearbyEvent(eventCodeHashHex: Self.eventCodeHashHex)
    try await waitUntil("the relayed candidate is joined") { !engine.joinAndStartContexts.isEmpty }
    XCTAssertEqual(engine.joinAndStartContexts.count, 1)
    XCTAssertEqual(Self.normalized(engine.joinAndStartContexts.first?.eventIdHex), Self.eventIdHex)

    let threshold = BeidConfig.eventConfirmThreshold
    for index in 0..<threshold {
      coordinator.handleDetection(
        enin: Int(Self.currentEnin),
        rpid: "peer-\(index)",
        detectedDisplayId: DetectionFixture.displayId(device: index)
      )
    }
    guard case .recording = coordinator.phase else {
      XCTFail("expected .recording after \(threshold) detections, got \(coordinator.phase)")
      return
    }

    coordinator.reset()

    XCTAssertEqual(reportStore.reports.count, 1, "one observation record for the relayed event")
    XCTAssertEqual(submission.queuedWindows.count, 1, "that window was queued for submission")
    XCTAssertEqual(Self.normalized(submission.queuedWindows.first?.eventIdHex), Self.eventIdHex)
    XCTAssertEqual(submission.queuedWindows.first?.id, reportStore.reports.first?.id)
  }

  // MARK: - Helpers

  private func makeCoordinator(
    engine: RecordingEventJoinControl,
    registry: FakeEventJoinRegistry,
    submission: RelayedWindowSubmissionSpy
  ) -> (SensingCoordinator, WindowReportStore) {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("relayed-event-info-contract-\(UUID().uuidString)", isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    } catch {
      preconditionFailure("Unable to create test directory: \(error)")
    }
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let reportStore = WindowReportStore(
      fileURL: directory.appendingPathComponent("window-reports.json")
    )
    let coordinator = SensingCoordinator(
      windowReportStore: reportStore,
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
      reportSubmissionRuntime: submission,
      eventJoinControl: engine,
      eventJoinRegistry: registry,
      nearbyDiscoveryClock: { Self.nowEpochMillis }
    )
    coordinator.useDemoEventMode = false
    return (coordinator, reportStore)
  }

  /// Yields to the main actor until `condition` holds, failing after a bound
  /// rather than hanging, because the registry and permission completions
  /// each hop through `Task { @MainActor in }`.
  private func waitUntil(
    _ description: String,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: () -> Bool
  ) async throws {
    for _ in 0..<200 {
      if condition() { return }
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    XCTFail("timed out waiting until \(description)", file: file, line: line)
    throw CancellationError()
  }

  private static func normalized(_ hex: String?) -> String? {
    guard let hex else { return nil }
    let lowered = hex.lowercased()
    return lowered.hasPrefix("0x") ? String(lowered.dropFirst(2)) : lowered
  }

  private static func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
  }

  private static func bytes(fromHex hex: String) -> [UInt8]? {
    guard hex.count % 2 == 0 else { return nil }
    var result: [UInt8] = []
    result.reserveCapacity(hex.count / 2)
    var index = hex.startIndex
    while index < hex.endIndex {
      let next = hex.index(index, offsetBy: 2)
      guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
      result.append(byte)
      index = next
    }
    return result
  }
}

/// Records what the coordinator hands the submission runtime at window close.
private final class RelayedWindowSubmissionSpy: WindowReportSubmissionRuntimeProtocol {
  struct QueuedWindow {
    let id: UUID
    let eventIdHex: String?
  }

  private(set) var queuedWindows: [QueuedWindow] = []

  func captureAndQueueWindow(
    id: UUID,
    eventCode: String,
    eventIdHex: String?,
    enin: Int,
    peerRpids: Set<String>,
    reporterRpid: String?,
    participantCommitment: Data?
  ) {
    queuedWindows.append(QueuedWindow(id: id, eventIdHex: eventIdHex))
  }

  func submitPending() {}

  func submissionState(forEventCode eventCode: String) -> ReportSubmissionState? {
    nil
  }

  func excludedWindowCount(forEventCode _: String) -> Int { 0 }
}
