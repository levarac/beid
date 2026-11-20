// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import BeidSharedKit
import SwiftUI

/// Frame 09's values and incomplete-record notice. Record existence and aggregate counts are
/// inputs so presentation never infers a signature from ProofSignatureState
/// or a connected wallet. The screenshot tour supplies only these display
/// values; it creates no durable signing or reporting artifact.
struct ProofDetailPresentation {
  let method: String
  let status: String
  let signature: String
  let withValue: String
  let incompleteReason: String?
  let isSealedOnDevice: Bool

  init(
    method: String,
    hasSelfProof: Bool,
    hasBinding _: Bool,
    deviceCount: Int?,
    windowCount: Int?,
    sessionCount: Int,
    selfProofDiscardedForKeyChange: Bool = false
  ) {
    self.method = method == "Bluetooth Sensing"
      ? String(localized: "proofDetail.method.bluetooth", defaultValue: "Bluetooth sensing")
      : method
    isSealedOnDevice = hasSelfProof && !selfProofDiscardedForKeyChange
    incompleteReason = selfProofDiscardedForKeyChange
      ? String(
        localized: "proofDetail.incompleteReason",
        defaultValue: "This recording could not be signed because its signing key changed or could not be verified. The record is kept on this phone.",
        comment: "Reason for an incomplete stored record after signing-key continuity failed. The record and its session/report evidence are retained."
      )
      : nil
    status = selfProofDiscardedForKeyChange
      ? String(localized: "proofDetail.status.incomplete", defaultValue: "Recording incomplete")
      : hasSelfProof
      ? String(localized: "Sealed")
      : String(
        localized: "proofDetail.status.recorded",
        defaultValue: "Recorded on device",
        comment: "Proof Detail status when a Proof is stored locally but no matching self-proof signature record exists. Do not imply sealing or third-party verification."
      )
    if selfProofDiscardedForKeyChange {
      signature = Self.signatureUnavailable
    } else if hasSelfProof {
      // A legacy binding's acknowledgement is not this recording's self-signature.
      signature = String(
        localized: "proofDetail.signature.selfSigned",
        defaultValue: "Self-signed on device",
        comment: "Record Detail signature value only when a matching on-device SelfProofRecord exists. This does not mean third-party verification."
      )
    } else {
      signature = Self.signatureUnavailable
    }
    if sessionCount > 1 {
      // A selected Proof is one session, never the entire event.
      withValue = String(
        localized: "proofDetail.with.multipleSessions",
        defaultValue: "See each session",
        comment: "Proof Detail WITH value for an event with multiple recording sessions. The participation summary below lists each session separately; never show one session's counts as event-wide."
      )
    } else if let deviceCount, let windowCount {
      let peers = String(
        localized: "proofDetail.with.peers",
        defaultValue: "^[\(deviceCount) devices](inflect: true)",
        comment: "Number of distinct nearby devices in this Proof's session aggregate; this does not imply mutual confirmation."
      )
      let windows = String(
        localized: "proofDetail.with.windows",
        defaultValue: "^[\(windowCount) windows](inflect: true)",
        comment: "Number of observed time windows in this Proof's session aggregate."
      )
      withValue = String(
        localized: "proofDetail.with.counts",
        defaultValue: "\(peers) · \(windows)",
        comment: "Proof Detail WITH value for one session. Device count and observed window count come from this Proof's durable aggregate snapshot, not an event-wide sum."
      )
    } else {
      withValue = Self.unavailable
    }
  }

  private static var signatureUnavailable: String {
    String(
      localized: "proofDetail.signature.unavailable",
      defaultValue: "NOT AVAILABLE",
      comment: "Record Detail signature value when no matching on-device self-signature is available, including a discarded self-proof or a legacy binding alone. This does not imply a key change unless the record is flagged incomplete."
    )
  }

  private static var unavailable: String {
    String(
      localized: "proofDetail.value.unavailable",
      defaultValue: "Not yet available",
      comment: "Proof Detail value when no session aggregate snapshot exists. No missing count should appear as zero."
    )
  }
}

/// Flat 2b frame 09, backed by the selected Proof's own durable data.
/// The native NavigationStack owns the back button and interactive pop.
struct ItemDetailView: View {
  @EnvironmentObject private var coordinator: AppCoordinator
  let proof: Proof
  var presentationOverride: ProofDetailPresentation? = nil

