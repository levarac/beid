// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

#if DEBUG && targetEnvironment(simulator)
import BeidSharedKit
import SwiftUI

/// Supplies durable synthetic input to the normal runtime in the app process.
/// The UI test runner owns the independent IPv4 loopback HTTP receiver.
@MainActor
final class FirstUploadNoticeUITestFixture {
  enum Mode: String {
    case automatic, account, eventCode, welcome
  }

  let mode: Mode
  /// `BEID_FIRST_UPLOAD_UI_SYSTEM_OPEN_URL=1` leaves the system `openURL` in
  /// place so the notice's Privacy Policy link opens Safari, for a manual or
  /// local evidence run. Default (unset): the link's URL is intercepted and
  /// shown in `firstUpload.fixture.policyURL`, which the UI tests assert.
  let usesSystemOpenURL: Bool
  let coordinator: AppCoordinator
  let reportStore: ReportSubmissionStore
  private let proofStore: ProofStore
  private let linkStore: ReportProofLinkStore
  private let runtime: ReportSubmissionRuntime
  private let record: ReportSubmissionRecord

  static func fromLaunchEnvironment() -> FirstUploadNoticeUITestFixture? {
    let process = ProcessInfo.processInfo
    guard process.arguments.contains("-beid-ui-test"),
      process.arguments.contains("-beid-first-upload-ui") else { return nil }
    do {
      return try FirstUploadNoticeUITestFixture(environment: process.environment)
    } catch {
      preconditionFailure("First upload UI fixture setup failed: \(error)")
    }
  }

  private init(environment: [String: String]) throws {
    guard let run = environment["BEID_FIRST_UPLOAD_UI_RUN"].flatMap(UUID.init(uuidString:)),
      let id = environment["BEID_FIRST_UPLOAD_UI_RECORD"].flatMap(UUID.init(uuidString:)),
      let port = environment["BEID_FIRST_UPLOAD_UI_PORT"].flatMap({ UInt16($0) }), port != 0,
      let mode = environment["BEID_FIRST_UPLOAD_UI_MODE"].flatMap(Mode.init(rawValue:)),
      let signed = environment["BEID_FIRST_UPLOAD_UI_OBSERVATION"],
      let defaults = UserDefaults(suiteName: "org.levarac.beid.ui.first-upload.\(run.uuidString)")
    else { throw CocoaError(.fileReadCorruptFile) }
    usesSystemOpenURL = environment["BEID_FIRST_UPLOAD_UI_SYSTEM_OPEN_URL"] == "1"
    let endpoint = "http://127.0.0.1:\(port)"
    let publicKey = "02c6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee5"
    let eventId = String(repeating: "11", count: 32)
    let definitionDigest = String(repeating: "22", count: 32)
    guard let stored = ExportedKotlinPackages.org.levarac.parallax.submission
      .restoreStoredObservation(signedBytesHex: signed),
      let configuration = ExportedKotlinPackages.org.levarac.parallax.submission.createSubmissionOperatorConfiguration(
        endpoint: endpoint, receiptPublicKeyHex: publicKey, eventIdHex: eventId,
        eventDefinitionDigestHex: definitionDigest, validFrom: nil, validUntil: nil,
        allowInsecureLoopbackForTests: true
      )
    else { throw CocoaError(.fileReadCorruptFile) }

    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("first-upload-ui-\(run.uuidString)", isDirectory: true)
    let configurationBundle = directory.appendingPathComponent("Fixture.bundle", isDirectory: true)
    try FileManager.default.createDirectory(at: configurationBundle, withIntermediateDirectories: true)
    let info = try PropertyListSerialization.data(
      fromPropertyList: [
        "CFBundleIdentifier": "org.levarac.beid.first-upload-ui",
        "CFBundlePackageType": "BNDL",
        "BeidReportSubmissionEnabled": "1"
      ], format: .xml, options: 0
    )
    try info.write(to: configurationBundle.appendingPathComponent("Info.plist"), options: .atomic)
    let proofStore = ProofStore(fileURL: directory.appendingPathComponent("proofs.json"))
    let reportStore = ReportSubmissionStore(fileURL: directory.appendingPathComponent("submissions.json"))
    let linkStore = ReportProofLinkStore(fileURL: directory.appendingPathComponent("links.json"))
    let cryptography = FirstUploadFixtureNoSigning()
    guard let bundle = Bundle(url: configurationBundle),
      let runtime = ReportSubmissionRuntime.makeIfEnabled(
        bundle: bundle, eventSigningCryptography: cryptography,
        definitionProvider: FirstUploadFixtureSavedRecordsOnly(), store: reportStore,
        noticeDefaults: defaults, allowInsecureLoopbackForTests: true
      ) else { throw CocoaError(.fileReadCorruptFile) }
    let engine = NearbyJoinUITestEngine()
    let sensing = SensingCoordinator(
      windowReportStore: WindowReportStore(fileURL: directory.appendingPathComponent("windows.json")),
      selfProofStore: SelfProofStore(fileURL: directory.appendingPathComponent("self-proofs.json")),
      selfProofCheckpointStore: SelfProofCheckpointStore(fileURL: directory.appendingPathComponent("checkpoint.json")),
      bindingRecordStore: BindingRecordStore(fileURL: directory.appendingPathComponent("bindings.json")),
      sessionAggregateSnapshotStore: SessionAggregateSnapshotStore(fileURL: directory.appendingPathComponent("aggregate.json")),
      sigilPresenceStore: SigilPresenceStore(fileURL: directory.appendingPathComponent("sigil.json")),
      unsentWindowLedgerRuntime: nil, sensingCryptography: cryptography,
      reportSubmissionRuntime: runtime, reportProofLinkStore: linkStore,
      ownerKeyRestorationAcknowledgementDefaults: defaults,
      eventJoinControl: engine, participantRelayControl: engine, proofStore: proofStore
    )
    let coordinator = AppCoordinator(
      proofStore: proofStore, sensingCoordinator: sensing, reportSubmissionStore: reportStore,
      reportProofLinkStore: linkStore, registryClient: nil, userDefaults: defaults
    )
    coordinator.screen = mode == .welcome ? .welcome : .home
    self.mode = mode
    self.coordinator = coordinator
    self.proofStore = proofStore
    self.reportStore = reportStore
    self.linkStore = linkStore
    self.runtime = runtime
    record = ReportSubmissionRecord(
      id: id, eventCode: "BEID936-FIXTURE", endpoint: endpoint, receiptPublicKeyHex: publicKey,
      eventIdHex: eventId, eventDefinitionDigestHex: definitionDigest, validFrom: nil, validUntil: nil,
      signedObservationHex: signed,
      observationDigestHex: fixtureHex(stored.observationDigest.toByteArray()),
      operatorIdHex: fixtureHex(configuration.operatorId.toByteArray()),
      createdAt: Date(timeIntervalSince1970: 1_774_487_000)
    )
  }

