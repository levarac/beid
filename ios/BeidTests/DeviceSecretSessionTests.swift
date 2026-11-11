// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

#if DEBUG
import Barnard
import BarnardCore
import BeidSharedKit
import CryptoKit
import Foundation
import Security
import XCTest
@testable import Beid

@MainActor
final class DeviceSecretSessionTests: XCTestCase {
  func testManualJoinKeepsResolvedSecretAcrossPermissionWait() async throws {
    let keychain = InMemoryDeviceSecretKeychain(storedData: Data(repeating: 0x31, count: 32))
    let cryptography = makeCryptography(keychain)
    let engine = RecordingEventJoinControl()
    engine.permissionOutcome = .answersLate
    let eventIdHex = String(repeating: "a", count: 64)
    let registry = FakeEventJoinRegistry()
    registry.answer = .resolves(FakeEventJoinRegistry.admittingResolution(eventIdHex: eventIdHex))
    let coordinator = makeCoordinator(
      directory: try makeDirectory(), cryptography: cryptography,
      eventJoinControl: engine, eventJoinRegistry: registry
    )
    coordinator.useDemoEventMode = false
    coordinator.startSensing(eventCode: "SESSION", eventIdHex: eventIdHex)
    XCTAssertTrue(engine.isHoldingPermissionRequest)
    XCTAssertEqual(keychain.readCount, 1)
    let publicKey = try cryptography.eventSigningPublicKey(eventCode: eventIdHex)

    keychain.readResults = Array(repeating: .failure(errSecInteractionNotAllowed), count: 8)
    engine.grantHeldPermissionRequest()
    try await Task.sleep(nanoseconds: 20_000_000)

    XCTAssertEqual(engine.joinedCodes, [eventIdHex])
    XCTAssertNil(coordinator.joinRefusal)
    XCTAssertNil(coordinator.eventSigningKeyFailure)
    XCTAssertEqual(engine.stopAutomaticOperationCallCount, 0)
    XCTAssertEqual(keychain.readCount, 1)
    XCTAssertTrue(try cryptography.eventSigningPublicKey(eventCode: eventIdHex) == publicKey)
    XCTAssertEqual(keychain.addCount + keychain.writeCount, 0)
    _ = coordinator.stopSensing()
  }

  func testManualJoinKeepsResolvedSecretAcrossRegistryWait() async throws {
    let keychain = InMemoryDeviceSecretKeychain(storedData: Data(repeating: 0x31, count: 32))
    let cryptography = makeCryptography(keychain)
    let engine = RecordingEventJoinControl()
    engine.permissionOutcome = .granted
    let eventIdHex = String(repeating: "a", count: 64)
    let registry = FakeEventJoinRegistry()
    registry.answer = .holds
    let coordinator = makeCoordinator(
      directory: try makeDirectory(), cryptography: cryptography,
      eventJoinControl: engine, eventJoinRegistry: registry
    )
    coordinator.useDemoEventMode = false
    coordinator.startSensing(eventCode: "SESSION", eventIdHex: eventIdHex)
    try await Task.sleep(nanoseconds: 20_000_000)
    XCTAssertTrue(registry.isHoldingRead)
    XCTAssertFalse(engine.didJoin)
    XCTAssertEqual(keychain.readCount, 1)
    let publicKey = try cryptography.eventSigningPublicKey(eventCode: eventIdHex)

    keychain.readResults = Array(repeating: .failure(errSecInteractionNotAllowed), count: 8)
    registry.answerHeldRead(with: FakeEventJoinRegistry.admittingResolution(eventIdHex: eventIdHex))
    try await Task.sleep(nanoseconds: 20_000_000)

    XCTAssertEqual(engine.joinedCodes, [eventIdHex])
    XCTAssertNil(coordinator.joinRefusal)
    XCTAssertNil(coordinator.eventSigningKeyFailure)
    XCTAssertEqual(engine.stopAutomaticOperationCallCount, 0)
    XCTAssertEqual(keychain.readCount, 1)
    XCTAssertTrue(try cryptography.eventSigningPublicKey(eventCode: eventIdHex) == publicKey)
    XCTAssertEqual(keychain.addCount + keychain.writeCount, 0)
    _ = coordinator.stopSensing()
  }

