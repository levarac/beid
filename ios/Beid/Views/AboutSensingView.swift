// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import SwiftUI

/// Flat 2b frame 15. This destination is shared by the Account route and
/// the pending Welcome, Home, and first-time sensing routes.
struct AboutSensingView: View {
  var body: some View {
    ScrollView {
      BeidAdaptiveContent {
        VStack(alignment: .leading, spacing: 0) {
          Text("About\nsensing")
            .beidTextStyle(DS.Font.Library.display52)
            .foregroundStyle(DS.Color.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)

          SensingExplainerSectionLabel("HOW IT WORKS")
            .padding(.top, DS.Space.l)
          SensingExplainerRule()

          SensingExplainerStep(
            number: "01",
            title: "Events find you",
            detail: "Nearby events appear automatically — no codes, no search."
          )
          SensingExplainerRule()
          SensingExplainerStep(
            number: "02",
            title: "Private by design",
            detail: "Phones exchange rotating anonymous IDs, not names or wallet addresses."
          )
          SensingExplainerRule()
          SensingExplainerStep(
            number: "03",
            title: "Zero effort",
            detail: "Sensing runs quietly in the background. Nothing to tap."
          )
          SensingExplainerRule()

          NavigationLink {
            WhatWeSendView()
          } label: {
            HStack {
              Text("What we send")
                .beidTextStyle(DS.Font.Library.title17)
              Spacer()
              Text(verbatim: "→")
                .beidTextStyle(DS.Font.Library.labelMono11)
                .accessibilityHidden(true)
            }
            .foregroundStyle(DS.Color.textPrimary)
            .frame(minHeight: DS.Space.xxl + DS.Space.m + DS.Space.xs)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityIdentifier("aboutSensing.whatWeSend")
          SensingExplainerRule()

          SensingExplainerSectionLabel("SENDING STATUS · ALL SAVED OBSERVATIONS")
            .padding(.top, DS.Space.xl)
          SensingExplainerRule()
          VStack(alignment: .leading, spacing: DS.Space.s) {
            Text("SENDING")
              .beidTextStyle(DS.Font.Library.labelMono10)
              .foregroundStyle(DS.Color.textSecondary)
            Text(sendingStatus)
              .beidTextStyle(DS.Font.Library.body13)
              .foregroundStyle(DS.Color.textPrimary)
              .fixedSize(horizontal: false, vertical: true)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.vertical, DS.Space.m)
          .accessibilityElement(children: .combine)
          SensingExplainerRule()
        }
        .padding(.horizontal, DS.Space.pageMargin)
        .padding(.bottom, DS.Space.xxl)
      }
    }
    .accessibilityIdentifier("aboutSensing.scroll")
    .background(DS.Color.surfaceCanvas)
    .navigationTitle("")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar(.visible, for: .navigationBar)
  }

  private var sendingStatus: String {
    if ReportSubmissionRuntime.isSubmissionEnabled() {
      return String(localized: "aboutSensing.submission.enabled", defaultValue: "Sending is turned on for this build.")
    }
    return String(localized: "dailySummary.submission.disabledForBuild")
  }
}

/// Flat 2b frame 16. The final Figma line is a designer instruction and is
/// intentionally absent from the production screen.
struct WhatWeSendView: View {
  var body: some View {
    ScrollView {
      BeidAdaptiveContent {
        VStack(alignment: .leading, spacing: 0) {
          Text("What\nwe send")
            .beidTextStyle(DS.Font.Library.display52)
            .foregroundStyle(DS.Color.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)

          SensingExplainerSectionLabel("WHAT WE SEND")
            .padding(.top, DS.Space.l)
          SensingExplainerRule()
          SensingExplainerDetail(
            title: "The event you joined",
            detail: "The event’s identifier, so the organiser knows which event this belongs to.",
            identifier: "whatWeSend.firstRow"
          )
          SensingExplainerRule()
          SensingExplainerDetail(
            title: "The time window",
            detail: "Which five-minute stretch of the event this record covers, not the moment you arrived or left."
          )
          SensingExplainerRule()
          SensingExplainerDetail(
            title: "The anonymous IDs of the phones near you",
            detail: "Each phone announces an ID that changes on its own schedule. It is not a name, an account, or a device serial."
          )
          SensingExplainerRule()
          SensingExplainerDetail(
            title: "Your own anonymous ID for that window",
            detail: "The same kind of rotating ID, so the phones around you can be matched with this record."
          )
          SensingExplainerRule()
          SensingExplainerDetail(
            title: "A commitment for this event",
            detail: "A value derived from keys for this event. It can support a later ownership check without including your wallet address."
          )
          SensingExplainerRule()
          SensingExplainerDetail(
            title: "A signature from this phone",
            detail: "It proves the record was not changed after this phone made it."
          )
          SensingExplainerRule()

          SensingExplainerSectionLabel("WHAT WE DON’T SEND")
            .padding(.top, DS.Space.l + DS.Space.xs)
          SensingExplainerRule()
          SensingExplainerDetail(
            title: "Your location",
            detail: "beid never reads GPS, and no position is recorded or sent."
          )
          SensingExplainerRule()
          SensingExplainerDetail(
            title: "Your name, your account, or your wallet address",
            detail: "None of them are part of a record."
          )
          SensingExplainerRule()
          if ReportSubmissionRuntime.isSubmissionEnabled() {
            SensingExplainerDetail(
              title: "Anything you have not recorded",
              detail: "Saved observations are sent to the event operator.",
              identifier: "whatWeSend.finalRow"
            )
          } else {
            SensingExplainerDetail(
              title: "Anything you have not recorded",
              detail: "Records stay on this phone until sending is turned on for this build.",
              identifier: "whatWeSend.finalRow"
            )
          }
          SensingExplainerRule()
        }
        .padding(.horizontal, DS.Space.pageMargin)
        .padding(.bottom, DS.Space.xxl)
      }
    }
    .accessibilityIdentifier("whatWeSend.scroll")
    .background(DS.Color.surfaceCanvas)
    .navigationTitle("")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar(.visible, for: .navigationBar)
  }
}

private struct SensingExplainerSectionLabel: View {
  let text: LocalizedStringKey

