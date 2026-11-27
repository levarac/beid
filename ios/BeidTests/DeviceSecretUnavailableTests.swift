// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import Foundation
import Security
import SwiftUI
import XCTest
@testable import Beid

/// What the app does while the device secret cannot be read: it signs
/// nothing, joins nothing, and writes nothing, and it says so.
@MainActor
final class DeviceSecretUnavailableTests: XCTestCase {
  private let canonicalEventIdHex = "0x\(String(repeating: "a", count: 64))"

  func testChangedKeyDiscardCopyExplainsTheEstablishedCause() {
    XCTAssertEqual(
      EventSigningKeyFailure.changed.message,
      "A record from an earlier session could not be saved because this device's signing key changed. It was discarded."
    )
  }

  func testUnverifiableDiscardCopyUsesCatalogEntry() {
    XCTAssertEqual(
      Bundle.main.localizedString(forKey: "eventSigningKeyFailure.unverifiable", value: nil, table: nil),
      "A record from an earlier session could not be checked and was discarded."
    )
  }

  func testDiscardFailureCopyDescribesTheEarlierRecordWithoutRestrictingRecording() {
    XCTAssertEqual(EventSigningKeyFailure.discardFailed.title, "Earlier record update failed")
    XCTAssertEqual(
      EventSigningKeyFailure.discardFailed.message,
      "Changes to a record from an earlier session could not be saved."
    )
    for (key, value) in [
      ("eventSigningKeyFailure.discardFailed.title", EventSigningKeyFailure.discardFailed.title),
      ("eventSigningKeyFailure.discardFailed", EventSigningKeyFailure.discardFailed.message)
    ] {
      let localized = Bundle.main.localizedString(forKey: key, value: nil, table: nil)
      XCTAssertNotEqual(localized, key)
      XCTAssertEqual(value, localized)
    }
  }

  func testSigningKeyDiscardCopyUsesCatalogEntries() {
    XCTAssertEqual(EventSigningKeyFailure.changed.title, "Earlier record discarded")
    for (failure, key) in [
      (EventSigningKeyFailure.changed, "eventSigningKeyFailure.changed"),
      (.discardFailed, "eventSigningKeyFailure.discardFailed")
    ] {
      let localized = Bundle.main.localizedString(forKey: key, value: nil, table: nil)
      XCTAssertNotEqual(localized, key)
      XCTAssertEqual(failure.message, localized)
    }
    XCTAssertEqual(
      EventSigningKeyFailure.changed.title,
      Bundle.main.localizedString(forKey: "eventSigningKeyFailure.changed.title", value: nil, table: nil)
    )
  }

  func testDeviceKeyRefusalPanelUsesTheDeviceKeyErrorCopy() throws {
    let coordinator = makeCoordinator(deviceSecretStore: DeviceSecretKeychainStore(keychain: lockedKeychain()))
    coordinator.startSensing()

    XCTAssertEqual(coordinator.joinRefusal, .eventSigningKeyUnavailable)
    let reason = try XCTUnwrap(SensingCantJoinReason(joinRefusalKey: coordinator.joinRefusalReasonKey))
    XCTAssertEqual(reason.title, LocalizedStringKey(EventSigningKeyFailure.unavailable.title))
    XCTAssertEqual(reason.message, LocalizedStringKey(EventSigningKeyFailure.unavailable.message))
  }

  func testSignerRefusesWhileTheDeviceSecretIsUnavailable() {
    let keychain = lockedKeychain()
    let random = CountingDeviceSecretRandomSource()
    let cryptography = BarnardSensingCryptography(
      deviceSecretStore: DeviceSecretKeychainStore(keychain: keychain, randomSource: random)
    )

    XCTAssertThrowsError(try cryptography.eventSigningPublicKey(eventCode: "EVENT-A")) { error in
      XCTAssertEqual(error as? DeviceSecretError, .readFailed(errSecInteractionNotAllowed))
    }
    XCTAssertThrowsError(try cryptography.signWindowReport(eventCode: "EVENT-A", bytes: Data([0x01])))
    XCTAssertEqual(random.callCount, 0, "no throwaway secret may be generated to sign with")
    XCTAssertEqual(keychain.addCount + keychain.writeCount, 0)
  }