  func testNearbyDiscoveryRestartsAfterAJoinCannotReadTheDeviceSecret() throws {
    let keychain = InMemoryDeviceSecretKeychain(storedData: Data(repeating: 0x31, count: 32))
    let engine = RecordingEventJoinControl()
    let coordinator = makeCoordinator(
      directory: try makeDirectory(), cryptography: makeCryptography(keychain), eventJoinControl: engine
    )
    coordinator.useDemoEventMode = false
    coordinator.startNearbyEventDiscovery()
    XCTAssertEqual(engine.startDiscoveryScanCallCount, 1)

    keychain.readResults = [.failure(errSecInteractionNotAllowed)]
    coordinator.joinNearbyEvent(eventCodeHashHex: String(repeating: "ab", count: 16))

    XCTAssertEqual(coordinator.phase, .idle)
    XCTAssertEqual(coordinator.joinRefusal, .eventSigningKeyUnavailable)
    XCTAssertEqual(coordinator.eventSigningKeyFailure, .unavailable)
    XCTAssertEqual(engine.stopAutomaticOperationCallCount, 1)
    XCTAssertEqual(engine.requestJoinPermissionsCallCount, 0)
    XCTAssertFalse(engine.didJoin)

    keychain.readResults = []
    coordinator.startNearbyEventDiscovery()

    XCTAssertEqual(engine.startDiscoveryScanCallCount, 2, "the stopped discovery scan must be restartable")
    XCTAssertNil(coordinator.eventSigningKeyFailure)
    XCTAssertEqual(keychain.readCount, 3)
    XCTAssertEqual(keychain.addCount + keychain.writeCount, 0)
    coordinator.stopNearbyEventDiscovery()
    coordinator.stopNearbyEventDiscovery()
    XCTAssertEqual(engine.stopDiscoveryScanCallCount, 1)
  }

  func testStoppingSensingReleasesDiscoveryScanOwnership() throws {
    let keychain = InMemoryDeviceSecretKeychain(storedData: Data(repeating: 0x31, count: 32))
    let engine = RecordingEventJoinControl()
    let coordinator = makeCoordinator(
      directory: try makeDirectory(), cryptography: makeCryptography(keychain), eventJoinControl: engine
    )
    coordinator.useDemoEventMode = false
    coordinator.startNearbyEventDiscovery()

    coordinator.stopSensing()
    coordinator.stopNearbyEventDiscovery()

    XCTAssertEqual(engine.stopAutomaticOperationCallCount, 1)
    XCTAssertEqual(engine.stopDiscoveryScanCallCount, 0, "automatic operation already stopped the owned scan")
    coordinator.startNearbyEventDiscovery()
    XCTAssertEqual(engine.startDiscoveryScanCallCount, 2)
    coordinator.stopNearbyEventDiscovery()
    XCTAssertEqual(engine.stopDiscoveryScanCallCount, 1)
  }

  func testResetPreservesOwnershipOfTheDiscoveryScanItLeavesRunning() throws {
    let keychain = InMemoryDeviceSecretKeychain(storedData: Data(repeating: 0x31, count: 32))
    let engine = RecordingEventJoinControl()
    let coordinator = makeCoordinator(
      directory: try makeDirectory(), cryptography: makeCryptography(keychain), eventJoinControl: engine
    )
    coordinator.useDemoEventMode = false
    coordinator.startNearbyEventDiscovery()

    coordinator.reset()
    coordinator.startNearbyEventDiscovery()

    XCTAssertEqual(engine.stopAutomaticOperationCallCount, 0)
    XCTAssertEqual(engine.startDiscoveryScanCallCount, 1)
    coordinator.stopNearbyEventDiscovery()
    XCTAssertEqual(engine.stopDiscoveryScanCallCount, 1)
  }

