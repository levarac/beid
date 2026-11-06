// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import BeidSharedKit
import SwiftUI

/// The five values in frame 09. Record existence and aggregate counts are
/// inputs so presentation never infers a signature from ProofSignatureState
/// or a connected wallet. The screenshot tour supplies only these display
/// values; it creates no durable signing or reporting artifact.
struct ProofDetailPresentation {
  let method: String
  let status: String
  let signature: String
  let withValue: String

  init(
    method: String,
    hasSelfProof: Bool,
    hasBinding: Bool,
    deviceCount: Int?,
    windowCount: Int?,
    sessionCount: Int
  ) {
    self.method = method == "Bluetooth Sensing"
      ? String(localized: "proofDetail.method.bluetooth", defaultValue: "Bluetooth sensing")
      : method
    status = hasSelfProof
      ? String(localized: "Sealed")
      : String(
        localized: "proofDetail.status.recorded",
        defaultValue: "Recorded on device",
        comment: "Proof Detail status when a Proof is stored locally but no matching self-proof signature record exists. Do not imply sealing or third-party verification."
      )
    if hasBinding {
      signature = String(
        localized: "proofDetail.signature.bound",
        defaultValue: "Bound to wallet",
        comment: "Proof Detail signature value shown only when a wallet BindingRecord belongs to this exact Proof."
      )
    } else if hasSelfProof {
      signature = String(
        localized: "proofDetail.signature.selfSigned",
        defaultValue: "Self-signed on device",
        comment: "Proof Detail signature value when a matching owner-key SelfProofRecord exists, but no wallet binding exists. This does not mean third-party verification."
      )
    } else {
      signature = Self.unavailable
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
        defaultValue: "^[\(deviceCount) peers](inflect: true)",
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

  private static var unavailable: String {
    String(
      localized: "proofDetail.value.unavailable",
      defaultValue: "Not yet available",
      comment: "Proof Detail value when no matching signature record or session aggregate snapshot exists. No missing count should appear as zero."
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
      sessionCount: groupSessions.count
    )
  }

  var body: some View {
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

          VStack(spacing: 0) {
            keyValueRow(String(localized: "METHOD"), value: presentation.method)
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
            keyValueRow(String(localized: "STATUS"), value: presentation.status)
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
            proof: proof, sensing: coordinator.sensingCoordinator,
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
private struct RecordEvidenceLadder: View {
  let proof: Proof
  @ObservedObject var sensing: SensingCoordinator
  @ObservedObject var submissionStore: ReportSubmissionStore
  @ObservedObject var proofStore: ProofStore
  @ObservedObject var linkStore: ReportProofLinkStore

  var body: some View {
    VStack(alignment: .leading, spacing: DS.Space.m) {
      let ordinal = EventGrouping.sessionOrdinal(of: proof, in: proofStore.proofs) ?? 1
      Text(String(localized: "record.selectedSession", defaultValue: "SELECTED SESSION \(ordinal)"))
        .beidTextStyle(DS.Font.Library.labelMono10)
      evidence(
        sensing.selfProofRecord(forProofId: proof.id) == nil ? "RECORDED ON DEVICE" : "SEALED ON THIS PHONE",
        value: String(localized: "Kept on this phone")
      )
      switch ReportProofLinkPresentation.readReports(
        for: proof, submissionStore: submissionStore, linkStore: linkStore, proofStore: proofStore
      ) {
      case .failure:
        evidence("REPORT STATUS", value: String(localized: "NOT YET AVAILABLE"))
      case .success(let reports):
        Text(verbatim: ReportProgressPresentation(records: reports.map(\.record)).summary)
          .beidTextStyle(DS.Font.Library.labelMono10)
        if reports.isEmpty {
          evidence("SENT TO", value: String(localized: "NOT YET AVAILABLE"))
          evidence("ACCEPTANCE RECEIPT", value: String(localized: "NOT YET AVAILABLE"))
        }
        ForEach(reports, id: \.record.id) { report in
          let received = !report.record.isTerminal && report.record.submissionState == .accepted && report.record.isReceiptStored
          VStack(alignment: .leading, spacing: DS.Space.s) {
            Text(String(localized: "eventDetail.report.title", defaultValue: "Report #\(report.ordinal)"))
              .beidTextStyle(DS.Font.Library.title15)
            evidence(
              received ? "SENT TO" : "DESTINATION",
              value: submissionOperatorOrigin(report.record.endpoint) ?? String(localized: "NOT YET AVAILABLE")
            )
            evidence("DELIVERY", value: ReportDetailPresentation(record: report.record).delivery)
            evidence("DELIVERY TIME", value: String(localized: "NOT YET AVAILABLE"))
            evidence(received ? "ACCEPTED" : "ACCEPTANCE RECEIPT", value: ReportDetailPresentation(record: report.record).receipt)
            evidence("RECEIPT TIME", value: String(localized: "NOT YET AVAILABLE"))
          }
          .accessibilityIdentifier("record.evidence.\(report.record.id.uuidString)")
        }
      }
      evidence("REPRODUCIBLE MATERIAL", value: String(localized: "NOT YET AVAILABLE"))
      evidence("THIRD-PARTY RESULT", value: String(localized: "NOT YET AVAILABLE"))
      evidence("MUTUAL OBSERVATION", value: String(localized: "NOT YET AVAILABLE"))
      evidence("INCLUDED IN PUBLISHED DATA", value: String(localized: "NOT YET AVAILABLE"))
      if let code = proof.eventCode {
        Text("EVENT DATA").beidTextStyle(DS.Font.Library.labelMono10)
        evidence("JOIN ACTION", value: String(localized: "Joined"))
        evidence(
          "EVENT WINDOWS ON THIS PHONE",
          value: sensing.availableRecordedWindowCount(forEventCode: code).map { String($0) } ?? String(localized: "NOT YET AVAILABLE")
        )
        evidence(
          "EVENT COUNT-ONLY WINDOWS",
          value: sensing.excludedWindowCount(forEventCode: code).map { String($0) } ?? String(localized: "NOT YET AVAILABLE")
        )
      }
    }
    .foregroundStyle(DS.Color.textPrimary)
  }

  private func evidence(_ title: LocalizedStringKey, value: String) -> some View {
    VStack(alignment: .leading, spacing: DS.Space.xs) {
      Text(title).beidTextStyle(DS.Font.Library.labelMono10).foregroundStyle(DS.Color.textSecondary)
      Text(verbatim: value).beidTextStyle(DS.Font.Library.body13)
    }
  }
}
