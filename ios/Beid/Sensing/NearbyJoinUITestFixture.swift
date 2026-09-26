// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

#if DEBUG
import Barnard
import BarnardCore
import BeidSharedKit
import SwiftUI

/// A seeded receiver snapshot and recording native effects for beid#579.
/// The card, Button, tap helper, permission callback, and shared issuer remain
/// production code. This fixture does not exercise BLE or registry transport.
@MainActor
enum NearbyJoinUITestFixture {
  static var isEnabled: Bool {
    let arguments = ProcessInfo.processInfo.arguments
    return arguments.contains("-beid-ui-test") && arguments.contains("-beid-nearby-join-fixture")
  }

  static let engine = NearbyJoinUITestEngine()
  static let eventId = "5d5891b92a9a6597aa2c58586fd2fdf3974f40f732b9a319ec9f3fc4d7ab3195"
  static let hash = "9adc61d60dda843e"

  static func makeCoordinator() -> SensingCoordinator {
    let now = Int64(Date().timeIntervalSince1970)
    let store = ExportedKotlinPackages.org.levarac.parallax.discovery.createNearbyEventDiscoveryStore()
    _ = ExportedKotlinPackages.org.levarac.parallax.discovery.recordNearbyEventRadioSelfVerifiedEnvelopeFromHex(
      store: store, peripheralId: "nearby-ui-fixture", eventDisplayName: "Community night",
      eventCodeHashHex: hash, rawContainerHex: "03000004", agreesWithRegistry: false,
      additionalNamesOmitted: false, additionalEventsOmitted: false, observedAtEpochMillis: now * 1_000
    )
    guard let attempt = ExportedKotlinPackages.org.levarac.parallax.discovery
      .beginNearbyEventRegistryResolutionFromHex(store: store, eventCodeHashHex: hash)
    else { preconditionFailure("Expected fixture registry resolution") }
    _ = ExportedKotlinPackages.org.levarac.parallax.discovery.completeNearbyEventRegistryResolutionFromHex(
      store: store, attempt: attempt, result: .VERIFIED,
      resolvedEventIdHex: eventId, verifiedDefinitionJoinMode: .OPEN,
      verifiedDefinitionEventIdHex: eventId, verifiedDefinitionEventCodeHashHex: hash,
      envelopeAgreesWithRegistry: true,
      verifiedDefinitionHashHex: String(repeating: "ab", count: 32),
      registryBlockHashHex: String(repeating: "cd", count: 32),
      verifiedDefinitionValidFromEpochSeconds: now - 60,
      verifiedDefinitionValidUntilEpochSeconds: now + 3_600
    )
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nearby-ui-\(UUID().uuidString)")
    let coordinator = SensingCoordinator(
      windowReportStore: WindowReportStore(fileURL: directory.appendingPathComponent("windows.json")),
      selfProofStore: SelfProofStore(fileURL: directory.appendingPathComponent("proofs.json")),
      selfProofCheckpointStore: SelfProofCheckpointStore(fileURL: directory.appendingPathComponent("checkpoint.json")),
      bindingRecordStore: BindingRecordStore(fileURL: directory.appendingPathComponent("bindings.json")),
      sessionAggregateSnapshotStore: SessionAggregateSnapshotStore(fileURL: directory.appendingPathComponent("aggregate.json")),
      unsentWindowLedgerRuntime: nil,
      sensingCryptography: BarnardSensingCryptography(),
      eventJoinControl: engine,
      nearbyDiscoveryStore: store,
      participantRelayControl: engine
    )
    coordinator.useDemoEventMode = false
    return coordinator
  }
}

/// Records only actual native join calls; no phase or tap callback writes this receipt.
final class NearbyJoinUITestEngine: ObservableObject, EventJoinControlling, ParticipantRelayControlling {
  @Published private(set) var receipt = "joins=0 event=none"
  private var joinCount = 0
  private var eventCode: String?
  var onEvent: ((BarnardEvent) -> Void)?

  func requestJoinPermissions(_ completion: @escaping (Bool, Bool) -> Void) { completion(true, true) }
  func startDiscoveryScan() {}
  func stopDiscoveryScan() {}
  func joinAndStart(_ context: ExportedKotlinPackages.org.levarac.parallax.discovery.RegistryVerifiedJoinContext) {
    joinCount += 1
    eventCode = context.joinCode
    receipt = "joins=\(joinCount) event=\(context.joinCode)"
  }
  func leaveJoinedEvent() { eventCode = nil }
  func stopAutomaticOperation() {}
  func currentJoinedEventCode() -> String? { eventCode }
  func setParticipantRelayVerifier(_ verifier: (any BarnardRelayVerifier)?) {}
  func advanceParticipantRelay() {}
}

@MainActor
struct NearbyJoinUITestReceipt: View {
  @ObservedObject private var engine = NearbyJoinUITestFixture.engine

  var body: some View {
    Text(verbatim: engine.receipt)
      .font(DS.Font.meta)
      .accessibilityIdentifier("fixture.nearby-join.receipt")
  }
}
#endif