  func testParticipantEngineAndSignerShareOneResolutionBeforePermissions() throws {
    let keychain = InMemoryDeviceSecretKeychain(storedData: Data(repeating: 0x31, count: 32))
    let store = DeviceSecretKeychainStore(keychain: keychain)
    let cryptography = BarnardSensingCryptography(deviceSecretStore: store)
    let coordinator = makeCoordinator(
      directory: try makeDirectory(), cryptography: cryptography,
      eventJoinControl: nil, deviceSecretStore: store
    )
    coordinator.useDemoEventMode = false

    coordinator.startSensing(eventCode: "SESSION")
    _ = try cryptography.eventSigningPublicKey(eventCode: "SESSION")

    XCTAssertEqual(keychain.readCount, 1)
    XCTAssertNil(coordinator.eventSigningKeyFailure)
    _ = coordinator.stopSensing()
  }

  func testResolvedSessionSignsWithoutFurtherKeychainReads() throws {
    let keychain = InMemoryDeviceSecretKeychain(storedData: Data(repeating: 0x31, count: 32))
    let cryptography = makeCryptography(keychain)
    _ = try cryptography.prepareSession()
    let publicKey = try cryptography.eventSigningPublicKey(eventCode: "SESSION")
    let reads = keychain.readCount
    keychain.readResults = Array(repeating: .failure(errSecInteractionNotAllowed), count: 8)
    let payload = Data([0x01, 0x02])

    let signature = try cryptography.signWindowReport(eventCode: "SESSION", bytes: payload)

    let recovered = BarnardCoreSigning.recoverPublicKey(
      recoveryId: signature.v, r: Array(signature.r), s: Array(signature.s),
      messageHash32: Array(SHA256.hash(data: payload))
    )
    XCTAssertTrue(recovered == Array(publicKey), "the signature must use the session's resolved key")
    XCTAssertTrue(try cryptography.eventSigningPublicKey(eventCode: "SESSION") == publicKey)
    XCTAssertEqual(keychain.readCount, reads)
    XCTAssertEqual(keychain.addCount + keychain.writeCount, 0)
  }

  func testNextSessionResolvesAgainAndRefusesAnUnavailableKey() throws {
    let keychain = InMemoryDeviceSecretKeychain(storedData: Data(repeating: 0x31, count: 32))
    let cryptography = makeCryptography(keychain)
    _ = try cryptography.prepareSession()
    let oldKey = try cryptography.eventSigningPublicKey(eventCode: "SESSION")
    keychain.readResults = [.failure(errSecInteractionNotAllowed)]

    XCTAssertThrowsError(try cryptography.prepareSession())

    keychain.storedData = Data(repeating: 0x42, count: 32)
    _ = try cryptography.prepareSession()
    XCTAssertFalse(try cryptography.eventSigningPublicKey(eventCode: "SESSION") == oldKey)
    XCTAssertEqual(keychain.addCount + keychain.writeCount, 0)
  }

  func testSigningSnapshotSurvivesTheNextSession() throws {
    let keychain = InMemoryDeviceSecretKeychain(storedData: Data(repeating: 0x31, count: 32))
    let cryptography = makeCryptography(keychain)
    _ = try cryptography.prepareSession()
    let publicKey = try cryptography.eventSigningPublicKey(eventCode: "SESSION")
    let snapshot = try cryptography.signingSnapshot()
    keychain.storedData = Data(repeating: 0x42, count: 32)
    _ = try cryptography.prepareSession()
    keychain.readResults = [.failure(errSecInteractionNotAllowed)]

    XCTAssertTrue(try snapshot.eventSigningPublicKey(eventCode: "SESSION") == publicKey)
    let signature = try snapshot.signWindowReport(eventCode: "SESSION", bytes: Data([0x03]))
    XCTAssertTrue(BarnardCoreSigning.recoverPublicKey(
      recoveryId: signature.v, r: Array(signature.r), s: Array(signature.s),
      messageHash32: Array(SHA256.hash(data: Data([0x03])))
    ) == Array(publicKey))
  }

