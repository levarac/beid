// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import Barnard
import BeidSharedKit

/// Defers SDK construction until the device secret has been resolved. Both
/// sensing ports share the same checked storage and the same radio instance.
final class KeychainSensingEngine: EventJoinControlling, ParticipantRelayControlling {
  var onEvent: ((BarnardEvent) -> Void)? {
    didSet { engine?.onEvent = onEvent }
  }

  private let store: DeviceSecretKeychainStore
  private var storage: ResolvedDeviceSecretStorage?
  private var engine: BarnardEngine?

  init(store: DeviceSecretKeychainStore) {
    self.store = store
  }

  func prepare() throws {
    let resolved = try store.resolve()
    guard storage != resolved else { return }
    engine?.stopAutomaticOperation()
    let engine = BarnardEngine(keyStorage: resolved)
    engine.onEvent = onEvent
    self.engine = engine
    storage = resolved
  }

  func requestJoinPermissions(_ completion: @escaping (Bool, Bool) -> Void) {
    engine?.requestJoinPermissions(completion)
  }

  func startDiscoveryScan() { engine?.startDiscoveryScan() }
  func stopDiscoveryScan() { engine?.stopDiscoveryScan() }

  func joinAndStart(
    _ context: ExportedKotlinPackages.org.levarac.parallax.discovery.RegistryVerifiedJoinContext
  ) {
    engine?.joinAndStart(context)
  }

  func leaveJoinedEvent() { engine?.leaveJoinedEvent() }
  func stopAutomaticOperation() { engine?.stopAutomaticOperation() }
  func currentJoinedEventCode() -> String? { engine?.currentJoinedEventCode() }

  func setParticipantRelayVerifier(_ verifier: (any BarnardRelayVerifier)?) {
    engine?.setParticipantRelayVerifier(verifier)
  }

  func advanceParticipantRelay() { engine?.advanceParticipantRelay() }
}