  var recordID: UUID { record.id }

  func submit() {
    do {
      if proofStore.proof(withId: record.id) == nil {
        precondition(proofStore.add(Proof(
          id: record.id, eventName: "First upload fixture", date: record.createdAt,
          peersVerified: 3, eventCode: record.eventCode
        )))
      }
      if !reportStore.records.contains(where: { $0.id == record.id }) { try reportStore.add(record) }
      try linkStore.add(windowId: record.id, proofId: record.id)
      runtime.submitPendingOnNaturalTrigger()
    } catch {
      preconditionFailure("First upload UI fixture could not persist its synthetic record: \(error)")
    }
  }
}

private func fixtureHex(_ bytes: ExportedKotlinPackages.kotlin.ByteArray) -> String {
  (0..<Int(bytes.size)).map { index in
    String(format: "%02x", UInt8(bitPattern: bytes[Int32(index)]))
  }.joined()
}

private final class FirstUploadFixtureSavedRecordsOnly: EventDefinitionContextProvider {
  func resolve(eventIdHex: String, completion: @escaping (VerifiedSubmissionDefinition?) -> Void) {
    completion(nil)
  }
}

private final class FirstUploadFixtureNoSigning: SensingCryptography {
  func eventSigningPublicKey(eventCode: String) throws -> Data { throw CocoaError(.fileReadNoPermission) }
  func ownerPublicKey() throws -> Data { throw CocoaError(.fileReadNoPermission) }
  func signWindowReport(eventCode: String, bytes: Data) throws -> SensingRecoverableSignature {
    throw CocoaError(.fileReadNoPermission)
  }

  func signSelfProof(
    eventIdHash: Data, eventSigningPublicKey: Data, eninStart: UInt64, eninEnd: UInt64
  ) throws -> SensingRecoverableSignature? { throw CocoaError(.fileReadNoPermission) }

  func signWalletAcknowledgement(
    walletAddress: Data, walletSignature: Data
  ) throws -> SensingRecoverableSignature? { throw CocoaError(.fileReadNoPermission) }
}

struct FirstUploadNoticeUITestRoot: View {
  let fixture: FirstUploadNoticeUITestFixture
  @ObservedObject private var coordinator: AppCoordinator
  @ObservedObject private var reportStore: ReportSubmissionStore
  @State private var policyURL: URL?
  @State private var started = false

  init(fixture: FirstUploadNoticeUITestFixture) {
    self.fixture = fixture
    coordinator = fixture.coordinator
    reportStore = fixture.reportStore
  }

  var body: some View {
    RootView()
      .environmentObject(coordinator)
      .modifier(PolicyURLInterception(enabled: !fixture.usesSystemOpenURL) { policyURL = $0 })
      .safeAreaInset(edge: .bottom) {
        VStack {
          if coordinator.screen == .home {
            Button("Recheck fixture queue", action: fixture.submit)
              .accessibilityIdentifier("firstUpload.fixture.recheck")
            if fixture.mode == .eventCode {
              Button("Open event code fixture") { coordinator.homeEventCodeSheetPresented = true }
                .accessibilityIdentifier("firstUpload.fixture.eventCode")
            }
          }
          Text(verbatim: status)
            .accessibilityIdentifier("firstUpload.fixture.state")
          if let policyURL {
            Text(verbatim: policyURL.absoluteString)
              .accessibilityIdentifier("firstUpload.fixture.policyURL")
          }
        }
      }
      .task { trigger(.automatic) }
      .onChange(of: coordinator.accountSheetPresented) { _, shown in
        if shown { trigger(.account) }
      }
      .onChange(of: coordinator.homeEventCodeSheetPresented) { _, shown in
        if shown { trigger(.eventCode) }
      }
      .onChange(of: coordinator.welcomeAboutSensingPresented) { _, shown in
        if shown { trigger(.welcome) }
      }
  }

  private var status: String {
    reportStore.records.first { $0.id == fixture.recordID }?.submissionState.rawValue ?? "EMPTY"
  }

  private func trigger(_ mode: FirstUploadNoticeUITestFixture.Mode) {
    guard mode == fixture.mode, !started else { return }
    started = true
    fixture.submit()
  }
}

/// Replaces `openURL` with a recorder unless the fixture asked for the system
/// action.
private struct PolicyURLInterception: ViewModifier {
  let enabled: Bool
  let record: (URL) -> Void

  @ViewBuilder
  func body(content: Content) -> some View {
    if enabled {
      content.environment(\.openURL, OpenURLAction { url in
        record(url)
        return .handled
      })
    } else {
      content
    }
  }
}
#endif