  func testJoinIsRefusedWhileTheDeviceSecretIsUnavailable() {
    let keychain = lockedKeychain()
    let coordinator = makeCoordinator(
      deviceSecretStore: DeviceSecretKeychainStore(keychain: keychain, randomSource: CountingDeviceSecretRandomSource())
    )
    coordinator.joinEvent("ethtokyo2026", canonicalEventIdHex: canonicalEventIdHex)

    coordinator.startSensing()

    XCTAssertEqual(coordinator.joinRefusal, .eventSigningKeyUnavailable)
    XCTAssertEqual(coordinator.eventSigningKeyFailure, .unavailable)
    guard case .idle = coordinator.phase else {
      return XCTFail("a refused join must leave the session idle, not \(coordinator.phase)")
    }
    XCTAssertEqual(keychain.addCount + keychain.writeCount, 0, "a read failure must not create or replace the secret")
  }

  func testJoinProceedsOnceTheDeviceSecretCanBeRead() {
    let keychain = lockedKeychain()
    let coordinator = makeCoordinator(
      deviceSecretStore: DeviceSecretKeychainStore(keychain: keychain, randomSource: CountingDeviceSecretRandomSource())
    )
    coordinator.joinEvent("ethtokyo2026", canonicalEventIdHex: canonicalEventIdHex)
    coordinator.startSensing()
    XCTAssertEqual(coordinator.joinRefusal, .eventSigningKeyUnavailable)

    keychain.readResults = []
    coordinator.startSensing()

    XCTAssertNil(coordinator.joinRefusal)
    XCTAssertNil(coordinator.eventSigningKeyFailure)
    guard case .sensing = coordinator.phase else {
      return XCTFail("with the secret readable the join must go on to the permission request, not \(coordinator.phase)")
    }
    XCTAssertEqual(keychain.addCount + keychain.writeCount, 0, "the stored secret is used, not replaced")
  }

  /// A Keychain that holds a secret but refuses every read, the way it does
  /// before the first unlock after a restart.
  private func lockedKeychain() -> InMemoryDeviceSecretKeychain {
    InMemoryDeviceSecretKeychain(
      storedData: Data(repeating: 0x01, count: 32),
      readResults: Array(repeating: .failure(errSecInteractionNotAllowed), count: 8)
    )
  }

  /// A coordinator that owns its Barnard engine (no seam injected), so the
  /// engine has to come from `deviceSecretStore`.
  private func makeCoordinator(deviceSecretStore: DeviceSecretKeychainStore) -> SensingCoordinator {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("device-secret-unavailable-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let coordinator = SensingCoordinator(
      windowReportStore: WindowReportStore(fileURL: directory.appendingPathComponent("window-reports.json")),
      selfProofStore: SelfProofStore(fileURL: directory.appendingPathComponent("self-proofs.json")),
      selfProofCheckpointStore: SelfProofCheckpointStore(
        fileURL: directory.appendingPathComponent("self-proof-checkpoint.json")
      ),
      bindingRecordStore: BindingRecordStore(fileURL: directory.appendingPathComponent("binding-records.json")),
      sessionAggregateSnapshotStore: SessionAggregateSnapshotStore(
        fileURL: directory.appendingPathComponent("session-aggregate-snapshots.json")
      ),
      unsentWindowLedgerFileURL: directory.appendingPathComponent("ledger.snapshot"),
      sensingCryptography: DeterministicSensingCryptography(),
      joinDiagnosticLog: { _ in },
      deviceSecretStore: deviceSecretStore
    )
    coordinator.useDemoEventMode = false
    return coordinator
  }
}
