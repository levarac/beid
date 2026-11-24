// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

#if DEBUG
import Foundation
import Security
import XCTest
@testable import Beid

@MainActor
final class VenueDeviceSecretRecoveryTests: XCTestCase {
  func testSignedVenueResolvesTheSecretOnEveryRestartAndRefusesReadFailure() throws {
    let keychain = InMemoryDeviceSecretKeychain(storedData: Data(repeating: 0x11, count: 32))
    let broadcaster = BarnardVenueSignedContainerBroadcasting(deviceSecretStore: DeviceSecretKeychainStore(keychain: keychain))
    let permit = try VenueServingContractFixture.load().permit()
    try broadcaster.installAndStart(permit)
    broadcaster.clearAndStop()
    let reads = keychain.readCount
    keychain.readResults = [.failure(errSecInteractionNotAllowed)]

    XCTAssertThrowsError(try broadcaster.installAndStart(permit)) { error in
      XCTAssertTrue(error is DeviceSecretError)
    }
    XCTAssertEqual(keychain.readCount, reads + 1)
    XCTAssertEqual(keychain.addCount + keychain.writeCount, 0)

    keychain.storedData = Data(repeating: 0x22, count: 32)
    XCTAssertNoThrow(try broadcaster.installAndStart(permit))
    XCTAssertEqual(keychain.readCount, reads + 2)
    broadcaster.clearAndStop()
  }

  func testUnsignedVenueResolvesTheSecretOnEveryRestartAndRefusesReadFailure() throws {
    let keychain = InMemoryDeviceSecretKeychain(storedData: Data(repeating: 0x11, count: 32))
    let broadcaster = BarnardVenueDeviceBroadcasting(deviceSecretStore: DeviceSecretKeychainStore(keychain: keychain))
    try broadcaster.startBroadcasting(eventCode: "VENUE", label: "Desk")
    broadcaster.stopBroadcasting()
    let reads = keychain.readCount
    keychain.readResults = [.failure(errSecInteractionNotAllowed)]

    XCTAssertThrowsError(try broadcaster.startBroadcasting(eventCode: "VENUE", label: "Desk")) { error in
      XCTAssertTrue(error is DeviceSecretError)
    }
    XCTAssertEqual(keychain.readCount, reads + 1)
    XCTAssertEqual(keychain.addCount + keychain.writeCount, 0)
    broadcaster.stopBroadcasting()
  }

  func testSignedVenueShowsDeviceKeyFailureInsteadOfContainerRejection() async throws {
    let keychain = InMemoryDeviceSecretKeychain(
      storedData: Data(repeating: 0x11, count: 32), readResults: [.failure(errSecInteractionNotAllowed)]
    )
    let fixture = try VenueServingContractFixture.load()
    let verifier = ScriptedVenuePorts()
    verifier.importReplies = [.immediate(.imported(fixture.imported()))]
    verifier.evaluationReplies = [.immediate(.permitted(fixture.permit()))]
    let acquisition = StubVenueArtifactAcquisition()
    acquisition.replies = [.artifact(fixture.artifact)]
    let directory = try makeDirectory()
    let viewModel = VenueSignedServingViewModel(
      verifier: verifier,
      broadcasting: BarnardVenueSignedContainerBroadcasting(deviceSecretStore: DeviceSecretKeychainStore(keychain: keychain)),
      acquisition: acquisition,
      store: VenuePublicArtifactStore(fileURL: directory.appendingPathComponent("artifact.json")),
      clock: { .available(unixSeconds: VenueServingContractFixture.currentUnixSeconds) },
      expiry: FakeVenueExpiryScheduler()
    )

    await viewModel.supply(bundleSource: URL(string: "https://venue.example/bundle")!,
                           handoffSource: URL(string: "https://venue.example/handoff")!, sourceDescription: "venue.example")
    await viewModel.startBroadcasting()

    guard case .radioRefused(let failure) = viewModel.status else { return XCTFail("expected an explicit device key failure") }
    XCTAssertEqual(failure.rawValue, "deviceKeyUnavailable")
    XCTAssertEqual(viewModel.radio.failure?.rawValue, "deviceKeyUnavailable")
  }

  func testUnsignedVenueShowsDeviceKeyFailureInsteadOfInvalidLabel() throws {
    let keychain = InMemoryDeviceSecretKeychain(
      storedData: Data(repeating: 0x11, count: 32), readResults: [.failure(errSecInteractionNotAllowed)]
    )
    let directory = try makeDirectory()
    let viewModel = VenueDeviceOrganizerViewModel(
      broadcasting: BarnardVenueDeviceBroadcasting(deviceSecretStore: DeviceSecretKeychainStore(keychain: keychain)),
      store: VenueDeviceAssignmentStore(fileURL: directory.appendingPathComponent("assignments.json"))
    )
    viewModel.label = "Desk"
    viewModel.validityStart = Date(timeIntervalSince1970: 100)
    viewModel.validityEnd = Date(timeIntervalSince1970: 200)

    viewModel.toggleOn(eventCode: "VENUE")

    XCTAssertEqual(viewModel.validationError.map { String(describing: $0) }, "deviceKeyUnavailable")
    XCTAssertFalse(viewModel.isBroadcasting)
    XCTAssertTrue(viewModel.history.isEmpty)
    viewModel.toggleOn(eventCode: "VENUE")
    XCTAssertNil(viewModel.validationError)
    XCTAssertTrue(viewModel.isBroadcasting)
    viewModel.toggleOff()
  }

  private func makeDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    return directory
  }
}
#endif