  func testParticipantWindowRotationBackgroundingAndStopKeepTheResolvedSecret() throws {
    let directory = try makeDirectory()
    let keychain = InMemoryDeviceSecretKeychain(storedData: Data(repeating: 0x31, count: 32))
    let cryptography = makeCryptography(keychain)
    let reports = WindowReportStore(fileURL: directory.appendingPathComponent("reports.json"))
    let coordinator = makeCoordinator(directory: directory, cryptography: cryptography, reports: reports)
    coordinator.useDemoEventMode = false
    coordinator.startSensing(eventCode: "SESSION")
    let publicKey = try cryptography.eventSigningPublicKey(eventCode: "SESSION")
    let reads = keychain.readCount
    keychain.readResults = Array(repeating: .failure(errSecInteractionNotAllowed), count: 20)

    for index in 0..<BeidConfig.eventConfirmThreshold {
      coordinator.handleDetection(enin: 1, rpid: "peer-\(index)",
                                  detectedDisplayId: DetectionFixture.displayId(device: index))
    }
    guard case .recording = coordinator.phase else { return XCTFail("recording must have started") }
    coordinator.handleDetection(enin: 2, rpid: "peer-next",
                                detectedDisplayId: DetectionFixture.displayId(device: 0))
    coordinator.checkpointOpenWindowForBackgrounding()
    coordinator.handleDetection(enin: 3, rpid: "peer-last",
                                detectedDisplayId: DetectionFixture.displayId(device: 0))
    let record = try XCTUnwrap(coordinator.stopSensing())

    XCTAssertEqual(reports.reports.count, 3)
    XCTAssertTrue(record.eventSigningPublicKeyHex == publicKey.map { String(format: "%02x", $0) }.joined())
    XCTAssertNil(coordinator.eventSigningKeyFailure)
    XCTAssertEqual(keychain.readCount, reads)

    coordinator.startSensing(eventCode: "SESSION")
    XCTAssertEqual(coordinator.phase, .idle)
    XCTAssertEqual(coordinator.eventSigningKeyFailure, .unavailable)
    XCTAssertEqual(keychain.addCount + keychain.writeCount, 0)
  }

  func testDemoRefusesToStartWhenTheSigningSecretIsUnavailable() throws {
    let keychain = InMemoryDeviceSecretKeychain(readResults: [.failure(errSecInteractionNotAllowed)])
    let coordinator = makeCoordinator(directory: try makeDirectory(), cryptography: makeCryptography(keychain))
    coordinator.useDemoEventMode = true

    coordinator.runDemoSequence(demoEvent: EventSession(id: "SESSION", name: "Session", venue: nil), stepDelayNanos: 0)

    XCTAssertEqual(coordinator.phase, .idle)
    XCTAssertEqual(coordinator.eventSigningKeyFailure, .unavailable)
    XCTAssertEqual(keychain.addCount + keychain.writeCount, 0)
  }

  func testUnavailableLaunchCheckpointIsPreservedUntilAStartCanResolveTheSecret() throws {
    let directory = try makeDirectory()
    let proofId = UUID()
    let checkpointURL = directory.appendingPathComponent("checkpoint.json")
    SelfProofCheckpointStore(fileURL: checkpointURL).save(SelfProofCheckpoint(
      proofId: proofId, eventCode: "PREVIOUS", eninStart: 1, eninEnd: 2
    ))
    let keychain = InMemoryDeviceSecretKeychain(
      storedData: Data(repeating: 0x31, count: 32),
      readResults: [.failure(errSecInteractionNotAllowed), .failure(errSecInteractionNotAllowed)]
    )
    let coordinator = makeCoordinator(directory: directory, cryptography: makeCryptography(keychain))
    coordinator.useDemoEventMode = false
    XCTAssertEqual(coordinator.eventSigningKeyFailure, .unavailable)

    coordinator.startSensing(eventCode: "NEXT")
    XCTAssertEqual(coordinator.phase, .idle)
    XCTAssertEqual(SelfProofCheckpointStore(fileURL: checkpointURL).checkpoint?.proofId, proofId)

    coordinator.startSensing(eventCode: "NEXT")

    XCTAssertNil(coordinator.eventSigningKeyFailure)
    XCTAssertNil(SelfProofCheckpointStore(fileURL: checkpointURL).checkpoint)
    XCTAssertNotNil(SelfProofStore(fileURL: directory.appendingPathComponent("self-proofs.json")).record(forProofId: proofId))
    _ = coordinator.stopSensing()
  }

