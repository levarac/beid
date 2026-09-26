// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import BeidSharedKit
import SwiftUI

/// Flat 2b screen 08. An event here is a group of stored recording Proofs;
/// no event schedule is stored. Report-to-session links (beid#701) are shown
/// on 09, 11 and 12; this screen does not show them yet (OD-9).
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
          Text(SessionDisplay.title(index))
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

  private func sessionMeasurements(_ aggregate: BeidSharedKit.aggregation.SessionAggregate?) -> String {
    guard let aggregate else { return String(localized: "Measurements unavailable") }
    return SessionDisplay.measurements(aggregate)
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
              EventReportRow(
                ordinal: index + 1,
                record: record,
                identifier: "event-detail.report.\(record.id.uuidString)",
                submissionStore: submissionStore,
                proofStore: proofStore,
                linkStore: coordinator.reportProofLinkStore,
                sensing: sensing
              )
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
        let state = SessionDisplay.proofState(
          hasSelfProof: sensing.selfProofRecord(forProofId: proof.id) != nil
        )
        hairline
        NavigationLink {
          ItemDetailView(proof: proof)
        } label: {
          HStack(spacing: DS.Space.m) {
            RecordSigilSlot(
              input: sensing.sigilInput(forProofId: proof.id),
              placement: .eventDetailRow
            )
            VStack(alignment: .leading, spacing: DS.Space.xs) {
              Text(SessionDisplay.proofTitle(index + 1))
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