  /// Event Detail can open any selected session's Proof; Daily Summary can
  /// also pass one directly. Grouping informs the WITH value and summary route.
  private var groupSessions: [Proof] {
    EventGrouping.sessions(for: proof, in: coordinator.proofStore.proofs)
  }

  private var presentation: ProofDetailPresentation {
    if let presentationOverride { return presentationOverride }
    let sensing = coordinator.sensingCoordinator
    let aggregate = sensing.sessionAggregateSnapshot(forProofId: proof.id)
    return ProofDetailPresentation(
      method: proof.method,
      hasSelfProof: sensing.selfProofRecord(forProofId: proof.id) != nil,
      hasBinding: sensing.bindingRecord(forProofId: proof.id) != nil,
      deviceCount: aggregate.map { Int($0.deviceCount) },
      windowCount: aggregate.map { Int($0.windowCount) },
      sessionCount: groupSessions.count,
      selfProofDiscardedForKeyChange: coordinator.proofStore.proof(withId: proof.id)?.selfProofDiscardedForKeyChange
        ?? proof.selfProofDiscardedForKeyChange
    )
  }

  var body: some View {
    let presentation = presentation
    ScrollView {
      BeidAdaptiveContent {
        VStack(alignment: .leading, spacing: 0) {
          RecordSigilSlot(
            input: coordinator.sensingCoordinator.sigilInput(forProofId: proof.id),
            placement: .proofDetail,
            isDeviceRecord: true
          )
          .frame(maxWidth: .infinity)
          .padding(.top, DS.Space.s)

          Text("Attendance\nRecord")
            .beidTextStyle(DS.Font.Library.display46)
            .foregroundStyle(DS.Color.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("proof.detail.title")
            .padding(.top, DS.Space.l + DS.Space.xs)

          if let reason = presentation.incompleteReason {
            VStack(alignment: .leading, spacing: DS.Space.s) {
              Text(verbatim: presentation.status)
                .beidTextStyle(DS.Font.Library.title15)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("record.incomplete.title")
              Text(verbatim: reason)
                .beidTextStyle(DS.Font.Library.body13)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("record.incomplete.reason")
            }
            .foregroundStyle(DS.Color.textPrimary)
            .padding(.vertical, DS.Space.m)
          }

          VStack(spacing: 0) {
            keyValueRow(
              String(localized: "RECORD ID"),
              value: RecordIDDisplay.abbreviated(proof.id),
              valueStyle: DS.Font.Library.labelMono13Value,
              accessibilityValue: String(
                localized: "proofDetail.recordID.accessibility",
                defaultValue: "Record ID \(proof.id.uuidString)",
                comment: "VoiceOver reads the complete Proof UUID even though the visible record ID is abbreviated."
              )
            )
            keyValueRow(String(localized: "METHOD"), value: presentation.method)
            keyValueRow(String(localized: "SIGNATURE"), value: presentation.signature)
            keyValueRow(String(localized: "WITH"), value: presentation.withValue)
          }
          .padding(.top, DS.Space.xs)

          LinkedReportsSection(
            heading: String(
              localized: "proofDetail.fromReports",
              defaultValue: "FROM REPORTS",
              comment: "Section listing the stored reports whose observation window was closed in this Proof's recording session. No count is shown."
            ),
            identifierPrefix: "proof-detail.report",
            proof: proof,
            submissionStore: coordinator.reportSubmissionStore,
            proofStore: coordinator.proofStore,
            linkStore: coordinator.reportProofLinkStore,
            sensing: coordinator.sensingCoordinator
          )

          RecordEvidenceLadder(
            proof: proof, hasSelfProof: presentation.isSealedOnDevice,
            sensing: coordinator.sensingCoordinator,
            submissionStore: coordinator.reportSubmissionStore,
            proofStore: coordinator.proofStore, linkStore: coordinator.reportProofLinkStore
          )
          .padding(.top, DS.Space.m)

          sessionRoutes
            .padding(.top, DS.Space.l)
            .padding(.bottom, DS.Space.l)
        }
        .padding(.horizontal, DS.Space.pageMargin)
      }
    }
    .background(DS.Color.surfaceCanvas.ignoresSafeArea())
    .navigationTitle(proof.eventName)
    .navigationBarTitleDisplayMode(.inline)
  }

  private func keyValueRow(
    _ label: String,
    value: String,
    valueStyle: DS.Font.Style = DS.Font.Library.title15,
    accessibilityValue: String? = nil
  ) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: DS.Space.m) {
      Text(verbatim: label)
        .beidTextStyle(DS.Font.Library.labelMono10)
        .foregroundStyle(DS.Color.textSecondary)
      Spacer(minLength: DS.Space.s)
      Text(verbatim: value)
        .beidTextStyle(valueStyle)
        .foregroundStyle(DS.Color.textPrimary)
        .multilineTextAlignment(.trailing)
        .accessibilityLabel(accessibilityValue ?? value)
    }
    .frame(minHeight: DS.Size.keyValueRowMinHeight)
    .overlay(alignment: .top) {
      Rectangle()
        .fill(DS.Color.strokeHairline)
        .frame(height: DS.Size.hairline)
    }
  }

  private var sessionRoutes: some View {
    VStack(alignment: .leading, spacing: DS.Space.s) {
      Text("SESSIONS").beidTextStyle(DS.Font.Library.labelMono10).foregroundStyle(DS.Color.textSecondary)
      ForEach(Array(EventGrouping.orderedSessions(for: proof, in: coordinator.proofStore.proofs).enumerated()), id: \.element.id) { index, session in
        NavigationLink {
          ObservationDetailView(
            proof: session, sessionNumber: index + 1,
            aggregate: coordinator.sensingCoordinator.sessionAggregateSnapshot(forProofId: session.id)
          )
        } label: {
          Text(verbatim: session.date.formatted(date: .abbreviated, time: .shortened))
            .beidTextStyle(DS.Font.Library.title15)
            .frame(maxWidth: .infinity, minHeight: DS.Size.sessionRowMinHeight, alignment: .leading)
        }
        .accessibilityIdentifier("record.session.\(session.id.uuidString)")
      }
    }
  }
}

