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
#if DEBUG
@MainActor
final class DeviceSecretConstructionGuardTests: XCTestCase {
  private let legacyKey = "barnard.rpidSeed"

  override func tearDown() {
    UserDefaults.standard.removeObject(forKey: legacyKey)
    super.tearDown()
  }

  func testSecretStorageAssertionsDoNotDescribeStoredValues() throws {
    let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let unsafeAssertion = try NSRegularExpression(
      pattern: #"\bXCTAssert(?:Equal|NotEqual|Nil|NotNil)\s*\(\s*(?:try\s+)?"#
        + #"(?:UserDefaults\.standard\.object|(?:storage\.)?defaults\.(?:object|data|string)|"#
        + #"storage\.(?:bytes|resolveSeed)|keychain\.storedData|keychain\.lastWrite(?!\?\.|\.)|"#
        + #"resolved\b|regenerated\s+as\s+NSObject)"#
    )
    for name in [
      "DeviceSecretConstructionGuardTests.swift",
      "DeviceSecretKeychainStoreTests.swift",
      "OwnerKeyKeychainTests.swift",
      "OwnerKeyProviderTests.swift",
    ] {
      let source = try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
      XCTAssertTrue(
        unsafeAssertion.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)) == nil,
        "\(name): compare secret storage values as Booleans so failures cannot describe them"
      )
    }
  }

  func testNoAppSourceConstructsBarnardWithItsDefaultStorage() throws {
    let root = try XCTUnwrap(Bundle(for: Self.self).resourceURL).appendingPathComponent("Beid")
    let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
    var scanned = 0
    var offenders: [String] = []
    while let url = enumerator?.nextObject() as? URL {
      guard url.pathExtension == "swift" else { continue }
      scanned += 1
      let text = try String(contentsOf: url, encoding: .utf8)
      if try !defaultStorageConstructions(in: text).isEmpty {
        offenders.append(url.lastPathComponent)
      }
    }
    XCTAssertGreaterThan(scanned, 100, "the scan must have read the app sources")
    XCTAssertEqual(
      offenders,
      [],
      "build Barnard objects from DeviceSecretKeychainStore, never with BarnardIdentity() or BarnardEngine()"
    )
  }

  func testConstructionScannerRejectsNonemptyArgumentsWithoutInjectedStorage() throws {
    for source in [
      "BarnardEngine()",
      "BarnardEngine(configuration: makeConfiguration())",
      "Barnard.BarnardEngine . init(configuration: makeConfiguration())",
      "BarnardIdentity.init(randomSource: makeRandom())",
      "BarnardEngine(configuration: makeOptions(keyStorage: storage))",
      "BarnardEngine(configuration: \"keyStorage: storage\")",
      "BarnardEngine(/* keyStorage: storage */ configuration: options)",
    ] {
      XCTAssertEqual(try defaultStorageConstructions(in: source).count, 1, source)
    }
  }

  func testConstructionScannerAcceptsInjectedStorageAndIgnoresCommentsAndStrings() throws {
    for source in [
      "BarnardEngine(keyStorage: try store.resolve())",
      "BarnardEngine(configuration: makeConfiguration(), keyStorage: storage)",
      "BarnardEngine(configuration: { makeOptions(a: 1, b: 2) }, keyStorage: try store.resolve())",
      "BarnardIdentity.init(keyStorage: makeStorage(options: [1, 2]))",
      "// BarnardEngine()",
      "/* BarnardIdentity() */",
      "let example = \"BarnardEngine(configuration: options)\"",
    ] {
      XCTAssertTrue(try defaultStorageConstructions(in: source).isEmpty, source)
    }
  }

  func testSignedContainerConstructionGuardActuallyStartsTheEngine() throws {
    let keychain = InMemoryDeviceSecretKeychain(storedData: Data(repeating: 0x11, count: 32))
    try exerciseSignedContainerStart(deviceSecretStore: DeviceSecretKeychainStore(keychain: keychain))
    XCTAssertEqual(keychain.readCount, 1, "the guard must reach engine construction inside installAndStart")
  }

  private func exerciseSignedContainerStart(deviceSecretStore: DeviceSecretKeychainStore) throws {
    let signedContainer = BarnardVenueSignedContainerBroadcasting(deviceSecretStore: deviceSecretStore)
    defer { signedContainer.clearAndStop() }
    try signedContainer.installAndStart(VenueServingContractFixture.load().permit())
  }

  private func defaultStorageConstructions(in source: String) throws -> [String] {
    // Remove literals and comments before checking argument labels, so neither
    // an example nor a nested call can masquerade as injected storage.
    let nonCode = try NSRegularExpression(pattern: #"(?s)//[^\n]*|/\*.*?\*/|"(?:\\.|[^"\\])*""#)
    let code = nonCode.stringByReplacingMatches(
      in: source, range: NSRange(source.startIndex..., in: source), withTemplate: " "
    )
    let constructors = try NSRegularExpression(
      pattern: #"\bBarnard(?:Identity|Engine)\s*(?:\.\s*init\s*)?\("#
    )
    let storageLabel = try NSRegularExpression(pattern: #"^\s*keyStorage\s*:"#)
    var offenders: [String] = []
    for match in constructors.matches(in: code, range: NSRange(code.startIndex..., in: code)) {
      guard let range = Range(match.range, in: code) else { continue }
      var depth = 0
      var start = range.upperBound
      var injected = false
      var closed = false
      for index in code.indices where index >= start {
        let character = code[index]
        if depth == 0, character == "," || character == ")" {
          let argument = String(code[start..<index])
          if storageLabel.firstMatch(in: argument, range: NSRange(argument.startIndex..., in: argument)) != nil {
            injected = true
          }
          start = code.index(after: index)
          if character == ")" { closed = true; break }
        } else if character == "(" || character == "[" || character == "{" {
          depth += 1
        } else if character == ")" || character == "]" || character == "}" {
          depth -= 1
        }
      }
      if !closed || !injected { offenders.append(String(code[range])) }
    }
    return offenders
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

    try exerciseSignedContainerStart(deviceSecretStore: .shared)

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

#endif
