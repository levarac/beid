// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import BeidSharedKit
import SwiftUI

/// Flat 2b screen 08. An event here is a group of stored recording Proofs;
/// no event schedule is stored. Each session's report status uses its own
/// UUID links; report details with known windows live inside that session.
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
    EventGrouping.orderedSessions(for: representative, in: proofStore.proofs)
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
          Button("Rejoin", systemImage: "arrow.clockwise") {
            Task { await coordinator.rejoinPastEventResolvingCanonicalId(code: eventCode) }
          }
          .disabled(!sensing.canSelectEventToJoin)
          .accessibilityLabel(String(
            localized: "eventDetail.rejoin.accessibilityLabel",
            defaultValue: "Rejoin \(representative.eventName)",
            comment: "VoiceOver label for rejoining this stored event by its event code; the inserted name is operator supplied."
          ))
          .accessibilityIdentifier("event-detail.rejoin")
        }
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
          Text(proof.date.formatted(date: .omitted, time: .shortened))
            .beidTextStyle(DS.Font.Library.title15)
            .foregroundStyle(DS.Color.textPrimary)
          Spacer(minLength: DS.Space.s)
          Text(sessionStatus(proof))
            .beidTextStyle(DS.Font.Library.labelMono10)
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
      localized: "record.openSession",
      defaultValue: "Open session \(index), \(proof.date.formatted(date: .omitted, time: .shortened)), \(sessionStatus(proof))",
      comment: "VoiceOver label for an Event Detail session row that opens this recording session's observations."
    ))
    .accessibilityIdentifier("event-detail.observation.\(index)")
  }

  private func sessionStatus(_ proof: Proof) -> String {
    switch ReportProofLinkPresentation.readReports(
      for: proof, submissionStore: submissionStore,
      linkStore: coordinator.reportProofLinkStore, proofStore: proofStore
    ) {
    case .failure: return String(localized: "REPORT STATUS UNAVAILABLE")
    case .success(let reports): return ReportProgressPresentation(records: reports.map(\.record)).summary
    }
  }

  private func sessionMeasurements(_ aggregate: BeidSharedKit.aggregation.SessionAggregate?) -> String {
    guard let aggregate else { return String(localized: "Measurements unavailable") }
    return SessionDisplay.measurements(aggregate)
  }

  @ViewBuilder private var proofs: some View {
    // The single event entry keeps the earliest session's existing UUID.
    // Its detail names that selected session; other sessions remain separate.
    if let anchor = sessions.first, proofStore.proof(withId: anchor.id) != nil {
      let state = SessionDisplay.proofState(hasSelfProof: sensing.selfProofRecord(forProofId: anchor.id) != nil)
      VStack(alignment: .leading, spacing: 0) {
        Text(String(localized: "record.event.count", defaultValue: "RECORDS · 1"))
          .beidTextStyle(DS.Font.Library.labelMono10)
          .foregroundStyle(DS.Color.textSecondary)
          .padding(.bottom, DS.Space.s)
        hairline
        NavigationLink {
          ItemDetailView(proof: anchor)
        } label: {
          HStack(spacing: DS.Space.m) {
            RecordSigilSlot(input: sensing.sigilInput(forProofId: anchor.id), placement: .eventDetailRow, isDeviceRecord: true)
            VStack(alignment: .leading, spacing: DS.Space.xs) {
              Text("Attendance Record").beidTextStyle(DS.Font.Library.title15)
              Text(String(localized: "record.event.sessions", defaultValue: "SESSIONS · \(sessions.count)"))
                .beidTextStyle(DS.Font.Library.labelMono10)
                .foregroundStyle(DS.Color.textSecondary)
            }
            Spacer(minLength: 0)
            Text("→").beidTextStyle(DS.Font.Library.labelMono11Time).accessibilityHidden(true)
          }
          .foregroundStyle(DS.Color.textPrimary)
          .frame(minHeight: DS.Size.proofRowMinHeight)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(
          localized: "record.openEventRecord", defaultValue: "Open record, selected session 1, \(state)"
        ))
        .accessibilityIdentifier("event-detail.proof.1")
        hairline
      }
    } else {
      Text("RECORDS · 0").beidTextStyle(DS.Font.Library.labelMono10)
      Text("No records are stored for this event.").beidTextStyle(DS.Font.Library.body13)
    }
  }

  private var hairline: some View {
    Rectangle()
      .fill(DS.Color.strokeHairline)
      .frame(height: DS.Size.hairline)
  }
}
