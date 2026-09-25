// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import BeidSharedKit
import SwiftUI

/// Flat 2b screen 08. An event here is a group of stored recording Proofs;
/// neither an event schedule nor a report-to-session relationship is stored.
struct EventDetailView: View {
  @EnvironmentObject private var coordinator: AppCoordinator
  @ObservedObject private var sensing: SensingCoordinator
  @ObservedObject private var proofStore: ProofStore
  @ObservedObject private var submissionStore: ReportSubmissionStore
  let representative: Proof

  init(
    representative: Proof,
    sensing: SensingCoordinator,
    proofStore: ProofStore,
    submissionStore: ReportSubmissionStore
  ) {
    self.representative = representative
    self.sensing = sensing
    self.proofStore = proofStore
    self._submissionStore = ObservedObject(wrappedValue: submissionStore)
  }

  private var sessions: [Proof] {
    EventGrouping.sessions(for: representative, in: proofStore.proofs)
      .sorted { $0.date < $1.date }
  }

  private var eventCode: String? { representative.eventCode }

  var body: some View {
    ScrollView {
      BeidAdaptiveContent {
        VStack(alignment: .leading, spacing: 0) {
          Text(verbatim: representative.eventName)
            .beidTextStyle(DS.Font.Library.display46)
            .foregroundStyle(DS.Color.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 220, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("event-detail.heading")

          Text(recordedDateCaption)
            .beidTextStyle(DS.Font.Library.labelMono10)
            .foregroundStyle(DS.Color.textSecondary)
            .padding(.top, DS.Space.s + DS.Space.xs)

          observations
            .padding(.top, DS.Space.xl)
          reports
            .padding(.top, DS.Space.xl)
          proofs
            .padding(.top, DS.Space.xl)
        }
        .padding(.horizontal, DS.Space.pageMargin)
        .padding(.top, DS.Space.s)
        .padding(.bottom, DS.Space.xl)
      }
    }
    .background(DS.Color.surfaceCanvas)
    .navigationTitle("")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      if let eventCode {
        ToolbarItem(placement: .topBarTrailing) {
          Button("REJOIN") {
            Task { await coordinator.rejoinPastEventResolvingCanonicalId(code: eventCode) }
          }
          .beidTextStyle(DS.Font.Library.labelMono11)
          .frame(minWidth: DS.Size.minHitTarget, minHeight: DS.Size.minHitTarget)
          .contentShape(Rectangle())
          .disabled(sensing.joinedEventCode != nil)
          .accessibilityLabel(String(
            localized: "eventDetail.rejoin.accessibilityLabel",
            defaultValue: "Rejoin \(representative.eventName)",
            comment: "VoiceOver label for rejoining this stored event by its event code; the inserted name is operator supplied."
          ))
          .accessibilityIdentifier("event-detail.rejoin")
        }
        .beidWithoutSharedBackground()
      }
    }
    .accessibilityIdentifier("event-detail")
  }

  private var recordedDateCaption: String {
    let date = representative.date.formatted(.dateTime.month(.abbreviated).day().year()).uppercased()
    return String(
      localized: "eventDetail.recordedDate",
      defaultValue: "RECORDED \(date)",
      comment: "Recording start date from the newest stored Proof; the app has no persisted event date or venue for past events."
    )
  }

  private var observations: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(observationHeading)
        .beidTextStyle(DS.Font.Library.labelMono10)
        .foregroundStyle(DS.Color.textSecondary)
        .padding(.bottom, DS.Space.s)