  func testDelayedCanonicalCaptureUsesTheSecretResolvedBeforeDefinitionLookup() async throws {
    let directory = try makeDirectory()
    let keychain = InMemoryDeviceSecretKeychain(storedData: Data(repeating: 0x31, count: 32))
    let cryptography = makeCryptography(keychain)
    _ = try cryptography.prepareSession()
    let publicKey = try cryptography.eventSigningPublicKey(eventCode: "SESSION")
    let provider = DelayedDeviceSecretDefinitionProvider()
    let receiptKeyHex = "02c6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee5"
    let server = try StubOperatorServer(
      eventId: Data(repeating: 0x11, count: 32),
      signingPrivateKey: [UInt8](repeating: 0, count: 31) + [2],
      signingPublicKey: hexData(receiptKeyHex)
    )
    defer { server.stop() }
    let endpoint = try await server.start()
    let configuration = try XCTUnwrap(ExportedKotlinPackages.org.levarac.parallax.submission
      .createSubmissionOperatorConfiguration(
        endpoint: endpoint.absoluteString, receiptPublicKeyHex: receiptKeyHex,
        eventIdHex: String(repeating: "11", count: 32),
        eventDefinitionDigestHex: String(repeating: "22", count: 32),
        validFrom: nil, validUntil: nil, allowInsecureLoopbackForTests: true
      ))
    let store = ReportSubmissionStore(fileURL: directory.appendingPathComponent("submissions.json"))
    let runtime = try XCTUnwrap(ReportSubmissionRuntime.makeIfEnabled(
      bundle: try enabledBundle(in: directory), eventSigningCryptography: cryptography,
      definitionProvider: provider, store: store, allowInsecureLoopbackForTests: true
    ))
    defer { runtime.stop() }
    runtime.captureAndQueueWindow(
      id: UUID(), eventCode: "SESSION", eventIdHex: String(repeating: "11", count: 32),
      enin: 1, peerRpids: ["01" + String(repeating: "aa", count: 16)],
      reporterRpid: "01" + String(repeating: "bb", count: 16),
      participantCommitment: Data(repeating: 0x55, count: 32)
    )
    let completion = try XCTUnwrap(provider.completion)
    keychain.storedData = Data(repeating: 0x42, count: 32)
    _ = try cryptography.prepareSession()
    let reads = keychain.readCount
    keychain.readResults = Array(repeating: .failure(errSecInteractionNotAllowed), count: 8)

    completion(VerifiedSubmissionDefinition(configuration: configuration))
    try await server.waitFor(postCount: 1)

    let record = try XCTUnwrap(store.records.first)
    XCTAssertTrue(record.signedObservationHex.contains(publicKey.map { String(format: "%02x", $0) }.joined()))
    XCTAssertEqual(keychain.readCount, reads)
    XCTAssertNil(runtime.eventSigningKeyFailure)
    XCTAssertTrue(store.pendingCaptures.isEmpty)
  }

  func testCanonicalCaptureWithoutAResolvedSecretRemainsDurableWhenTheKeyIsUnavailable() throws {
    let directory = try makeDirectory()
    let fileURL = directory.appendingPathComponent("submissions.json")
    let store = ReportSubmissionStore(fileURL: fileURL)
    let keychain = InMemoryDeviceSecretKeychain(
      storedData: Data(repeating: 0x31, count: 32),
      readResults: Array(repeating: .failure(errSecInteractionNotAllowed), count: 8)
    )
    let provider = DelayedDeviceSecretDefinitionProvider()
    let runtime = try XCTUnwrap(ReportSubmissionRuntime.makeIfEnabled(
      bundle: try enabledBundle(in: directory), eventSigningCryptography: makeCryptography(keychain),
      definitionProvider: provider, store: store
    ))
    defer { runtime.stop() }

    runtime.captureAndQueueWindow(
      id: UUID(), eventCode: "PREVIOUS", eventIdHex: String(repeating: "11", count: 32),
      enin: 1, peerRpids: ["01" + String(repeating: "aa", count: 16)],
      reporterRpid: "01" + String(repeating: "bb", count: 16), participantCommitment: nil
    )

    XCTAssertEqual(runtime.eventSigningKeyFailure, .unavailable)
    XCTAssertEqual(ReportSubmissionStore(fileURL: fileURL).pendingCaptures.count, 1)
    XCTAssertTrue(store.records.isEmpty)
    XCTAssertNil(provider.completion)
    XCTAssertEqual(keychain.addCount + keychain.writeCount, 0)
  }