/// Every network stage belongs to this selected session and exact report UUID.
/// A request starting is not delivery evidence. Until a durable receipt exists,
/// the send and acceptance rungs stay pending; partial sessions stay partial.
struct RecordSendingLadderPresentation {
  struct Rung: Identifiable {
    let number: Int
    let title: String
    let reached: Bool
    var id: Int { number }
  }

  let rungs: [Rung]

  init(hasSelfProof: Bool, records: [ReportSubmissionRecord]?) {
    let records = records ?? []
    let received = records.filter { !$0.isTerminal && $0.submissionState == .accepted && $0.isReceiptStored }
    let allReceived = !records.isEmpty && received.count == records.count
    let origins = Set(received.compactMap { submissionOperatorOrigin($0.endpoint) })
    let sentTitle: String
    if allReceived, origins.count == 1, let origin = origins.first {
      sentTitle = String(localized: "record.sentToOrganizer", defaultValue: "SENT TO \(origin)")
    } else {
      sentTitle = String(localized: "SENT TO ORGANIZER")
    }
    rungs = [
      Rung(number: 1, title: String(localized: hasSelfProof ? "SEALED ON THIS PHONE" : "RECORDED ON THIS PHONE"), reached: hasSelfProof),
      Rung(number: 2, title: sentTitle, reached: allReceived),
      Rung(number: 3, title: String(localized: "ACCEPTED"), reached: allReceived),
      Rung(number: 4, title: String(localized: "THIRD-PARTY RESULT"), reached: false)
    ]
  }
}

private struct RecordEvidenceLadder: View {
  let proof: Proof
  let hasSelfProof: Bool
  @ObservedObject var sensing: SensingCoordinator
  @ObservedObject var submissionStore: ReportSubmissionStore
  @ObservedObject var proofStore: ProofStore
  @ObservedObject var linkStore: ReportProofLinkStore

  private var reports: [LinkedReport]? {
    try? ReportProofLinkPresentation.readReports(
      for: proof, submissionStore: submissionStore, linkStore: linkStore, proofStore: proofStore
    ).get()
  }

