// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import SwiftUI

/// Daily Summary screen (gh#291, Phase 2 — Phase 1's design is PM-approved).
/// iOS-only: Android has no collection-home surface yet to add this to
/// (AGENTS.md's current-state paragraph — `EventJoinScreen` stands in for
/// iOS's `.home`, and #121/#122 track the still-missing Android home). The
/// day-rollup decision itself still lives in `shared/` (`DailyRollupRuntime`
/// wraps `BeidSharedKit.aggregation`'s day-rollup functions), so Android
/// gets identical bucketing for free once its own home surface exists —
/// only this screen is iOS-only, not the underlying decision.
///
/// Deliberately omits any Verified / public-scope row (beid#240 precedent —
/// a state without backing must never be labeled "Verified"). Each record
/// row instead pushes into the same `ItemDetailView` `CollectionHomeView`
/// already uses (`coordinator.openProof`), which is where a participant
/// already reaches `TransparencyView`/`ParticipationSummaryView` for that
/// detail — this screen does not construct a second, day-scoped entry point
/// into those two surfaces.
struct DailySummaryView: View {
  @EnvironmentObject private var coordinator: AppCoordinator

  private static let timeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.timeStyle = .short
    formatter.dateStyle = .none
    return formatter
  }()

  /// The single source of "which proofs are today's" — routed through
  /// `DailyRollupRuntime` (shared's day-rollup decision), never a second,
  /// independent `Calendar`-based filter here. Both the record count and
  /// the row list below read this same array, so they cannot disagree.
  private var todaysProofs: [Proof] {
    DailyRollupRuntime.recordsToday(in: coordinator.proofStore.proofs) ?? []
  }

  var body: some View {
    ScrollView {
      BeidAdaptiveContent {
        VStack(alignment: .leading, spacing: DS.Space.l) {
          recordSection
          submissionSection
        }
        .padding(DS.Space.pageMargin)
      }
    }
    .background(DS.Color.surfaceCanvas)
    .navigationTitle(dailySummaryTitleText)
    .navigationBarTitleDisplayMode(.large)
  }

  @ViewBuilder
  private var recordSection: some View {
    if todaysProofs.isEmpty {
      BeidEmptyBlock {
        VStack(alignment: .leading, spacing: DS.Space.s) {
          Text(
            "No proofs yet today",
            comment: "Empty-state title on the Daily Summary screen when no proof has been collected yet today (local calendar day). Distinct from Collection Home's all-time empty state (\"No proofs yet\")."
          )
          .font(DS.Font.sectionTitle)
          .foregroundStyle(DS.Color.textPrimary)
          Text(
            "Proofs you collect today will show up here.",
            comment: "Empty-state body on the Daily Summary screen, directly under \"No proofs yet today\". Describes what will populate this list, not an instruction to act right now."
          )
          .font(DS.Font.body)
          .foregroundStyle(DS.Color.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
        }
      }
    } else {
      BeidPanel {
        VStack(alignment: .leading, spacing: DS.Space.m) {
          Text(recordCountText)
            .font(DS.Font.sectionTitle)
            .foregroundStyle(DS.Color.textPrimary)
          VStack(spacing: DS.Space.s) {
            ForEach(Array(todaysProofs.enumerated()), id: \.element.id) { index, proof in
              Button {
                BeidDesign.haptic()
                coordinator.openProof(proof)
              } label: {
                recordRow(for: proof)
              }
              .buttonStyle(.plain)
              if index < todaysProofs.count - 1 {
                Divider()
              }
            }
          }
        }
      }
    }
  }

  private func recordRow(for proof: Proof) -> some View {
    HStack(alignment: .center, spacing: DS.Space.m) {
      VStack(alignment: .leading, spacing: DS.Space.xs) {
        Text(proof.eventName)
          .font(DS.Font.cardTitle)
          .foregroundStyle(DS.Color.textPrimary)
        Text(Self.timeFormatter.string(from: proof.date))
          .font(DS.Font.meta)
          .foregroundStyle(DS.Color.textSecondary)
      }
      Spacer(minLength: DS.Space.s)
      Image(systemName: "chevron.right")
        .font(DS.Font.meta)
        .foregroundStyle(DS.Color.textSecondary)
        .accessibilityHidden(true)
    }
    .frame(minHeight: DS.Size.minHitTarget)
  }

  /// Submission is never rendered as a count (Phase 1's approved design):
  /// the submission pipeline is code-complete (#258) but globally disabled
  /// by the `BeidReportSubmissionEnabled` build flag
  /// (`BEID_REPORT_SUBMISSION_ENABLED = "NO"`), so a per-day sent/pending
  /// count would not correspond to anything a user could act on. This row
  /// states the pipeline's actual on/off status in words instead — "built,
  /// off," never "not built."
  private var submissionSection: some View {
    BeidPanel {
      VStack(alignment: .leading, spacing: DS.Space.s) {
        Text(
          "Submission",
          comment: "Section header on the Daily Summary screen, above one line describing whether sending proofs to a report server is turned on for this build. Noun, not a verb/CTA."
        )
        .font(DS.Font.cardTitle)
        .foregroundStyle(DS.Color.textPrimary)
        Text(submissionStatusText)
          .font(DS.Font.body)
          .foregroundStyle(DS.Color.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private var submissionStatusText: String {
    if ReportSubmissionRuntime.isSubmissionEnabled() {
      return String(
        localized: "dailySummary.submission.notSentYet",
        defaultValue: "Not sent yet.",
        comment: "Submission status line on the Daily Summary screen, shown only when the BeidReportSubmissionEnabled build flag is on. States plainly that nothing has been transmitted to a report server yet — not a count, not a claim about verification."
      )
    } else {
      return String(
        localized: "dailySummary.submission.disabledForBuild",
        defaultValue: "Sending isn't turned on for this build.",
        comment: "Submission status line on the Daily Summary screen, shown when the BeidReportSubmissionEnabled build flag is off (the default today). Communicates that the sending feature exists but is switched off for this build — \"built, off,\" never \"not built\" — not that anything failed."
      )
    }
  }

  private var dailySummaryTitleText: String {
    String(
      localized: "dailySummary.title",
      defaultValue: "Today",
      comment: "Navigation title of the Daily Summary screen: a day-scoped rollup of proofs collected on the current local calendar day. Refers to the current day, not a to-do list or calendar-app sense of \"Today\"."
    )
  }

  /// Explicit reverse-DNS-ish key (AGENTS.md's localization rule) because
  /// this string has an interpolated plural count.
  private var recordCountText: String {
    String(
      localized: "dailySummary.recordCount",
      defaultValue: "^[\(todaysProofs.count) proofs](inflect: true) collected today",
      comment: "Header above the Daily Summary screen's list of today's proofs: how many proofs (Proof records in ProofStore, not distinct events) were collected on the current local calendar day. Only shown when the day is non-empty — the empty-day state (\"No proofs yet today\") is a separate string."
    )
  }
}

#Preview("Empty") {
  NavigationStack {
    DailySummaryView()
  }
  .environmentObject(AppCoordinator())
}

#Preview("Populated") {
  let coordinator = AppCoordinator()
  coordinator.proofStore.add(Proof(eventName: "ETHGlobal Tokyo", date: Date(), peersVerified: 3))
  coordinator.proofStore.add(Proof(eventName: "beid Meetup", date: Date().addingTimeInterval(-3_600), peersVerified: 1))
  return NavigationStack {
    DailySummaryView()
  }
  .environmentObject(coordinator)
}