      ForEach(Array(sessions.enumerated()), id: \.element.id) { index, proof in
        hairline
        sessionRow(index: index + 1, proof: proof)
      }
      hairline
    }
  }

  private var observationHeading: String {
    let count = sessions.count
    return String(
      localized: "eventDetail.observations.sessions",
      defaultValue: "OBSERVATIONS · \(count) SESSIONS",
      comment: "Section label and independently pluralized number of stored recording sessions for this event."
    )
  }

  private func sessionRow(index: Int, proof: Proof) -> some View {
    let aggregate = sensing.sessionAggregateSnapshot(forProofId: proof.id)
    return NavigationLink {
      ObservationDetailView(proof: proof, sessionNumber: index, aggregate: aggregate)
    } label: {
      VStack(alignment: .leading, spacing: DS.Space.xs) {
        HStack(alignment: .firstTextBaseline) {
          Text(sessionTitle(index))
            .beidTextStyle(DS.Font.Library.title15)
            .foregroundStyle(DS.Color.textPrimary)
          Spacer(minLength: DS.Space.s)
          Text(proof.date.formatted(date: .omitted, time: .shortened))
            .beidTextStyle(DS.Font.Library.labelMono11Time)
            .foregroundStyle(DS.Color.textPrimary)
        }
        Text(sessionMeasurements(aggregate))
          .beidTextStyle(DS.Font.Library.labelMono10Tight)
          .foregroundStyle(DS.Color.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, minHeight: DS.Size.sessionRowMinHeight, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(String(
      localized: "observationDetail.openSession",
      defaultValue: "Open observations for session \(index)",
      comment: "VoiceOver label for an Event Detail session row that opens this recording session's observations."
    ))
    .accessibilityIdentifier("event-detail.observation.\(index)")
  }

  private func sessionTitle(_ index: Int) -> String {
    String(
      localized: "eventDetail.session.title",
      defaultValue: "Session \(index)",
      comment: "Ordinal label for one stored recording session within an event, oldest first."
    )
  }

  private func sessionMeasurements(_ aggregate: BeidSharedKit.aggregation.SessionAggregate?) -> String {
    guard let aggregate else { return String(localized: "Measurements unavailable") }
    let devices = Int(aggregate.deviceCount)
    let windows = Int(aggregate.windowCount)
    return String(
      localized: "eventDetail.session.measurements",
      defaultValue: "\(devices) devices · \(windows) windows",
      comment: "Session's independently pluralized sensed-device and observation-window counts, read only from its persisted aggregate snapshot."
    )
  }

  private var reports: some View {
    VStack(alignment: .leading, spacing: DS.Space.s) {
      if let eventCode {
        switch submissionStore.eventRecords(forEventCode: eventCode) {
        case .failure(.unreadableStore):
          sectionLabel(String(localized: "Reports"))
          Text("Reports unavailable on this device")
            .beidTextStyle(DS.Font.Library.body13)
            .foregroundStyle(DS.Color.textSecondary)
        case .failure(.invalidEventCode):
          sectionLabel(String(localized: "Reports"))
          Text("Reports unavailable for this event code")
            .beidTextStyle(DS.Font.Library.body13)
            .foregroundStyle(DS.Color.textSecondary)
        case .success(let records):
          sectionLabel(records.isEmpty ? String(localized: "Reports") : reportHeading(records.count))
          if records.isEmpty {
            noReports
          } else {
            ForEach(Array(records.enumerated()), id: \.element.id) { index, record in
              hairline
              reportRow(index: index + 1, record: record)
            }
            hairline
          }
        }
      } else {
        sectionLabel(String(localized: "Reports"))
        Text("Reports unavailable for this older proof")
          .beidTextStyle(DS.Font.Library.body13)
          .foregroundStyle(DS.Color.textSecondary)
      }
    }
  }

  private func reportHeading(_ count: Int) -> String {
    String(
      localized: "eventDetail.reports.count",
      defaultValue: "REPORTS · \(count)",
      comment: "Section label and number of locally stored canonical Observation submission records for this event."
    )
  }

  private var noReports: some View {
    BeidEmptyBlock {
      VStack(spacing: DS.Space.s) {
        Text("NO REPORTS YET")
          .beidTextStyle(DS.Font.Library.labelMono10)
          .foregroundStyle(DS.Color.textPrimary)
        Text("No reports for this event are stored on this device.")
          .beidTextStyle(DS.Font.Library.body13)
          .foregroundStyle(DS.Color.textSecondary)
          .multilineTextAlignment(.center)
      }
    }
  }

  private func reportRow(index: Int, record: ReportSubmissionRecord) -> some View {
    NavigationLink {
      ReportDetailView(
        recordID: record.id, reportIndex: index, submissionStore: submissionStore
      )
      .toolbar(.visible, for: .navigationBar)
    } label: {
      VStack(alignment: .leading, spacing: DS.Space.xs) {
        HStack {
          Text(reportTitle(index))
            .beidTextStyle(DS.Font.Library.title15)
            .foregroundStyle(DS.Color.textPrimary)
          Spacer(minLength: DS.Space.s)
          Text(reportStatus(record))
            .beidTextStyle(DS.Font.Library.labelMono10)
            .foregroundStyle(DS.Color.textPrimary)
        }
        Text(reportMetadata(record))
          .beidTextStyle(DS.Font.Library.labelMono10Tight)
          .foregroundStyle(DS.Color.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, minHeight: DS.Size.reportRowMinHeight, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("event-detail.report.\(record.id.uuidString)")
  }

  private func reportTitle(_ index: Int) -> String {
    String(
      localized: "eventDetail.report.title",
      defaultValue: "Report #\(index)",
      comment: "Ordinal label for a stored canonical Observation submission record, oldest first."
    )
  }

  private func reportStatus(_ record: ReportSubmissionRecord) -> String {
    if record.isTerminal { return String(localized: "Stopped") }
    switch record.submissionState {
    case .prepared: return String(localized: "Prepared")
    case .submitting: return String(localized: "Submitting")
    case .accepted:
      return record.acceptanceReceiptHex == nil
        ? String(localized: "Status unavailable") : String(localized: "Receipt stored")
    }
  }

  private func reportMetadata(_ record: ReportSubmissionRecord) -> String {
    let digest = shortDigest(record.observationDigestHex)
    if record.isTerminal {
      return String(
        localized: "eventDetail.report.stoppedMetadata",
        defaultValue: "\(digest) · Submission stopped",
        comment: "Stored report digest followed by a terminal local submission state; no rejection or operator verdict is implied."
      )
    }
    switch record.submissionState {
    case .prepared:
      return String(
        localized: "eventDetail.report.preparedMetadata",
        defaultValue: "\(digest) · On device · not sent",
        comment: "Stored report digest followed by the PREPARED local submission state; no network send has started."
      )
    case .submitting:
      return String(
        localized: "eventDetail.report.submittingMetadata",
        defaultValue: "\(digest) · Receipt unavailable",
        comment: "Stored report digest for a submission started without a stored operator receipt."
      )
    case .accepted:
      if record.acceptanceReceiptHex == nil {
        return String(
          localized: "eventDetail.report.missingReceiptMetadata",
          defaultValue: "\(digest) · Receipt unavailable",
          comment: "Stored report digest when a state says accepted but no operator receipt is stored; no acceptance claim is shown."
        )
      }
      return String(
        localized: "eventDetail.report.receiptMetadata",
        defaultValue: "\(digest) · Operator receipt on device",
        comment: "Stored report digest with an operator acceptance receipt durably present on this device."
      )
    }
  }

  private func shortDigest(_ digest: String) -> String {
    guard digest.count > 8 else { return digest }
    return "\(digest.prefix(4))…\(digest.suffix(4))"
  }

  private func sectionLabel(_ title: String) -> some View {
    Text(verbatim: title)
      .beidTextStyle(DS.Font.Library.labelMono10)
      .foregroundStyle(DS.Color.textSecondary)
  }

  private var proofs: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(proofHeading)
        .beidTextStyle(DS.Font.Library.labelMono10)
        .foregroundStyle(DS.Color.textSecondary)
        .padding(.bottom, DS.Space.s)
      ForEach(Array(sessions.enumerated()), id: \.element.id) { index, proof in
        let state = proofState(for: proof)
        hairline
        NavigationLink {
          ItemDetailView(proof: proof)
        } label: {
          HStack(spacing: DS.Space.m) {
            RecordSigilSlot(
              recordID: proof.id,
              size: DS.Size.proofRowMinHeight - DS.Space.l,
              ground: .canvas
            )
            VStack(alignment: .leading, spacing: DS.Space.xs) {
              Text(proofTitle(index + 1))
                .beidTextStyle(DS.Font.Library.title15)
                .foregroundStyle(DS.Color.textPrimary)
              Text(state)
                .beidTextStyle(DS.Font.Library.labelMono10)
                .foregroundStyle(DS.Color.textSecondary)
            }
            Spacer(minLength: 0)
            Text("→")
              .beidTextStyle(DS.Font.Library.labelMono11Time)
              .foregroundStyle(DS.Color.textPrimary)
              .accessibilityHidden(true)
          }
          .frame(minHeight: DS.Size.proofRowMinHeight)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(proofAccessibilityLabel(index + 1, state: state))
        .accessibilityIdentifier("event-detail.proof.\(index + 1)")
      }
      hairline
    }
  }

  private var proofHeading: String {
    let count = sessions.count
    return String(
      localized: "eventDetail.proofs.count",
      defaultValue: "PROOFS · \(count)",
      comment: "Section label and number of stored recording Proofs for this event."
    )
  }

  private func proofTitle(_ index: Int) -> String {
    String(
      localized: "eventDetail.proof.title",
      defaultValue: "Session \(index) proof",
      comment: "Opens the existing detail for the stored Proof collected in this numbered recording session."
    )
  }

  private func proofState(for proof: Proof) -> String {
    if sensing.selfProofRecord(forProofId: proof.id) != nil {
      return String(
        localized: "eventDetail.proof.state.sealed",
        defaultValue: "SEALED",
        comment: "Proof row state when a self-proof signature record exists for this exact stored Proof."
      )
    }
    return String(
      localized: "eventDetail.proof.state.recorded",
      defaultValue: "RECORDED ON DEVICE",
      comment: "Proof row state when no self-proof signature record exists for this exact stored Proof."
    )
  }

  private func proofAccessibilityLabel(_ index: Int, state: String) -> String {
    String(
      localized: "eventDetail.proof.accessibilityLabel",
      defaultValue: "Open proof for session \(index), \(state)",
      comment: "VoiceOver label for a Proof row. State comes only from a matching self-proof signature record."
    )
  }

  private var hairline: some View {
    Rectangle()
      .fill(DS.Color.strokeHairline)
      .frame(height: DS.Size.hairline)
  }
}
