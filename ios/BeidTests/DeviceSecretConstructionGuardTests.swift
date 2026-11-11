// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import Barnard
import BarnardCore
import Foundation
import XCTest
@testable import Beid

/// Every Barnard object the app builds must read the device secret through
/// `DeviceSecretKeychainStore`. Barnard's argument-free initializers fall back
/// to a `UserDefaults` storage that creates a new secret whenever a read
/// returns nil, so one such call anywhere would bring back both the backed-up
/// copy and the silent replacement.
///
/// Two checks, because each misses what the other catches. The source scan
/// sees a construction site nobody exercises; the runtime check sees a
/// default reached in a way the text does not show.
@MainActor
final class DeviceSecretConstructionGuardTests: XCTestCase {
  private let legacyKey = "barnard.rpidSeed"

  override func tearDown() {
    UserDefaults.standard.removeObject(forKey: legacyKey)
    super.tearDown()
  }

  func testNoAppSourceConstructsBarnardWithItsDefaultStorage() throws {
    let root = try XCTUnwrap(Bundle(for: Self.self).resourceURL).appendingPathComponent("Beid")
    let pattern = try NSRegularExpression(pattern: #"\bBarnard(Identity|Engine)(\.init)?\s*\(\s*\)"#)
    let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
    var scanned = 0
    var offenders: [String] = []
    while let url = enumerator?.nextObject() as? URL {
      guard url.pathExtension == "swift" else { continue }
      scanned += 1
      let text = try String(contentsOf: url, encoding: .utf8)
      for (index, line) in text.components(separatedBy: "\n").enumerated() {
        // Comments may name the initializer; only code may not.
        let code = line.components(separatedBy: "//").first ?? ""
        let range = NSRange(code.startIndex..., in: code)
        if pattern.firstMatch(in: code, range: range) != nil {
          offenders.append("\(url.lastPathComponent):\(index + 1)")
        }
      }
    }
    XCTAssertGreaterThan(scanned, 100, "the scan must have read the app sources")
    XCTAssertEqual(
      offenders,
      [],
      "build Barnard objects from DeviceSecretKeychainStore, never with BarnardIdentity() or BarnardEngine()"
    )
  }

  func testStartupDeletesTheLegacyValue() throws {
    let root = try XCTUnwrap(Bundle(for: Self.self).resourceURL)
    let source = try String(contentsOf: root.appendingPathComponent("Beid/App/BeidApp.swift"), encoding: .utf8)
    XCTAssertTrue(source.contains("DeviceSecretKeychainStore.removeLegacyUserDefaultsCopy(from: .standard)"))
  }

  func testProductionConstructionPathsNeverRecreateTheUserDefaultsSecret() throws {
    UserDefaults.standard.removeObject(forKey: legacyKey)

    let cryptography = BarnardSensingCryptography()
    _ = try cryptography.eventSigningPublicKey(eventCode: "GUARD-EVENT")
    _ = try cryptography.signWindowReport(eventCode: "GUARD-EVENT", bytes: Data([0x01, 0x02]))

    let coordinator = makeIsolatedSensingCoordinator(for: self)
    coordinator.useDemoEventMode = false
    coordinator.startNearbyEventDiscovery()

    let venueDevice = BarnardVenueDeviceBroadcasting()
    try venueDevice.startBroadcasting(eventCode: "GUARD-EVENT", label: "Guard Desk")
    venueDevice.stopBroadcasting()

    let signedContainer = BarnardVenueSignedContainerBroadcasting()
    signedContainer.clearAndStop()

    XCTAssertNil(
      UserDefaults.standard.object(forKey: legacyKey),
      "a Barnard object built with its default storage recreated the UserDefaults secret"
    )
  }

  func testProductionSignerNeverReadsTheLegacyUserDefaultsSecret() throws {
    let legacySecret = [UInt8](repeating: 0x6C, count: 32)
    UserDefaults.standard.set(Data(legacySecret), forKey: legacyKey)
    let keyFromLegacySecret = BarnardIdentity(keyStorage: FixedSecretStorage(secret: legacySecret))
      .signingPublicKey(eventCode: "LEGACY-EVENT")

    let productionKey = try BarnardSensingCryptography().eventSigningPublicKey(eventCode: "LEGACY-EVENT")

    XCTAssertFalse(
      productionKey == keyFromLegacySecret,
      "the event signing key must not come from the old UserDefaults value"
    )
  }
}

/// Answers every read with one fixed secret.
private struct FixedSecretStorage: BarnardCoreKeyStorage {
  let secret: [UInt8]

  func bytes(forKey key: String) -> [UInt8]? { secret }
  func setBytes(_ bytes: [UInt8], forKey key: String) {}
}