  var body: some View {
    let reports = reports
    let presentation = RecordSendingLadderPresentation(
      hasSelfProof: hasSelfProof,
      records: reports?.map(\.record)
    )
    VStack(alignment: .leading, spacing: DS.Space.m) {
      let ordinal = EventGrouping.sessionOrdinal(of: proof, in: proofStore.proofs) ?? 1
      Text(String(localized: "record.selectedSession", defaultValue: "SELECTED SESSION \(ordinal)"))
        .beidTextStyle(DS.Font.Library.labelMono10)
      ForEach(presentation.rungs) { rung in
        HStack(alignment: .top, spacing: DS.Space.m) {
          Text(verbatim: String(format: "%02d", rung.number))
            .beidTextStyle(DS.Font.Library.labelMono13Value)
            .foregroundStyle(rung.reached ? DS.Color.textPrimary : DS.Color.textSecondary)
            .accessibilityHidden(true)
          VStack(alignment: .leading, spacing: DS.Space.s) {
            Text(verbatim: rung.title)
              .beidTextStyle(DS.Font.Library.labelMono10)
              .accessibilityIdentifier("record.ladder.\(rung.number).title")
            rungDetails(rung.number, reports: reports)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, DS.Space.m)
        .overlay(alignment: .top) {
          Rectangle().fill(DS.Color.strokeHairline).frame(height: DS.Size.hairline)
        }
        .accessibilityIdentifier("record.ladder.\(rung.number)")
      }
      if let code = proof.eventCode {
        Text("EVENT DATA").beidTextStyle(DS.Font.Library.labelMono10)
        evidence("JOIN ACTION", value: String(localized: "Joined"))
        evidence(
          "EVENT WINDOWS ON THIS PHONE",
          value: sensing.availableRecordedWindowCount(forEventCode: code).map { String($0) } ?? String(localized: "NOT YET AVAILABLE")
        )
        evidence(
          LocalizedStringKey(ReportDetailPresentation.excludedWindowLabel),
          value: sensing.excludedWindowCount(forEventCode: code).map { String($0) } ?? String(localized: "NOT YET AVAILABLE")
        )
      }
    }
    .foregroundStyle(DS.Color.textPrimary)
  }

  @ViewBuilder private func rungDetails(_ number: Int, reports: [LinkedReport]?) -> some View {
    if number == 1 {
      Text("Kept on this phone").beidTextStyle(DS.Font.Library.body13)
    } else if number == 4 {
      Text("NOT YET AVAILABLE").beidTextStyle(DS.Font.Library.body13)
    } else if let reports, !reports.isEmpty {
      ForEach(reports, id: \.record.id) { report in
        let record = report.record
        let received = !record.isTerminal && record.submissionState == .accepted && record.isReceiptStored
        VStack(alignment: .leading, spacing: DS.Space.s) {
          Text(String(localized: "eventDetail.report.title", defaultValue: "Report #\(report.ordinal)"))
            .beidTextStyle(DS.Font.Library.title15)
          if number == 2 {
            evidence(
              received ? "SENT TO" : "DESTINATION",
              value: submissionOperatorOrigin(record.endpoint) ?? String(localized: "NOT YET AVAILABLE")
            )
            evidence("DELIVERY", value: ReportDetailPresentation(record: record).delivery)
            if received {
              evidence("DELIVERY TIME", value: String(localized: "NOT YET AVAILABLE"))
            }
          } else if received, let receipt = record.acceptanceReceiptHex {
            evidence("ACCEPTANCE RECEIPT", value: receipt)
            evidence("RECEIPT TIME", value: String(localized: "NOT YET AVAILABLE"))
          } else {
            Text(verbatim: ReportDetailPresentation(record: record).receipt)
              .beidTextStyle(DS.Font.Library.body13)
          }
        }
        .accessibilityIdentifier("record.ladder.\(number).report.\(record.id.uuidString)")
      }
    } else {
      Text("NOT YET AVAILABLE").beidTextStyle(DS.Font.Library.body13)
      if reports == nil {
        Text("REPORT STATUS UNAVAILABLE").beidTextStyle(DS.Font.Library.body13)
      }
    }
  }

  private func evidence(_ title: LocalizedStringKey, value: String) -> some View {
    VStack(alignment: .leading, spacing: DS.Space.xs) {
      Text(title).beidTextStyle(DS.Font.Library.labelMono10).foregroundStyle(DS.Color.textSecondary)
      Text(verbatim: value).beidTextStyle(DS.Font.Library.body13)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}
