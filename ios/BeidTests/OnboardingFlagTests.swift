// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import Beid

@MainActor
final class OnboardingFlagTests: XCTestCase {
  func testOnboardingStartsWithBluetoothPermission() {
    // Legacy feature flags must not introduce a wallet step.
    let coordinator = AppCoordinator()
    coordinator.beginOnboarding()

    XCTAssertEqual(coordinator.screen, .bluetoothPermission)
    XCTAssertNil(coordinator.walletAddress)
  }

  func testWalletFirstOrderReachesBluetoothPermissionAfterConnect() throws {
    guard OnboardingMode.current == .walletFirst else {
      throw XCTSkip("only applicable when OnboardingMode.current == .walletFirst")
    }
    let coordinator = AppCoordinator()
    coordinator.beginOnboarding()
    XCTAssertEqual(coordinator.screen, .bluetoothPermission)

    coordinator.completeWalletConnect(
      address: LiveWalletAddress.fromConnectorResult(address: "0xREALADDRESS", chainId: "eip155:1")
    )
    XCTAssertEqual(coordinator.walletAddress, "0xREALADDRESS")
    XCTAssertEqual(coordinator.screen, .bluetoothPermission)
  }

  func testLeavingLegacyCodeEntryReturnsToBluetoothWithoutWalletPresentation() {
    let coordinator = AppCoordinator()
    coordinator.screen = .eventCodeEntry
    coordinator.returnToBluetoothPermission()
    XCTAssertEqual(coordinator.screen, .bluetoothPermission)
    XCTAssertNil(coordinator.walletAddress)
  }

  func testGuestFirstOrderSkipsWalletStepInitially() throws {
    guard OnboardingMode.current == .guestFirst else {
      throw XCTSkip("only applicable when OnboardingMode.current == .guestFirst")
    }
    let coordinator = AppCoordinator()
    coordinator.beginOnboarding()
    XCTAssertEqual(coordinator.screen, .bluetoothPermission)
    XCTAssertNil(coordinator.walletAddress)
  }
}

final class AppVersionMetadataTests: XCTestCase {
  func testMissingShortVersionHasNoWelcomeFallback() throws {
    try withBundle(shortVersion: nil) { bundle in
      XCTAssertNil(AppVersion.shortVersion(bundle: bundle))
      XCTAssertEqual(AppVersion.displayString(bundle: bundle), "0.0.0 (local+42)")
    }
  }

  func testEmptyShortVersionIsOmitted() throws {
    try withBundle(shortVersion: "") { bundle in
      XCTAssertNil(AppVersion.shortVersion(bundle: bundle))
    }
  }

  func testNonemptyShortVersionComesFromBundleMetadata() throws {
    try withBundle(shortVersion: "9.8.7") { bundle in
      XCTAssertEqual(AppVersion.shortVersion(bundle: bundle), "9.8.7")
    }
  }

  func testNonStringShortVersionIsUnavailable() throws {
    try withBundle(shortVersion: 987) { bundle in
      XCTAssertNil(AppVersion.shortVersion(bundle: bundle))
    }
  }

  func testFullVersionRowKeepsItsExistingBuildFormat() throws {
    try withBundle(shortVersion: "9.8.7") { bundle in
      XCTAssertEqual(AppVersion.displayString(bundle: bundle), "9.8.7 (local+42)")
    }
  }

  private func withBundle(shortVersion: Any?, assertions: (Bundle) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString).appendingPathExtension("bundle")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    var metadata: [String: Any] = [
      "CFBundleIdentifier": "org.example.beid.metadata.\(UUID().uuidString)",
      "CFBundlePackageType": "BNDL",
      "CFBundleVersion": "42"
    ]
    metadata["CFBundleShortVersionString"] = shortVersion
    let data = try PropertyListSerialization.data(fromPropertyList: metadata, format: .xml, options: 0)
    try data.write(to: directory.appendingPathComponent("Info.plist"))
    try assertions(XCTUnwrap(Bundle(url: directory)))
  }
}

final class BluetoothPermissionPurposeTests: XCTestCase {
  func testAppBluetoothPurposeDescribesDeviceSignalsAndRecords() {
    for key in ["NSBluetoothAlwaysUsageDescription", "NSBluetoothPeripheralUsageDescription"] {
      XCTAssertEqual(
        Bundle.main.object(forInfoDictionaryKey: key) as? String,
        "beid uses Bluetooth to exchange signals with nearby devices and keep a record of what it observes.",
        "\(key) must describe nearby-device signals and recorded observations"
      )
    }
  }
}

@MainActor
final class AboutSensingPresentationTests: XCTestCase {
  func testExplicitCapabilityWinsOverTheDebugFixture() {
    XCTAssertFalse(capability(explicit: false, actual: true, setting: "on"))
    XCTAssertTrue(capability(explicit: true, actual: false, setting: "off"))
  }

  func testDebugFixtureSelectsBothPresentationStates() {
    let enabled = capability(actual: false, setting: "on")
    let disabled = capability(actual: true, setting: "off")
    #if DEBUG
    XCTAssertTrue(enabled)
    XCTAssertFalse(disabled)
    #else
    XCTAssertFalse(enabled)
    XCTAssertTrue(disabled)
    #endif
  }

  func testNonDebugPresentationIgnoresTheFixture() {
    XCTAssertTrue(AboutSensingView.submissionCapability(
      explicit: nil, actual: true,
      arguments: ["-beid-ui-test", "-beid-about-sending", "off"], debugBuild: false
    ))
    XCTAssertFalse(AboutSensingView.submissionCapability(
      explicit: nil, actual: false,
      arguments: ["-beid-ui-test", "-beid-about-sending", "on"], debugBuild: false
    ))
  }

  func testFixtureRequiresTheUITestArgument() {
    XCTAssertTrue(AboutSensingView.submissionCapability(
      explicit: nil, actual: true, arguments: ["-beid-about-sending", "off"], debugBuild: true
    ))
  }

  func testMissingMalformedOrAmbiguousFixtureUsesActualCapability() {
    let arguments = [
      ["-beid-ui-test"],
      ["-beid-ui-test", "-beid-about-sending"],
      ["-beid-ui-test", "-beid-about-sending", "ON"],
      ["-beid-ui-test", "-beid-about-sending", "true"],
      ["-beid-ui-test", "-beid-about-sending", "off "],
      ["-beid-ui-test", "-beid-about-sending", "off", "-beid-about-sending", "on"]
    ]
    for input in arguments {
      for actual in [false, true] {
        XCTAssertEqual(
          AboutSensingView.submissionCapability(
            explicit: nil, actual: actual, arguments: input, debugBuild: true
          ), actual
        )
      }
    }
  }

  private func capability(explicit: Bool? = nil, actual: Bool, setting: String) -> Bool {
    AboutSensingView.submissionCapability(
      explicit: explicit, actual: actual,
      arguments: ["-beid-ui-test", "-beid-about-sending", setting], debugBuild: true
    )
  }
}
