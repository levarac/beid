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
  func testCheckpointDiscardNoticeWaitsForRemoval() throws {
    try assertCheckpointDiscardNoticeWaitsForRemoval(parentDecisionAlreadySaved: false)
  }

  func testCheckpointDiscardNoticeWaitsForRemovalOnRelaunch() throws {
    try assertCheckpointDiscardNoticeWaitsForRemoval(parentDecisionAlreadySaved: true)
  }

  private func assertCheckpointDiscardNoticeWaitsForRemoval(parentDecisionAlreadySaved: Bool) throws {
    let directory = try makeDirectory()
    let keychain = InMemoryDeviceSecretKeychain(storedData: Data(repeating: 0x31, count: 32))
    let publicKey = try makeCryptography(keychain).eventSigningPublicKey(eventCode: "PREVIOUS")
    let proofId = try seedCheckpoint(in: directory, publicKey: publicKey)
    let parentURL = directory.appendingPathComponent("proofs.json")
    if parentDecisionAlreadySaved {
      try ProofStore(fileURL: parentURL).discardSelfProofForKeyChange(for: proofId)
    }
    let checkpointURL = directory.appendingPathComponent("checkpoint.json")
    var removalFails = true
    let checkpoints = SelfProofCheckpointStore(fileURL: checkpointURL, removeFile: { url in
      if removalFails { throw CocoaError(.fileWriteNoPermission) }
      try FileManager.default.removeItem(at: url)
    })
    keychain.storedData = Data(repeating: 0x42, count: 32)
    let coordinator = makeCoordinator(
      directory: directory, cryptography: makeCryptography(keychain), checkpointStore: checkpoints
    )

    XCTAssertEqual(coordinator.eventSigningKeyFailure, .discardFailed)
    XCTAssertNil(coordinator.eventSigningKeyNoticeEventCode)
    XCTAssertEqual(SelfProofCheckpointStore(fileURL: checkpointURL).checkpoint?.proofId, proofId)
    XCTAssertTrue(try XCTUnwrap(ProofStore(fileURL: parentURL).proof(withId: proofId)).selfProofDiscardedForKeyChange)
    XCTAssertTrue(SelfProofStore(fileURL: directory.appendingPathComponent("self-proofs.json")).records.isEmpty)

    removalFails = false
    keychain.storedData = Data(repeating: 0x31, count: 32)
    coordinator.useDemoEventMode = false
    coordinator.startSensing(eventCode: "NEXT")

    XCTAssertNil(SelfProofCheckpointStore(fileURL: checkpointURL).checkpoint)
    XCTAssertEqual(coordinator.eventSigningKeyFailure, .changed)
    XCTAssertEqual(coordinator.eventSigningKeyNoticeEventCode, "PREVIOUS")
    XCTAssertTrue(SelfProofStore(fileURL: directory.appendingPathComponent("self-proofs.json")).records.isEmpty)
    coordinator.dismissEventSigningKeyFailure()
    XCTAssertNil(coordinator.eventSigningKeyFailure)
    let relaunched = makeCoordinator(directory: directory, cryptography: makeCryptography(keychain))
    XCTAssertNil(relaunched.eventSigningKeyFailure)
  }

  func testOrphanCheckpointIsDiscardedOnceWithoutBlockingLaterJoins() throws {
    let directory = try makeDirectory()
    let keychain = InMemoryDeviceSecretKeychain(storedData: Data(repeating: 0x31, count: 32))
    let publicKey = try makeCryptography(keychain).eventSigningPublicKey(eventCode: "PREVIOUS")
    _ = try seedCheckpoint(in: directory, publicKey: publicKey)
    try FileManager.default.removeItem(at: directory.appendingPathComponent("proofs.json"))
    let reads = keychain.readCount
    let engine = RecordingEventJoinControl()
    engine.permissionOutcome = .answersLate

    let coordinator = makeCoordinator(
      directory: directory, cryptography: makeCryptography(keychain), eventJoinControl: engine
    )

    XCTAssertNil(SelfProofCheckpointStore(fileURL: directory.appendingPathComponent("checkpoint.json")).checkpoint)
    XCTAssertTrue(SelfProofStore(fileURL: directory.appendingPathComponent("self-proofs.json")).records.isEmpty)
    XCTAssertEqual(keychain.readCount, reads)
    XCTAssertEqual(
      coordinator.eventSigningKeyFailure?.message,
      "A record from an earlier session could not be checked and was discarded."
    )
    coordinator.useDemoEventMode = false
    coordinator.startSensing(eventCode: "NEXT")
    XCTAssertTrue(engine.isHoldingPermissionRequest)
    XCTAssertNil(coordinator.joinRefusal)
    XCTAssertEqual(coordinator.eventSigningKeyNoticeEventCode, "PREVIOUS")
    coordinator.dismissEventSigningKeyFailure()
    XCTAssertNil(coordinator.eventSigningKeyFailure)

    let relaunched = makeCoordinator(directory: directory, cryptography: makeCryptography(keychain))
    XCTAssertNil(relaunched.eventSigningKeyFailure)
    XCTAssertTrue(SelfProofStore(fileURL: directory.appendingPathComponent("self-proofs.json")).records.isEmpty)
  }

  func testManualJoinUsesTheHumanCodeForWindowAndSelfProofSigning() async throws {
    let directory = try makeDirectory()
    let humanCode = "SESSION"
    let eventIdHex = String(repeating: "11", count: 32)
    let keychain = InMemoryDeviceSecretKeychain(storedData: Data(repeating: 0x31, count: 32))
    let cryptography = makeCryptography(keychain)
    let engine = RecordingEventJoinControl()
    engine.permissionOutcome = .granted
    let registry = FakeEventJoinRegistry()
    registry.answer = .resolves(FakeEventJoinRegistry.admittingResolution(eventIdHex: eventIdHex))
    let reports = WindowReportStore(fileURL: directory.appendingPathComponent("reports.json"))
    let store = ReportSubmissionStore(fileURL: directory.appendingPathComponent("submissions.json"))
    let provider = DelayedDeviceSecretDefinitionProvider()
    let runtime = try XCTUnwrap(ReportSubmissionRuntime.makeIfEnabled(
      bundle: try enabledBundle(in: directory), eventSigningCryptography: cryptography,
      definitionProvider: provider, store: store, allowInsecureLoopbackForTests: true
    ))
    defer { runtime.stop() }
    let coordinator = makeCoordinator(
      directory: directory, cryptography: cryptography, reports: reports,
      eventJoinControl: engine, eventJoinRegistry: registry, reportSubmissionRuntime: runtime
    )
    coordinator.useDemoEventMode = false
    coordinator.startSensing(eventCode: humanCode, eventIdHex: eventIdHex)
    try await Task.sleep(nanoseconds: 20_000_000)
    XCTAssertEqual(engine.joinedCodes, [eventIdHex])
    let publicKey = try cryptography.eventSigningPublicKey(eventCode: humanCode)
    XCTAssertFalse(try cryptography.eventSigningPublicKey(eventCode: eventIdHex) == publicKey)
    let reads = keychain.readCount
    keychain.readResults = Array(repeating: .failure(errSecInteractionNotAllowed), count: 20)
    let reporterRpid = "01" + String(repeating: "bb", count: 16)
    for index in 0..<BeidConfig.eventConfirmThreshold {
      coordinator.handleDetection(
        enin: 1, rpid: "01" + String(format: "%032x", index + 1),
        detectedDisplayId: DetectionFixture.displayId(device: index), reporterRpid: reporterRpid
      )
    }
    guard case .recording(let session, _) = coordinator.phase else {
      return XCTFail("recording must have started")
    }
    XCTAssertEqual(session.id, humanCode)
    coordinator.handleDetection(
      enin: 2, rpid: "01" + String(repeating: "cc", count: 16),
      detectedDisplayId: DetectionFixture.displayId(device: 0), reporterRpid: reporterRpid
    )
    let checkpoint = try XCTUnwrap(SelfProofCheckpointStore(
      fileURL: directory.appendingPathComponent("checkpoint.json")
    ).checkpoint)
    XCTAssertEqual(checkpoint.eventCode, humanCode)
    XCTAssertTrue(checkpoint.eventSigningPublicKey == publicKey)
    let capture = try XCTUnwrap(ReportSubmissionStore(
      fileURL: directory.appendingPathComponent("submissions.json")
    ).pendingCaptures.first)
    XCTAssertEqual(capture.eventCode, humanCode)
    XCTAssertEqual(capture.eventIdHex, eventIdHex)
    XCTAssertTrue(capture.eventSigningPublicKey == publicKey)
    XCTAssertTrue(store.exclusions.isEmpty)
    let report = try XCTUnwrap(reports.reports.first)
    var payload = Data(humanCode.utf8)
    payload.append(contentsOf: withUnsafeBytes(of: Int64(1).bigEndian) { Array($0) })
    payload.append(hexData(report.commitHex))
    for rpid in capture.peerRpids.sorted() { payload.append(contentsOf: rpid.utf8) }
    XCTAssertTrue(BarnardCoreSigning.recoverPublicKey(
      recoveryId: report.signatureV, r: Array(hexData(report.signatureRHex)),
      s: Array(hexData(report.signatureSHex)), messageHash32: Array(SHA256.hash(data: payload))
    ) == Array(publicKey))

    let receiptKeyHex = "02c6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee5"
    let server = try StubOperatorServer(
      eventId: Data(repeating: 0x11, count: 32),
      signingPrivateKey: [UInt8](repeating: 0, count: 31) + [2], signingPublicKey: hexData(receiptKeyHex)
    )
    defer { server.stop() }
    let endpoint = try await server.start()
    let configuration = try XCTUnwrap(ExportedKotlinPackages.org.levarac.parallax.submission
      .createSubmissionOperatorConfiguration(
        endpoint: endpoint.absoluteString, receiptPublicKeyHex: receiptKeyHex,
        eventIdHex: eventIdHex, eventDefinitionDigestHex: String(repeating: "22", count: 32),
        validFrom: nil, validUntil: nil, allowInsecureLoopbackForTests: true
      ))
    try XCTUnwrap(provider.completion)(VerifiedSubmissionDefinition(configuration: configuration))
    try await server.waitFor(postCount: 1)
    let signed = try XCTUnwrap(store.records.first)
    let evidence = try XCTUnwrap(ExportedKotlinPackages.org.levarac.parallax.observation
      .createMutualSensingWindowEvidence(
        idHex: capture.id.uuidString.replacingOccurrences(of: "-", with: "").lowercased(), eventIdHex: eventIdHex,
        eventDefinitionDigestHex: String(repeating: "22", count: 32), observerHex: hexString(publicKey),
        finalizedAt: capture.finalizedAt, reporterRpidHex: capture.reporterRpid, enin: Int64(capture.enin),
        observedRpidHexes: capture.peerRpids, rpidClaimHex: nil,
        participantCommitmentHex: capture.participantCommitment.map { hexString($0) }, legacyPeerCount: nil
      ))
    let eligible = try XCTUnwrap(ExportedKotlinPackages.org.levarac.parallax.observation
      .prepareMutualSensingObservation(evidence: evidence) as?
      ExportedKotlinPackages.org.levarac.parallax.observation.ObservationPreparationResult.Eligible)
    let digest = Array(SHA256.hash(data: Data(kotlinBytes: eligible.prepared.signatureStructure.toByteArray())))
    let compact = hexData(signed.signedObservationHex).suffix(64)
    XCTAssertEqual(signed.eventCode, humanCode)
    XCTAssertTrue((0...1).contains { recoveryId in
      BarnardCoreSigning.recoverPublicKey(
        recoveryId: recoveryId, r: Array(compact.prefix(32)), s: Array(compact.suffix(32)), messageHash32: digest
      ) == Array(publicKey)
    })

    let record = try XCTUnwrap(coordinator.stopSensing())
    XCTAssertEqual(record.eventCode, humanCode)
    XCTAssertTrue(record.eventIdHashHex == hexString(EventIdHash.compute(eventCode: humanCode)))
    XCTAssertTrue(record.eventSigningPublicKeyHex == hexString(publicKey))
    XCTAssertTrue(BarnardCoreSigning.verifySelfProof(
      eventIdHash: Array(hexData(record.eventIdHashHex)), eventSigningPublicKey: Array(publicKey),
      eninStart: record.eninStart, eninEnd: record.eninEnd, ownerPublicKey: Array(hexData(record.ownerPublicKeyHex)),
      signature: BarnardCoreRecoverableSignature(
        r: Array(hexData(record.signatureRHex)), s: Array(hexData(record.signatureSHex)), v: record.signatureV
      )
    ))
    XCTAssertNil(SelfProofCheckpointStore(fileURL: directory.appendingPathComponent("checkpoint.json")).checkpoint)
    XCTAssertEqual(reports.reports.count, 2)
    XCTAssertTrue(store.exclusions.isEmpty)
    XCTAssertNil(coordinator.eventSigningKeyFailure)
    XCTAssertEqual(keychain.readCount, reads)
  }

  func testParentAcknowledgementReconcilesExclusionsAfterInterruptedDismissal() throws {
    try assertInterruptedAcknowledgementIsReconciled(parentAcknowledged: true)
  }

  func testExclusionAcknowledgementReconcilesParentsBeforePresentingNotices() throws {
    try assertInterruptedAcknowledgementIsReconciled(parentAcknowledged: false)
  }

  func testParentAcknowledgementSuppressesRepeatedNoticeWhenReconciliationCannotWrite() throws {
    try assertInterruptedAcknowledgementIsReconciled(parentAcknowledged: true, blockExclusionWrite: true)
  }

  private func assertInterruptedAcknowledgementIsReconciled(
    parentAcknowledged: Bool, blockExclusionWrite: Bool = false
  ) throws {
    let directory = try makeDirectory()
    let proofId = try seedCheckpoint(in: directory, publicKey: nil)
    let parents = ProofStore(fileURL: directory.appendingPathComponent("proofs.json"))
    try parents.discardSelfProofForKeyChange(for: proofId)
    try SelfProofCheckpointStore(fileURL: directory.appendingPathComponent("checkpoint.json")).clearDurably()
    let fileURL = directory.appendingPathComponent("submissions.json")
    let store = ReportSubmissionStore(fileURL: fileURL)
    let capture = try seedCapture(in: store, publicKey: nil)
    try store.addExclusion(ReportSubmissionExclusion(
      id: capture.id, eventCode: capture.eventCode, eventIdHex: capture.eventIdHex,
      enin: capture.enin, peerCount: capture.peerRpids.count,
      reasonCode: "signing-key-changed", createdAt: Date()
    ))
    try store.removePendingCapture(id: capture.id)
    if parentAcknowledged {
      try parents.acknowledgeSigningKeyChanges(forEventCodes: ["PREVIOUS"])
    } else {
      try store.acknowledgeSigningKeyChanges(forEventCodes: ["PREVIOUS"])
    }
    let keychain = InMemoryDeviceSecretKeychain(storedData: Data(repeating: 0x31, count: 32))
    let reloaded = ReportSubmissionStore(fileURL: fileURL)
    let runtime = try XCTUnwrap(ReportSubmissionRuntime.makeIfEnabled(
      bundle: try enabledBundle(in: directory), eventSigningCryptography: makeCryptography(keychain),
      definitionProvider: DelayedDeviceSecretDefinitionProvider(), store: reloaded
    ))
    defer { runtime.stop() }
    let exclusionURL = directory.appendingPathComponent("submissions.exclusions.json")
    let preservedURL = directory.appendingPathComponent("preserved-exclusions.json")
    if blockExclusionWrite {
      try FileManager.default.moveItem(at: exclusionURL, to: preservedURL)
      try FileManager.default.createDirectory(at: exclusionURL, withIntermediateDirectories: false)
    }

    let coordinator = makeCoordinator(
      directory: directory, cryptography: makeCryptography(keychain), reportSubmissionRuntime: runtime
    )

    XCTAssertNil(coordinator.eventSigningKeyNoticeEventCode)
    XCTAssertEqual(keychain.readCount, 0)
    if blockExclusionWrite {
      XCTAssertEqual(coordinator.eventSigningKeyFailure, .discardFailed)
      XCTAssertTrue(reloaded.pendingCaptures.isEmpty)
      XCTAssertEqual(coordinator.eventSigningKeyFailure?.title, "Earlier record update failed")
      XCTAssertEqual(
        coordinator.eventSigningKeyFailure?.message,
        "Changes to a record from an earlier session could not be saved."
      )
      XCTAssertTrue(reloaded.acknowledgedSigningKeyChangeEventCodes.isEmpty)
      try FileManager.default.removeItem(at: exclusionURL)
      try FileManager.default.moveItem(at: preservedURL, to: exclusionURL)
    } else {
      XCTAssertNil(coordinator.eventSigningKeyFailure)
      XCTAssertEqual(reloaded.acknowledgedSigningKeyChangeEventCodes, ["PREVIOUS"])
      XCTAssertTrue(try XCTUnwrap(ProofStore(fileURL: directory.appendingPathComponent("proofs.json"))
        .proof(withId: proofId)).signingKeyChangeNoticeAcknowledged)
    }
    runtime.stop()
    let relaunchedStore = ReportSubmissionStore(fileURL: fileURL)
    let relaunchedRuntime = try XCTUnwrap(ReportSubmissionRuntime.makeIfEnabled(
      bundle: try enabledBundle(in: directory), eventSigningCryptography: makeCryptography(keychain),
      definitionProvider: DelayedDeviceSecretDefinitionProvider(), store: relaunchedStore
    ))
    defer { relaunchedRuntime.stop() }
    let relaunched = makeCoordinator(
      directory: directory, cryptography: makeCryptography(keychain), reportSubmissionRuntime: relaunchedRuntime
    )
    XCTAssertNil(relaunched.eventSigningKeyFailure)
    XCTAssertEqual(relaunchedStore.acknowledgedSigningKeyChangeEventCodes, ["PREVIOUS"])
    XCTAssertTrue(relaunchedStore.records.isEmpty)
    XCTAssertTrue(relaunchedStore.pendingCaptures.isEmpty)
  }

  func testStartingSessionRetainsPendingCaptureReadFailureUntilDismissed() throws {
    let directory = try makeDirectory()
    let keychain = InMemoryDeviceSecretKeychain(storedData: Data(repeating: 0x31, count: 32))
    let cryptography = makeCryptography(keychain)
    let publicKey = try cryptography.eventSigningPublicKey(eventCode: "PREVIOUS")
    let store = ReportSubmissionStore(fileURL: directory.appendingPathComponent("submissions.json"))
    let capture = try seedCapture(in: store, publicKey: publicKey)
    let provider = DelayedDeviceSecretDefinitionProvider()
    let runtime = try XCTUnwrap(ReportSubmissionRuntime.makeIfEnabled(
      bundle: try enabledBundle(in: directory), eventSigningCryptography: cryptography,
      definitionProvider: provider, store: store
    ))
    defer { runtime.stop() }
    let coordinator = makeCoordinator(directory: directory, cryptography: cryptography, reportSubmissionRuntime: runtime)
    coordinator.useDemoEventMode = false
    let reads = keychain.readCount
    keychain.readResults = [.failure(errSecInteractionNotAllowed)]

    coordinator.startSensing(eventCode: "NEXT")

    XCTAssertEqual(keychain.readCount, reads + 2)
    XCTAssertEqual(coordinator.phase, .sensing)
    XCTAssertEqual(coordinator.eventSigningKeyFailure, .unavailable)
    XCTAssertEqual(ReportSubmissionStore(fileURL: directory.appendingPathComponent("submissions.json"))
      .pendingCaptures.map(\.id), [capture.id])
    XCTAssertTrue(store.records.isEmpty)
    XCTAssertTrue(store.exclusions.isEmpty)
    XCTAssertNil(provider.completion)
    coordinator.dismissEventSigningKeyFailure()
    XCTAssertNil(coordinator.eventSigningKeyFailure)
    coordinator.stopSensing()
  }

  func testStartingSessionRetainsPendingCaptureCleanupFailure() throws {
    let directory = try makeDirectory()
    let keychain = InMemoryDeviceSecretKeychain(storedData: Data(repeating: 0x31, count: 32))
    let cryptography = makeCryptography(keychain)
    let publicKey = try cryptography.eventSigningPublicKey(eventCode: "PREVIOUS")
    let fileURL = directory.appendingPathComponent("submissions.json")
    _ = try seedCapture(in: ReportSubmissionStore(fileURL: fileURL), publicKey: publicKey)
    try Data("unreadable".utf8).write(to: directory.appendingPathComponent("submissions.exclusions.json"))
    let store = ReportSubmissionStore(fileURL: fileURL)
    let runtime = try XCTUnwrap(ReportSubmissionRuntime.makeIfEnabled(
      bundle: try enabledBundle(in: directory), eventSigningCryptography: cryptography,
      definitionProvider: DelayedDeviceSecretDefinitionProvider(), store: store
    ))
    defer { runtime.stop() }
    let coordinator = makeCoordinator(directory: directory, cryptography: cryptography, reportSubmissionRuntime: runtime)
    coordinator.useDemoEventMode = false

    coordinator.startSensing(eventCode: "NEXT")

    XCTAssertEqual(coordinator.eventSigningKeyFailure, .discardFailed)
    XCTAssertEqual(store.pendingCaptures.count, 1)
    XCTAssertTrue(store.records.isEmpty)
    coordinator.stopSensing()
  }

  func testPendingCaptureRecoveryReadsCurrentKeyDespiteCachedSession() throws {
    let directory = try makeDirectory()
    let keychain = InMemoryDeviceSecretKeychain(storedData: Data(repeating: 0x31, count: 32))
    let cryptography = makeCryptography(keychain)
    _ = try cryptography.prepareSession()
    let publicKey = try cryptography.eventSigningPublicKey(eventCode: "PREVIOUS")
    let store = ReportSubmissionStore(fileURL: directory.appendingPathComponent("submissions.json"))
    _ = try seedCapture(in: store, publicKey: publicKey)
    keychain.storedData = Data(repeating: 0x42, count: 32)
    let provider = DelayedDeviceSecretDefinitionProvider()
    let runtime = try XCTUnwrap(ReportSubmissionRuntime.makeIfEnabled(
      bundle: try enabledBundle(in: directory), eventSigningCryptography: cryptography,
      definitionProvider: provider, store: store
    ))
    defer { runtime.stop() }

    runtime.submitPending()

    XCTAssertTrue(store.pendingCaptures.isEmpty)
    XCTAssertTrue(store.records.isEmpty)
    XCTAssertEqual(store.exclusions.count, 1)
    XCTAssertEqual(runtime.eventSigningKeyFailure, .changed)
    XCTAssertNil(provider.completion)
    XCTAssertTrue(try cryptography.eventSigningPublicKey(eventCode: "PREVIOUS") == publicKey)
  }

  func testPendingCaptureRecoveryReadFailureIgnoresCachedSession() throws {
    try assertCachedRecoveryReadFailure(checkpoint: false, missingKey: false)
  }

  func testPendingCaptureWithoutKeySurvivesRecoveryReadFailureDespiteCachedSession() throws {
    try assertCachedRecoveryReadFailure(checkpoint: false, missingKey: true)
  }

  func testCheckpointRecoveryReadsCurrentKeyDespiteCachedSession() throws {
    let directory = try makeDirectory()
    let keychain = InMemoryDeviceSecretKeychain(storedData: Data(repeating: 0x31, count: 32))
    let cryptography = makeCryptography(keychain)
    _ = try cryptography.prepareSession()
    let publicKey = try cryptography.eventSigningPublicKey(eventCode: "PREVIOUS")
    _ = try seedCheckpoint(in: directory, publicKey: publicKey)
    keychain.storedData = Data(repeating: 0x42, count: 32)

    let coordinator = makeCoordinator(directory: directory, cryptography: cryptography)

    XCTAssertNil(SelfProofCheckpointStore(fileURL: directory.appendingPathComponent("checkpoint.json")).checkpoint)
    XCTAssertTrue(SelfProofStore(fileURL: directory.appendingPathComponent("self-proofs.json")).records.isEmpty)
    XCTAssertEqual(coordinator.eventSigningKeyFailure, .changed)
    XCTAssertTrue(try cryptography.eventSigningPublicKey(eventCode: "PREVIOUS") == publicKey)
  }

  func testCheckpointRecoveryReadFailureIgnoresCachedSession() throws {
    try assertCachedRecoveryReadFailure(checkpoint: true, missingKey: false)
  }

  func testCheckpointWithoutKeySurvivesRecoveryReadFailureDespiteCachedSession() throws {
    try assertCachedRecoveryReadFailure(checkpoint: true, missingKey: true)
  }

  private func assertCachedRecoveryReadFailure(checkpoint: Bool, missingKey: Bool) throws {
    let directory = try makeDirectory()
    let keychain = InMemoryDeviceSecretKeychain(storedData: Data(repeating: 0x31, count: 32))
    let cryptography = makeCryptography(keychain)
    _ = try cryptography.prepareSession()
    let publicKey = try cryptography.eventSigningPublicKey(eventCode: "PREVIOUS")
    let store = ReportSubmissionStore(fileURL: directory.appendingPathComponent("submissions.json"))
    if checkpoint {
      _ = try seedCheckpoint(in: directory, publicKey: missingKey ? nil : publicKey)
    } else {
      _ = try seedCapture(in: store, publicKey: missingKey ? nil : publicKey)
    }
    let inputURL = directory.appendingPathComponent(checkpoint ? "checkpoint.json" : "submissions.pending.json")
    let original = try Data(contentsOf: inputURL)
    let reads = keychain.readCount
    keychain.readResults = [.failure(errSecInteractionNotAllowed)]
    let provider = DelayedDeviceSecretDefinitionProvider()
    let runtime = try XCTUnwrap(ReportSubmissionRuntime.makeIfEnabled(
      bundle: try enabledBundle(in: directory), eventSigningCryptography: cryptography,
      definitionProvider: provider, store: store
    ))
    defer { runtime.stop() }
    let coordinator = makeCoordinator(directory: directory, cryptography: cryptography, reportSubmissionRuntime: runtime)

    if !checkpoint { runtime.submitPending() }

    XCTAssertEqual(coordinator.eventSigningKeyFailure, .unavailable)
    XCTAssertEqual(keychain.readCount, reads + 1)
    XCTAssertTrue(try Data(contentsOf: inputURL) == original)
    XCTAssertTrue(store.records.isEmpty)
    XCTAssertTrue(store.exclusions.isEmpty)
    XCTAssertTrue(SelfProofStore(fileURL: directory.appendingPathComponent("self-proofs.json")).records.isEmpty)
    XCTAssertNil(provider.completion)
    XCTAssertEqual(keychain.addCount + keychain.writeCount + keychain.removeCount, 0)
  }

  func testActiveCaptureKeepsSessionKeyUntilTheNextSession() async throws {
    let directory = try makeDirectory()
    let keychain = InMemoryDeviceSecretKeychain(storedData: Data(repeating: 0x31, count: 32))
    let cryptography = makeCryptography(keychain)
    let provider = DelayedDeviceSecretDefinitionProvider()
    let store = ReportSubmissionStore(fileURL: directory.appendingPathComponent("submissions.json"))
    let runtime = try XCTUnwrap(ReportSubmissionRuntime.makeIfEnabled(
      bundle: try enabledBundle(in: directory), eventSigningCryptography: cryptography,
      definitionProvider: provider, store: store
    ))
    defer { runtime.stop() }
    let coordinator = makeCoordinator(directory: directory, cryptography: cryptography, reportSubmissionRuntime: runtime)
    coordinator.useDemoEventMode = false
    coordinator.startSensing(eventCode: "SESSION")
    let publicKey = try cryptography.eventSigningPublicKey(eventCode: "SESSION")
    let reads = keychain.readCount
    keychain.readResults = [.failure(errSecInteractionNotAllowed)]
    runtime.captureAndQueueWindow(
      id: UUID(), eventCode: "SESSION", eventIdHex: String(repeating: "11", count: 32),
      enin: 1, peerRpids: [], reporterRpid: "01" + String(repeating: "bb", count: 16),
      participantCommitment: nil, eventSigningPublicKey: publicKey
    )
    try XCTUnwrap(provider.completion)(nil)
    try await Task.sleep(nanoseconds: 20_000_000)
    provider.completion = nil
    runtime.submitPending()
    XCTAssertNotNil(provider.completion)
    XCTAssertEqual(keychain.readCount, reads)
    XCTAssertNil(runtime.eventSigningKeyFailure)
    try XCTUnwrap(provider.completion)(nil)
    try await Task.sleep(nanoseconds: 20_000_000)
    provider.completion = nil
    keychain.readResults = []
    keychain.storedData = Data(repeating: 0x42, count: 32)

    coordinator.startSensing(eventCode: "NEXT")

    XCTAssertTrue(store.pendingCaptures.isEmpty)
    XCTAssertTrue(store.records.isEmpty)
    XCTAssertEqual(coordinator.eventSigningKeyFailure, .changed)
    XCTAssertNil(provider.completion)
    coordinator.stopSensing()
  }

  func testRelaunchCheckpointWithMatchingKeyProducesAVerifiableRecord() throws {
    let directory = try makeDirectory()
    let keychain = InMemoryDeviceSecretKeychain(storedData: Data(repeating: 0x31, count: 32))
    let publicKey = try makeCryptography(keychain).eventSigningPublicKey(eventCode: "PREVIOUS")
    let proofId = try seedCheckpoint(in: directory, publicKey: publicKey)

    let coordinator = makeCoordinator(directory: directory, cryptography: makeCryptography(keychain))

    let record = try XCTUnwrap(SelfProofStore(fileURL: directory.appendingPathComponent("self-proofs.json"))
      .record(forProofId: proofId))
    XCTAssertTrue(record.eventSigningPublicKeyHex == hexString(publicKey))
    XCTAssertTrue(BarnardCoreSigning.verifySelfProof(
      eventIdHash: Array(hexData(record.eventIdHashHex)),
      eventSigningPublicKey: Array(hexData(record.eventSigningPublicKeyHex)),
      eninStart: record.eninStart, eninEnd: record.eninEnd,
      ownerPublicKey: Array(hexData(record.ownerPublicKeyHex)),
      signature: BarnardCoreRecoverableSignature(
        r: Array(hexData(record.signatureRHex)), s: Array(hexData(record.signatureSHex)), v: record.signatureV
      )
    ))
    XCTAssertNil(SelfProofCheckpointStore(fileURL: directory.appendingPathComponent("checkpoint.json")).checkpoint)
    XCTAssertNil(coordinator.eventSigningKeyFailure)
  }

  func testRelaunchCheckpointWithChangedKeyIsDroppedAndReportedOnce() throws {
    let directory = try makeDirectory()
    let keychain = InMemoryDeviceSecretKeychain(storedData: Data(repeating: 0x31, count: 32))
    let publicKey = try makeCryptography(keychain).eventSigningPublicKey(eventCode: "PREVIOUS")
    let proofId = try seedCheckpoint(in: directory, publicKey: publicKey)
    keychain.storedData = Data(repeating: 0x42, count: 32)

    let coordinator = makeCoordinator(directory: directory, cryptography: makeCryptography(keychain))

    XCTAssertNil(SelfProofCheckpointStore(fileURL: directory.appendingPathComponent("checkpoint.json")).checkpoint)
    XCTAssertTrue(SelfProofStore(fileURL: directory.appendingPathComponent("self-proofs.json")).records.isEmpty)
    XCTAssertNotNil(coordinator.eventSigningKeyFailure)
    XCTAssertNotEqual(coordinator.eventSigningKeyFailure, .unavailable)
    XCTAssertEqual(
      coordinator.eventSigningKeyFailure?.message,
      "A record from an earlier session could not be saved because this device's signing key changed. It was discarded."
    )
    let parent = try XCTUnwrap(ProofStore(fileURL: directory.appendingPathComponent("proofs.json")).proof(withId: proofId))
    XCTAssertTrue(parent.selfProofDiscardedForKeyChange)
    XCTAssertFalse(parent.signingKeyChangeNoticeAcknowledged)
    let interrupted = makeCoordinator(directory: directory, cryptography: makeCryptography(keychain))
    XCTAssertEqual(interrupted.eventSigningKeyFailure, .changed)
    XCTAssertEqual(interrupted.eventSigningKeyFailure?.message, coordinator.eventSigningKeyFailure?.message)
    interrupted.dismissEventSigningKeyFailure()
    let relaunched = makeCoordinator(directory: directory, cryptography: makeCryptography(keychain))
    XCTAssertNil(relaunched.eventSigningKeyFailure)
  }

  func testChangedCheckpointRetainsInputWhenParentDecisionCannotBeSaved() throws {
    let directory = try makeDirectory()
    let keychain = InMemoryDeviceSecretKeychain(storedData: Data(repeating: 0x31, count: 32))
    let publicKey = try makeCryptography(keychain).eventSigningPublicKey(eventCode: "PREVIOUS")
    let proofId = try seedCheckpoint(in: directory, publicKey: publicKey)
    let fileURL = directory.appendingPathComponent("proofs.json")
    let parents = ProofStore(fileURL: fileURL)
    try FileManager.default.removeItem(at: fileURL)
    try FileManager.default.createDirectory(at: fileURL, withIntermediateDirectories: false)
    keychain.storedData = Data(repeating: 0x42, count: 32)

    let coordinator = makeCoordinator(directory: directory, cryptography: makeCryptography(keychain), proofStore: parents)

    XCTAssertEqual(coordinator.eventSigningKeyFailure, .discardFailed)
    XCTAssertEqual(SelfProofCheckpointStore(fileURL: directory.appendingPathComponent("checkpoint.json")).checkpoint?.proofId, proofId)
    XCTAssertFalse(try XCTUnwrap(parents.proof(withId: proofId)).selfProofDiscardedForKeyChange)
    XCTAssertTrue(SelfProofStore(fileURL: directory.appendingPathComponent("self-proofs.json")).records.isEmpty)
  }

  func testDurableParentDiscardPreventsSigningAfterInterruptedCheckpointRemoval() throws {
    let directory = try makeDirectory()
    let keychain = InMemoryDeviceSecretKeychain(storedData: Data(repeating: 0x31, count: 32))
    let publicKey = try makeCryptography(keychain).eventSigningPublicKey(eventCode: "PREVIOUS")
    let proofId = try seedCheckpoint(in: directory, publicKey: publicKey)
    let parents = ProofStore(fileURL: directory.appendingPathComponent("proofs.json"))
    try parents.discardSelfProofForKeyChange(for: proofId)
    let reads = keychain.readCount

    let coordinator = makeCoordinator(directory: directory, cryptography: makeCryptography(keychain))

    XCTAssertEqual(coordinator.eventSigningKeyFailure, .changed)
    XCTAssertEqual(keychain.readCount, reads)
    XCTAssertTrue(SelfProofStore(fileURL: directory.appendingPathComponent("self-proofs.json")).records.isEmpty)
    XCTAssertNil(SelfProofCheckpointStore(fileURL: directory.appendingPathComponent("checkpoint.json")).checkpoint)
    XCTAssertTrue(try XCTUnwrap(ProofStore(fileURL: directory.appendingPathComponent("proofs.json"))
      .proof(withId: proofId)).selfProofDiscardedForKeyChange)
  }

  func testRelaunchCheckpointReadFailurePreservesInputsWithoutSigning() throws {
    let directory = try makeDirectory()
    let keychain = InMemoryDeviceSecretKeychain(storedData: Data(repeating: 0x31, count: 32))
    let publicKey = try makeCryptography(keychain).eventSigningPublicKey(eventCode: "PREVIOUS")
    _ = try seedCheckpoint(in: directory, publicKey: publicKey)
    let url = directory.appendingPathComponent("checkpoint.json")
    let original = try Data(contentsOf: url)
    keychain.readResults = [.failure(errSecInteractionNotAllowed)]

    let coordinator = makeCoordinator(directory: directory, cryptography: makeCryptography(keychain))

    XCTAssertEqual(coordinator.eventSigningKeyFailure, .unavailable)
    XCTAssertTrue(try Data(contentsOf: url) == original)
    XCTAssertTrue(SelfProofStore(fileURL: directory.appendingPathComponent("self-proofs.json")).records.isEmpty)
    XCTAssertEqual(keychain.addCount + keychain.writeCount, 0)
  }

  func testRelaunchCheckpointWithoutCapturedKeyIsDropped() throws {
    let directory = try makeDirectory()
    _ = try seedCheckpoint(in: directory, publicKey: nil)
    let keychain = InMemoryDeviceSecretKeychain(storedData: Data(repeating: 0x31, count: 32))

    let coordinator = makeCoordinator(directory: directory, cryptography: makeCryptography(keychain))

    XCTAssertNil(SelfProofCheckpointStore(fileURL: directory.appendingPathComponent("checkpoint.json")).checkpoint)
    XCTAssertTrue(SelfProofStore(fileURL: directory.appendingPathComponent("self-proofs.json")).records.isEmpty)
    XCTAssertEqual(
      coordinator.eventSigningKeyFailure?.message,
      "A record from an earlier session could not be checked and was discarded."
    )
    let relaunched = makeCoordinator(directory: directory, cryptography: makeCryptography(keychain))
    XCTAssertEqual(relaunched.eventSigningKeyFailure?.message, coordinator.eventSigningKeyFailure?.message)
    XCTAssertEqual(keychain.addCount + keychain.writeCount, 0)
  }

  func testStartingSessionKeepsDiscardNoticeUntilDismissed() throws {
    let directory = try makeDirectory()
    let keychain = InMemoryDeviceSecretKeychain(storedData: Data(repeating: 0x31, count: 32))
    let publicKey = try makeCryptography(keychain).eventSigningPublicKey(eventCode: "PREVIOUS")
    _ = try seedCheckpoint(in: directory, publicKey: publicKey)
    keychain.storedData = Data(repeating: 0x42, count: 32)
    let coordinator = makeCoordinator(directory: directory, cryptography: makeCryptography(keychain))
    coordinator.useDemoEventMode = false

    coordinator.startSensing(eventCode: "NEXT")

    XCTAssertEqual(coordinator.eventSigningKeyFailure, .changed)
    coordinator.dismissEventSigningKeyFailure()
    XCTAssertNil(coordinator.eventSigningKeyFailure)
    coordinator.stopSensing()
    coordinator.startSensing(eventCode: "NEXT")
    XCTAssertNil(coordinator.eventSigningKeyFailure)
    coordinator.stopSensing()
  }

  func testUnlockThenStartKeepsThePendingCaptureDiscardNotice() throws {
    let directory = try makeDirectory()
    let keychain = InMemoryDeviceSecretKeychain(storedData: Data(repeating: 0x31, count: 32))
    let publicKey = try makeCryptography(keychain).eventSigningPublicKey(eventCode: "PREVIOUS")
    let store = ReportSubmissionStore(fileURL: directory.appendingPathComponent("submissions.json"))
    _ = try seedCapture(in: store, publicKey: publicKey)
    let runtime = try XCTUnwrap(ReportSubmissionRuntime.makeIfEnabled(
      bundle: try enabledBundle(in: directory), eventSigningCryptography: makeCryptography(keychain),
      definitionProvider: DelayedDeviceSecretDefinitionProvider(), store: store
    ))
    defer { runtime.stop() }
    let coordinator = makeCoordinator(
      directory: directory, cryptography: makeCryptography(keychain), reportSubmissionRuntime: runtime
    )
    coordinator.useDemoEventMode = false
    keychain.readResults = [.failure(errSecInteractionNotAllowed)]
    runtime.submitPending()
    XCTAssertEqual(coordinator.eventSigningKeyFailure, .unavailable)
    keychain.storedData = Data(repeating: 0x42, count: 32)

    coordinator.startSensing(eventCode: "NEXT")

    XCTAssertTrue(store.pendingCaptures.isEmpty)
    XCTAssertTrue(store.records.isEmpty)
    XCTAssertEqual(coordinator.eventSigningKeyFailure, .changed)
    coordinator.stopSensing()
  }

  func testPendingCaptureWithChangedKeyIsDroppedAndReportedOnce() throws {
    try assertPendingCaptureIsDropped(captureKeyIsMissing: false)
  }

  func testPendingCaptureWithoutCapturedKeyIsDropped() throws {
    try assertPendingCaptureIsDropped(captureKeyIsMissing: true)
  }

  func testAcknowledgedEventDoesNotRepeatNoticeForLaterWindowsOrRelaunch() throws {
    let directory = try makeDirectory()
    let fileURL = directory.appendingPathComponent("submissions.json")
    let keychain = InMemoryDeviceSecretKeychain(storedData: Data(repeating: 0x31, count: 32))
    let publicKey = try makeCryptography(keychain).eventSigningPublicKey(eventCode: "PREVIOUS")
    let store = ReportSubmissionStore(fileURL: fileURL)
    _ = try seedCapture(in: store, publicKey: publicKey)
    keychain.storedData = Data(repeating: 0x42, count: 32)
    let runtime = try XCTUnwrap(ReportSubmissionRuntime.makeIfEnabled(
      bundle: try enabledBundle(in: directory), eventSigningCryptography: makeCryptography(keychain),
      definitionProvider: DelayedDeviceSecretDefinitionProvider(), store: store
    ))
    var notices = 0
    runtime.onEventSigningKeyFailure = { if $0 == .changed { notices += 1 } }
    runtime.submitPending()
    XCTAssertEqual(notices, 1)
    try runtime.acknowledgeSigningKeyChanges()
    _ = try seedCapture(in: store, publicKey: publicKey)
    runtime.submitPending()
    XCTAssertEqual(notices, 1)
    runtime.stop()
    let reloaded = ReportSubmissionStore(fileURL: fileURL)
    _ = try seedCapture(in: reloaded, publicKey: publicKey)
    let relaunched = try XCTUnwrap(ReportSubmissionRuntime.makeIfEnabled(
      bundle: try enabledBundle(in: directory), eventSigningCryptography: makeCryptography(keychain),
      definitionProvider: DelayedDeviceSecretDefinitionProvider(), store: reloaded
    ))
    defer { relaunched.stop() }
    relaunched.onEventSigningKeyFailure = { if $0 == .changed { notices += 1 } }
    relaunched.submitPending()
    XCTAssertEqual(notices, 1)
    _ = try seedCapture(in: reloaded, publicKey: publicKey, eventCode: "OTHER")
    relaunched.submitPending()
    XCTAssertEqual(notices, 2)
    XCTAssertTrue(reloaded.pendingCaptures.isEmpty)
    XCTAssertTrue(reloaded.records.isEmpty)
    XCTAssertEqual(reloaded.exclusions.count, 4)
  }

  func testUnacknowledgedWindowDiscardNoticeSurvivesRelaunch() throws {
    let directory = try makeDirectory()
    let fileURL = directory.appendingPathComponent("submissions.json")
    let keychain = InMemoryDeviceSecretKeychain(storedData: Data(repeating: 0x31, count: 32))
    let publicKey = try makeCryptography(keychain).eventSigningPublicKey(eventCode: "PREVIOUS")
    let store = ReportSubmissionStore(fileURL: fileURL)
    let capture = try seedCapture(in: store, publicKey: publicKey)
    try store.addExclusion(ReportSubmissionExclusion(
      id: capture.id, eventCode: capture.eventCode, eventIdHex: capture.eventIdHex,
      enin: capture.enin, peerCount: capture.peerRpids.count,
      reasonCode: "signing-key-changed", createdAt: Date()
    ))
    try store.removePendingCapture(id: capture.id)
    let runtime = try XCTUnwrap(ReportSubmissionRuntime.makeIfEnabled(
      bundle: try enabledBundle(in: directory), eventSigningCryptography: makeCryptography(keychain),
      definitionProvider: DelayedDeviceSecretDefinitionProvider(), store: ReportSubmissionStore(fileURL: fileURL)
    ))
    defer { runtime.stop() }

    let coordinator = makeCoordinator(
      directory: directory, cryptography: makeCryptography(keychain), reportSubmissionRuntime: runtime
    )

    XCTAssertEqual(coordinator.eventSigningKeyFailure, .changed)
    coordinator.dismissEventSigningKeyFailure()
    XCTAssertTrue(ReportSubmissionStore(fileURL: fileURL).exclusions.allSatisfy {
      $0.signingKeyChangeNoticeAcknowledged == true
    })
  }

  func testCheckpointAcknowledgementAlsoSuppressesLaterWindowNoticesForTheEvent() throws {
    let directory = try makeDirectory()
    let keychain = InMemoryDeviceSecretKeychain(storedData: Data(repeating: 0x31, count: 32))
    let publicKey = try makeCryptography(keychain).eventSigningPublicKey(eventCode: "PREVIOUS")
    _ = try seedCheckpoint(in: directory, publicKey: publicKey)
    keychain.storedData = Data(repeating: 0x42, count: 32)
    let fileURL = directory.appendingPathComponent("submissions.json")
    let store = ReportSubmissionStore(fileURL: fileURL)
    let runtime = try XCTUnwrap(ReportSubmissionRuntime.makeIfEnabled(
      bundle: try enabledBundle(in: directory), eventSigningCryptography: makeCryptography(keychain),
      definitionProvider: DelayedDeviceSecretDefinitionProvider(), store: store
    ))
    defer { runtime.stop() }
    let coordinator = makeCoordinator(
      directory: directory, cryptography: makeCryptography(keychain), reportSubmissionRuntime: runtime
    )
    XCTAssertEqual(coordinator.eventSigningKeyFailure, .changed)
    coordinator.dismissEventSigningKeyFailure()

    _ = try seedCapture(in: store, publicKey: publicKey)
    runtime.submitPending()

    XCTAssertNil(coordinator.eventSigningKeyFailure)
    XCTAssertNil(runtime.eventSigningKeyFailure)
    XCTAssertTrue(store.pendingCaptures.isEmpty)
    XCTAssertTrue(ReportSubmissionStore(fileURL: fileURL).exclusions.allSatisfy {
      $0.signingKeyChangeNoticeAcknowledged == true
    })
  }

  func testDistinctEventsRequireSeparateNoticeDismissals() throws {
    let directory = try makeDirectory()
    let keychain = InMemoryDeviceSecretKeychain(storedData: Data(repeating: 0x31, count: 32))
    let publicKey = try makeCryptography(keychain).eventSigningPublicKey(eventCode: "PREVIOUS")
    let store = ReportSubmissionStore(fileURL: directory.appendingPathComponent("submissions.json"))
    _ = try seedCapture(in: store, publicKey: publicKey)
    _ = try seedCapture(in: store, publicKey: publicKey, eventCode: "OTHER")
    keychain.storedData = Data(repeating: 0x42, count: 32)
    let runtime = try XCTUnwrap(ReportSubmissionRuntime.makeIfEnabled(
      bundle: try enabledBundle(in: directory), eventSigningCryptography: makeCryptography(keychain),
      definitionProvider: DelayedDeviceSecretDefinitionProvider(), store: store
    ))
    defer { runtime.stop() }
    let coordinator = makeCoordinator(
      directory: directory, cryptography: makeCryptography(keychain), reportSubmissionRuntime: runtime
    )
    runtime.submitPending()
    XCTAssertEqual(coordinator.eventSigningKeyNoticeEventCode, "PREVIOUS")

    coordinator.dismissEventSigningKeyFailure()

    XCTAssertEqual(coordinator.eventSigningKeyFailure, .changed)
    XCTAssertEqual(coordinator.eventSigningKeyNoticeEventCode, "OTHER")
    XCTAssertEqual(store.acknowledgedSigningKeyChangeEventCodes, ["PREVIOUS"])
    coordinator.dismissEventSigningKeyFailure()
    XCTAssertNil(coordinator.eventSigningKeyFailure)
    XCTAssertEqual(store.acknowledgedSigningKeyChangeEventCodes, ["PREVIOUS", "OTHER"])
  }

  func testPendingCaptureReadFailurePreservesInputsWithoutSigning() throws {
    let directory = try makeDirectory()
    let fileURL = directory.appendingPathComponent("submissions.json")
    let keychain = InMemoryDeviceSecretKeychain(storedData: Data(repeating: 0x31, count: 32))
    let publicKey = try makeCryptography(keychain).eventSigningPublicKey(eventCode: "PREVIOUS")
    let store = ReportSubmissionStore(fileURL: fileURL)
    let capture = try seedCapture(in: store, publicKey: publicKey)
    keychain.readResults = [.failure(errSecInteractionNotAllowed)]
    let provider = DelayedDeviceSecretDefinitionProvider()
    let runtime = try XCTUnwrap(ReportSubmissionRuntime.makeIfEnabled(
      bundle: try enabledBundle(in: directory), eventSigningCryptography: makeCryptography(keychain),
      definitionProvider: provider, store: store
    ))
    defer { runtime.stop() }

    runtime.submitPending()

    XCTAssertEqual(runtime.eventSigningKeyFailure, .unavailable)
    XCTAssertEqual(ReportSubmissionStore(fileURL: fileURL).pendingCaptures.map(\.id), [capture.id])
    XCTAssertTrue(store.records.isEmpty)
    XCTAssertTrue(store.exclusions.isEmpty)
    XCTAssertNil(provider.completion)
    XCTAssertEqual(keychain.addCount + keychain.writeCount, 0)
  }

  func testRelaunchPendingCaptureWithMatchingKeySignsWithTheCapturedKey() async throws {
    let directory = try makeDirectory()
    let keychain = InMemoryDeviceSecretKeychain(storedData: Data(repeating: 0x31, count: 32))
    let publicKey = try makeCryptography(keychain).eventSigningPublicKey(eventCode: "PREVIOUS")
    let fileURL = directory.appendingPathComponent("submissions.json")
    let capture = try seedCapture(in: ReportSubmissionStore(fileURL: fileURL), publicKey: publicKey)
    let store = ReportSubmissionStore(fileURL: fileURL)
    let receiptKeyHex = "02c6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee5"
    let server = try StubOperatorServer(
      eventId: Data(repeating: 0x11, count: 32),
      signingPrivateKey: [UInt8](repeating: 0, count: 31) + [2], signingPublicKey: hexData(receiptKeyHex)
    )
    defer { server.stop() }
    let endpoint = try await server.start()
    let configuration = try XCTUnwrap(ExportedKotlinPackages.org.levarac.parallax.submission
      .createSubmissionOperatorConfiguration(
        endpoint: endpoint.absoluteString, receiptPublicKeyHex: receiptKeyHex,
        eventIdHex: capture.eventIdHex, eventDefinitionDigestHex: String(repeating: "22", count: 32),
        validFrom: nil, validUntil: nil, allowInsecureLoopbackForTests: true
      ))
    let provider = DelayedDeviceSecretDefinitionProvider()
    let runtime = try XCTUnwrap(ReportSubmissionRuntime.makeIfEnabled(
      bundle: try enabledBundle(in: directory), eventSigningCryptography: makeCryptography(keychain),
      definitionProvider: provider, store: store, allowInsecureLoopbackForTests: true
    ))
    defer { runtime.stop() }

    runtime.submitPending()
    try XCTUnwrap(provider.completion)(VerifiedSubmissionDefinition(configuration: configuration))
    try await server.waitFor(postCount: 1)

    let record = try XCTUnwrap(store.records.first)
    let evidence = try XCTUnwrap(ExportedKotlinPackages.org.levarac.parallax.observation
      .createMutualSensingWindowEvidence(
        idHex: capture.id.uuidString.replacingOccurrences(of: "-", with: "").lowercased(), eventIdHex: capture.eventIdHex!,
        eventDefinitionDigestHex: String(repeating: "22", count: 32), observerHex: hexString(publicKey),
        finalizedAt: capture.finalizedAt, reporterRpidHex: capture.reporterRpid, enin: Int64(capture.enin),
        observedRpidHexes: capture.peerRpids, rpidClaimHex: nil,
        participantCommitmentHex: nil, legacyPeerCount: nil
      ))
    let eligible = try XCTUnwrap(ExportedKotlinPackages.org.levarac.parallax.observation
      .prepareMutualSensingObservation(evidence: evidence) as?
      ExportedKotlinPackages.org.levarac.parallax.observation.ObservationPreparationResult.Eligible)
    let digest = Array(SHA256.hash(data: Data(kotlinBytes: eligible.prepared.signatureStructure.toByteArray())))
    let compact = hexData(record.signedObservationHex).suffix(64)
    XCTAssertTrue((0...1).contains { recoveryId in
      BarnardCoreSigning.recoverPublicKey(
        recoveryId: recoveryId, r: Array(compact.prefix(32)), s: Array(compact.suffix(32)), messageHash32: digest
      ) == Array(publicKey)
    })
    XCTAssertTrue(store.pendingCaptures.isEmpty)
    XCTAssertNil(runtime.eventSigningKeyFailure)
  }

  private func assertPendingCaptureIsDropped(captureKeyIsMissing: Bool) throws {
    let directory = try makeDirectory()
    let fileURL = directory.appendingPathComponent("submissions.json")
    let keychain = InMemoryDeviceSecretKeychain(storedData: Data(repeating: 0x31, count: 32))
    let publicKey = try makeCryptography(keychain).eventSigningPublicKey(eventCode: "PREVIOUS")
    let store = ReportSubmissionStore(fileURL: fileURL)
    _ = try seedCapture(in: store, publicKey: captureKeyIsMissing ? nil : publicKey)
    if !captureKeyIsMissing { keychain.storedData = Data(repeating: 0x42, count: 32) }
    let provider = DelayedDeviceSecretDefinitionProvider()
    let runtime = try XCTUnwrap(ReportSubmissionRuntime.makeIfEnabled(
      bundle: try enabledBundle(in: directory), eventSigningCryptography: makeCryptography(keychain),
      definitionProvider: provider, store: store
    ))
    defer { runtime.stop() }
    var notices = 0
    runtime.onEventSigningKeyFailure = { _ in notices += 1 }

    runtime.submitPending()

    XCTAssertTrue(ReportSubmissionStore(fileURL: fileURL).pendingCaptures.isEmpty)
    XCTAssertTrue(store.records.isEmpty)
    XCTAssertEqual(store.exclusions.count, 1)
    XCTAssertNotEqual(runtime.eventSigningKeyFailure, .unavailable)
    XCTAssertEqual(
      runtime.eventSigningKeyFailure?.message,
      captureKeyIsMissing
        ? "A record from an earlier session could not be checked and was discarded."
        : "A record from an earlier session could not be saved because this device's signing key changed. It was discarded."
    )
    XCTAssertNil(provider.completion)
    runtime.submitPending()
    XCTAssertEqual(notices, 1)
    let relaunched = try XCTUnwrap(ReportSubmissionRuntime.makeIfEnabled(
      bundle: try enabledBundle(in: directory), eventSigningCryptography: makeCryptography(keychain),
      definitionProvider: DelayedDeviceSecretDefinitionProvider(), store: ReportSubmissionStore(fileURL: fileURL)
    ))
    defer { relaunched.stop() }
    XCTAssertEqual(relaunched.eventSigningKeyFailure?.message, runtime.eventSigningKeyFailure?.message)
  }

  private func seedCheckpoint(in directory: URL, publicKey: Data?) throws -> UUID {
    let proofId = UUID()
    ProofStore(fileURL: directory.appendingPathComponent("proofs.json")).add(Proof(
      id: proofId, eventName: "Previous event", date: Date(), peersVerified: 1, eventCode: "PREVIOUS"
    ))
    var record: [String: Any] = [
      "proofId": proofId.uuidString, "eventCode": "PREVIOUS", "eninStart": 1, "eninEnd": 2
    ]
    record["eventSigningPublicKey"] = publicKey?.base64EncodedString()
    try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "record": record])
      .write(to: directory.appendingPathComponent("checkpoint.json"), options: .atomic)
    return proofId
  }

  private func seedCapture(
    in store: ReportSubmissionStore, publicKey: Data?, eventCode: String = "PREVIOUS"
  ) throws -> ReportSubmissionCapture {
    let capture = ReportSubmissionCapture(
      id: UUID(), eventCode: eventCode, eventIdHex: String(repeating: "11", count: 32),
      enin: 1, peerRpids: ["01" + String(repeating: "aa", count: 16)],
      reporterRpid: "01" + String(repeating: "bb", count: 16), participantCommitment: nil
    )
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(capture)) as? [String: Any])
    object["eventSigningPublicKey"] = publicKey?.base64EncodedString()
    let captured = try JSONDecoder().decode(ReportSubmissionCapture.self, from: JSONSerialization.data(withJSONObject: object))
    try store.addPendingCapture(captured)
    return captured
  }

  func testCheckpointSurvivesARecordWriteFailure() throws {
    let directory = try makeDirectory()
    let keychain = InMemoryDeviceSecretKeychain(storedData: Data(repeating: 0x31, count: 32))
    let publicKey = try makeCryptography(keychain).eventSigningPublicKey(eventCode: "PREVIOUS")
    _ = try seedCheckpoint(in: directory, publicKey: publicKey)
    try FileManager.default.createDirectory(
      at: directory.appendingPathComponent("self-proofs.json"), withIntermediateDirectories: false
    )

    let coordinator = makeCoordinator(directory: directory, cryptography: makeCryptography(keychain))

    XCTAssertNotNil(SelfProofCheckpointStore(fileURL: directory.appendingPathComponent("checkpoint.json")).checkpoint)
    XCTAssertNotNil(coordinator.eventSigningKeyFailure)
    coordinator.useDemoEventMode = false
    coordinator.startSensing(eventCode: "NEXT")
    XCTAssertEqual(coordinator.joinRefusal, .eventSigningKeyUnavailable)
    XCTAssertNotNil(SelfProofCheckpointStore(fileURL: directory.appendingPathComponent("checkpoint.json")).checkpoint)
  }

  func testExcludedCaptureCannotSignAfterItsRemovalWasInterrupted() throws {
    try assertDiscardNoticeWaitsForCaptureRemoval(exclusionAlreadySaved: false)
  }

  func testExcludedCaptureDoesNotShowDiscardNoticeBeforeRemovalOnRelaunch() throws {
    try assertDiscardNoticeWaitsForCaptureRemoval(exclusionAlreadySaved: true)
  }

  private func assertDiscardNoticeWaitsForCaptureRemoval(exclusionAlreadySaved: Bool) throws {
    let directory = try makeDirectory()
    let fileURL = directory.appendingPathComponent("submissions.json")
    let pendingURL = directory.appendingPathComponent("submissions.pending.json")
    let preservedURL = directory.appendingPathComponent("preserved.json")
    let keychain = InMemoryDeviceSecretKeychain(storedData: Data(repeating: 0x31, count: 32))
    let publicKey = try makeCryptography(keychain).eventSigningPublicKey(eventCode: "PREVIOUS")
    let store = ReportSubmissionStore(fileURL: fileURL)
    let capture = try seedCapture(in: store, publicKey: publicKey)
    if exclusionAlreadySaved {
      try store.addExclusion(ReportSubmissionExclusion(
        id: capture.id, eventCode: capture.eventCode, eventIdHex: capture.eventIdHex,
        enin: capture.enin, peerCount: capture.peerRpids.count,
        reasonCode: "signing-key-changed", createdAt: Date()
      ))
    }
    let runtimeStore = exclusionAlreadySaved ? ReportSubmissionStore(fileURL: fileURL) : store
    try FileManager.default.moveItem(at: pendingURL, to: preservedURL)
    try FileManager.default.createDirectory(at: pendingURL, withIntermediateDirectories: false)
    keychain.storedData = Data(repeating: 0x42, count: 32)
    let provider = DelayedDeviceSecretDefinitionProvider()
    let runtime = try XCTUnwrap(ReportSubmissionRuntime.makeIfEnabled(
      bundle: try enabledBundle(in: directory), eventSigningCryptography: makeCryptography(keychain),
      definitionProvider: provider, store: runtimeStore
    ))
    defer { runtime.stop() }
    let coordinator = makeCoordinator(
      directory: directory, cryptography: makeCryptography(keychain), reportSubmissionRuntime: runtime
    )
    XCTAssertNil(coordinator.eventSigningKeyNoticeEventCode)

    runtime.submitPending()

    XCTAssertEqual(runtimeStore.pendingCaptures.count, 1)
    XCTAssertEqual(ReportSubmissionStore(fileURL: fileURL).exclusions.count, 1)
    XCTAssertTrue(runtimeStore.records.isEmpty)
    XCTAssertEqual(coordinator.eventSigningKeyFailure, .discardFailed)
    XCTAssertNil(coordinator.eventSigningKeyNoticeEventCode)
    try FileManager.default.removeItem(at: pendingURL)
    try FileManager.default.moveItem(at: preservedURL, to: pendingURL)
    keychain.storedData = Data(repeating: 0x31, count: 32)
    runtime.submitPending()

    XCTAssertTrue(ReportSubmissionStore(fileURL: fileURL).pendingCaptures.isEmpty)
    XCTAssertTrue(runtimeStore.records.isEmpty)
    XCTAssertEqual(coordinator.eventSigningKeyFailure, .changed)
    XCTAssertEqual(coordinator.eventSigningKeyNoticeEventCode, "PREVIOUS")
    XCTAssertNil(provider.completion)
  }

  func testUnreadableExclusionsPreventKeyDerivationAndSigning() throws {
    let directory = try makeDirectory()
    let fileURL = directory.appendingPathComponent("submissions.json")
    let keychain = InMemoryDeviceSecretKeychain(storedData: Data(repeating: 0x31, count: 32))
    let publicKey = try makeCryptography(keychain).eventSigningPublicKey(eventCode: "PREVIOUS")
    let initialStore = ReportSubmissionStore(fileURL: fileURL)
    let capture = try seedCapture(in: initialStore, publicKey: publicKey)
    try initialStore.addExclusion(ReportSubmissionExclusion(
      id: capture.id, eventCode: capture.eventCode, eventIdHex: capture.eventIdHex,
      enin: capture.enin, peerCount: capture.peerRpids.count,
      reasonCode: "signing-key-changed", createdAt: Date()
    ))
    try Data("unreadable".utf8).write(to: directory.appendingPathComponent("submissions.exclusions.json"))
    let reads = keychain.readCount
    let store = ReportSubmissionStore(fileURL: fileURL)
    let provider = DelayedDeviceSecretDefinitionProvider()
    let runtime = try XCTUnwrap(ReportSubmissionRuntime.makeIfEnabled(
      bundle: try enabledBundle(in: directory), eventSigningCryptography: makeCryptography(keychain),
      definitionProvider: provider, store: store
    ))
    defer { runtime.stop() }

    runtime.submitPending()

    XCTAssertEqual(keychain.readCount, reads)
    XCTAssertNil(provider.completion)
    XCTAssertTrue(store.records.isEmpty)
    XCTAssertEqual(store.pendingCaptures.map(\.id), [capture.id])
    XCTAssertEqual(runtime.eventSigningKeyFailure, .discardFailed)
  }

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
    XCTAssertTrue(SelfProofCheckpointStore(fileURL: directory.appendingPathComponent("checkpoint.json"))
      .checkpoint?.eventSigningPublicKey == publicKey)
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
    ProofStore(fileURL: directory.appendingPathComponent("proofs.json")).add(Proof(
      id: proofId, eventName: "Previous event", date: Date(), peersVerified: 1, eventCode: "PREVIOUS"
    ))
    let publicKey = try makeCryptography(InMemoryDeviceSecretKeychain(storedData: Data(repeating: 0x31, count: 32)))
      .eventSigningPublicKey(eventCode: "PREVIOUS")
    SelfProofCheckpointStore(fileURL: checkpointURL).save(SelfProofCheckpoint(
      proofId: proofId, eventCode: "PREVIOUS", eninStart: 1, eninEnd: 2, eventSigningPublicKey: publicKey
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
      participantCommitment: Data(repeating: 0x55, count: 32), eventSigningPublicKey: publicKey
    )
    XCTAssertTrue(ReportSubmissionStore(fileURL: directory.appendingPathComponent("submissions.json"))
      .pendingCaptures.first?.eventSigningPublicKey == publicKey)
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
    let publicKey = try makeCryptography(InMemoryDeviceSecretKeychain(storedData: Data(repeating: 0x31, count: 32)))
      .eventSigningPublicKey(eventCode: "PREVIOUS")
    let runtime = try XCTUnwrap(ReportSubmissionRuntime.makeIfEnabled(
      bundle: try enabledBundle(in: directory), eventSigningCryptography: makeCryptography(keychain),
      definitionProvider: provider, store: store
    ))
    defer { runtime.stop() }

    runtime.captureAndQueueWindow(
      id: UUID(), eventCode: "PREVIOUS", eventIdHex: String(repeating: "11", count: 32),
      enin: 1, peerRpids: ["01" + String(repeating: "aa", count: 16)],
      reporterRpid: "01" + String(repeating: "bb", count: 16), participantCommitment: nil,
      eventSigningPublicKey: publicKey
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
    deviceSecretStore: DeviceSecretKeychainStore = .shared,
    proofStore: ProofStore? = nil,
    checkpointStore: SelfProofCheckpointStore? = nil,
    reportSubmissionRuntime: (any WindowReportSubmissionRuntimeProtocol)? = nil
  ) -> SensingCoordinator {
    let parents = proofStore ?? ProofStore(fileURL: directory.appendingPathComponent("proofs.json"))
    let coordinator = SensingCoordinator(
      windowReportStore: reports ?? WindowReportStore(fileURL: directory.appendingPathComponent("reports.json")),
      selfProofStore: SelfProofStore(fileURL: directory.appendingPathComponent("self-proofs.json")),
      selfProofCheckpointStore: checkpointStore
        ?? SelfProofCheckpointStore(fileURL: directory.appendingPathComponent("checkpoint.json")),
      bindingRecordStore: BindingRecordStore(fileURL: directory.appendingPathComponent("bindings.json")),
      sessionAggregateSnapshotStore: SessionAggregateSnapshotStore(fileURL: directory.appendingPathComponent("aggregate.json")),
      unsentWindowLedgerFileURL: directory.appendingPathComponent("ledger.snapshot"),
      sensingCryptography: cryptography, reportSubmissionRuntime: reportSubmissionRuntime,
      eventJoinControl: eventJoinControl,
      eventJoinRegistry: eventJoinRegistry, joinDiagnosticLog: { _ in },
      deviceSecretStore: deviceSecretStore,
      proofStore: parents
    )
    coordinator.onProofCollected = { parents.add($0) }
    return coordinator
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

  private func hexString(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
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

private extension Data {
  init(kotlinBytes bytes: ExportedKotlinPackages.kotlin.ByteArray) {
    self.init((0..<Int(bytes.size)).map { UInt8(bitPattern: bytes[Int32($0)]) })
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