  private func makeCryptography(_ keychain: InMemoryDeviceSecretKeychain) -> BarnardSensingCryptography {
    BarnardSensingCryptography(
      ownerKeyProvider: OwnerKeyProvider(keyStorage: SessionOwnerKeyStorage()),
      deviceSecretStore: DeviceSecretKeychainStore(keychain: keychain)
    )
  }

  private func makeCoordinator(
    directory: URL, cryptography: BarnardSensingCryptography, reports: WindowReportStore? = nil,
    eventJoinControl: (any EventJoinControlling)? = SessionJoinControl(),
    eventJoinRegistry: (any EventJoinRegistry)? = nil,
    deviceSecretStore: DeviceSecretKeychainStore = .shared
  ) -> SensingCoordinator {
    SensingCoordinator(
      windowReportStore: reports ?? WindowReportStore(fileURL: directory.appendingPathComponent("reports.json")),
      selfProofStore: SelfProofStore(fileURL: directory.appendingPathComponent("self-proofs.json")),
      selfProofCheckpointStore: SelfProofCheckpointStore(fileURL: directory.appendingPathComponent("checkpoint.json")),
      bindingRecordStore: BindingRecordStore(fileURL: directory.appendingPathComponent("bindings.json")),
      sessionAggregateSnapshotStore: SessionAggregateSnapshotStore(fileURL: directory.appendingPathComponent("aggregate.json")),
      unsentWindowLedgerFileURL: directory.appendingPathComponent("ledger.snapshot"),
      sensingCryptography: cryptography, eventJoinControl: eventJoinControl,
      eventJoinRegistry: eventJoinRegistry, joinDiagnosticLog: { _ in },
      deviceSecretStore: deviceSecretStore
    )
  }

  private func makeDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    return directory
  }

  private func enabledBundle(in directory: URL) throws -> Bundle {
    let url = directory.appendingPathComponent("enabled.bundle", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    let data = try PropertyListSerialization.data(fromPropertyList: [
      "CFBundleIdentifier": "org.levarac.beid.tests.\(UUID().uuidString)",
      "CFBundlePackageType": "BNDL", "BeidReportSubmissionEnabled": "1"
    ], format: .xml, options: 0)
    try data.write(to: url.appendingPathComponent("Info.plist"))
    return try XCTUnwrap(Bundle(url: url))
  }

  private func hexData(_ value: String) -> Data {
    var bytes: [UInt8] = []
    var index = value.startIndex
    while index < value.endIndex {
      let next = value.index(index, offsetBy: 2)
      bytes.append(UInt8(value[index..<next], radix: 16)!)
      index = next
    }
    return Data(bytes)
  }
}

private struct SessionOwnerKeyStorage: OwnerKeySeedResolving {
  func bytes(forKey key: String) -> [UInt8]? { [UInt8](repeating: 0x53, count: 32) }
  func setBytes(_ bytes: [UInt8], forKey key: String) {}
  func resolveSeed(forKey key: String, randomSource: any OwnerKeyRandomBytesGenerating) throws -> [UInt8] {
    [UInt8](repeating: 0x53, count: 32)
  }
}

private final class SessionJoinControl: EventJoinControlling {
  var onEvent: ((Barnard.BarnardEvent) -> Void)?
  func requestJoinPermissions(_ completion: @escaping (Bool, Bool) -> Void) {}
  func startDiscoveryScan() {}
  func stopDiscoveryScan() {}
  func joinAndStart(_ context: ExportedKotlinPackages.org.levarac.parallax.discovery.RegistryVerifiedJoinContext) {}
  func leaveJoinedEvent() {}
  func stopAutomaticOperation() {}
  func currentJoinedEventCode() -> String? { nil }
}

@MainActor
private final class DelayedDeviceSecretDefinitionProvider: EventDefinitionContextProvider {
  var completion: ((VerifiedSubmissionDefinition?) -> Void)?
  func resolve(eventIdHex: String, completion: @escaping (VerifiedSubmissionDefinition?) -> Void) {
    self.completion = completion
  }
}
#endif