  init(_ text: LocalizedStringKey) {
    self.text = text
  }

  var body: some View {
    Text(text)
      .beidTextStyle(DS.Font.Library.labelMono10)
      .foregroundStyle(DS.Color.textSecondary)
      .fixedSize(horizontal: false, vertical: true)
      .padding(.bottom, DS.Space.s + DS.Space.xs)
      .accessibilityAddTraits(.isHeader)
  }
}

private struct SensingExplainerRule: View {
  var body: some View {
    DS.Color.strokeHairline
      .frame(height: DS.Size.hairline)
      .accessibilityHidden(true)
  }
}

private struct SensingExplainerStep: View {
  let number: String
  let title: LocalizedStringKey
  let detail: LocalizedStringKey

  var body: some View {
    HStack(alignment: .top, spacing: DS.Space.xl) {
      Text(verbatim: number)
        .beidTextStyle(DS.Font.Library.labelMono11)
        .foregroundStyle(DS.Color.textPrimary)
        .frame(width: DS.Space.m, alignment: .leading)
      VStack(alignment: .leading, spacing: DS.Space.xs) {
        Text(title)
          .beidTextStyle(DS.Font.Library.title15)
          .foregroundStyle(DS.Color.textPrimary)
        Text(detail)
          .beidTextStyle(DS.Font.Library.body13)
          .foregroundStyle(DS.Color.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.top, DS.Space.s + DS.Space.xs)
    .padding(.bottom, DS.Space.xs)
    .accessibilityElement(children: .combine)
  }
}

private struct SensingExplainerDetail: View {
  let title: LocalizedStringKey
  let detail: LocalizedStringKey
  let identifier: String?

  init(title: LocalizedStringKey, detail: LocalizedStringKey, identifier: String? = nil) {
    self.title = title
    self.detail = detail
    self.identifier = identifier
  }

  var body: some View {
    VStack(alignment: .leading, spacing: DS.Space.xs) {
      Text(title)
        .beidTextStyle(DS.Font.Library.title15)
        .foregroundStyle(DS.Color.textPrimary)
      Text(detail)
        .beidTextStyle(DS.Font.Library.body13)
        .foregroundStyle(DS.Color.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.top, DS.Space.s + DS.Space.xs)
    .padding(.bottom, DS.Space.xs)
    .frame(minHeight: DS.Size.listRowMinHeight - DS.Space.m, alignment: .topLeading)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier(identifier ?? "")
  }
}

#Preview("About sensing") {
  NavigationStack { AboutSensingView() }
}

#Preview("What we send") {
  NavigationStack { WhatWeSendView() }
}
