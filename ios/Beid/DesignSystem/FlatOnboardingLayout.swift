// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import SwiftUI

/// Shared layout for the three Flat 2b onboarding frames. The content starts
/// at the export's 72 pt eyebrow anchor on a 402 pt screen. A scroll view
/// keeps enlarged text reachable while the primary action stays at the foot.
struct FlatOnboardingPage<Content: View, Footer: View>: View {
  let content: Content
  let footer: Footer

  init(
    @ViewBuilder content: () -> Content,
    @ViewBuilder footer: () -> Footer
  ) {
    self.content = content()
    self.footer = footer()
  }

  var body: some View {
    GeometryReader { geometry in
      ZStack {
        DS.Color.surfaceCanvas.ignoresSafeArea()

        BeidAdaptiveContent {
          VStack(spacing: 0) {
            ScrollView {
              content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, max(0, DS.Onboarding.eyebrowY - geometry.safeAreaInsets.top))
                .padding(.horizontal, DS.Space.pageMargin)
                .padding(.bottom, DS.Space.l)
            }
            .scrollIndicators(.hidden)

            footer
              .padding(.horizontal, DS.Space.pageMargin)
              .padding(.bottom, DS.Onboarding.footerBottom)
          }
        }
      }
    }
  }
}

/// The Figma Button/Primary large shape, scoped to these three frames while
/// the repository-wide button migration remains separate. It retains the
/// current DM Sans sentence-case control copy decided for this issue.
struct FlatOnboardingPrimaryButton: View {
  let title: LocalizedStringKey
  let action: () -> Void

  init(_ title: LocalizedStringKey, action: @escaping () -> Void) {
    self.title = title
    self.action = action
  }

  var body: some View {
    Button {
      BeidDesign.haptic()
      action()
    } label: {
      Text(title)
        .beidTextStyle(DS.Font.Library.title16)
        .foregroundStyle(DS.Color.labelOnActionPrimary)
        .frame(maxWidth: .infinity, minHeight: DS.Size.primaryButtonMinHeight)
        .background(DS.Color.actionPrimary, in: Capsule())
        .contentShape(Capsule())
    }
    .buttonStyle(.plain)
  }
}

/// Figma's hairline-separated numbered instructions. The same row anatomy
/// handles the permission benefits and Bluetooth-off recovery steps.
struct FlatOnboardingSteps: View {
  struct Step {
    let title: LocalizedStringKey
    let detail: LocalizedStringKey?

    init(_ title: LocalizedStringKey, detail: LocalizedStringKey? = nil) {
      self.title = title
      self.detail = detail
    }
  }

  let steps: [Step]

  var body: some View {
    VStack(spacing: 0) {
      ForEach(steps.indices, id: \.self) { index in
        Rectangle()
          .fill(DS.Color.strokeHairline)
          .frame(height: DS.Size.hairline)

        HStack(alignment: .top, spacing: 0) {
          Text(verbatim: String(format: "%02d", index + 1))
            .beidTextStyle(DS.Font.Library.labelMono11)
            .foregroundStyle(DS.Color.textPrimary)
            .padding(.top, DS.Space.xs)
            .frame(width: DS.Onboarding.rowNumberWidth, alignment: .leading)

          VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text(steps[index].title)
              .beidTextStyle(DS.Font.Library.title17)
              .foregroundStyle(DS.Color.textPrimary)

            if let detail = steps[index].detail {
              Text(detail)
                .beidTextStyle(DS.Font.Library.body13)
                .foregroundStyle(DS.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, steps[index].detail == nil
          ? DS.Onboarding.recoveryRowTop : DS.Onboarding.benefitRowTop)
        .frame(
          minHeight: steps[index].detail == nil
            ? DS.Onboarding.recoveryRowHeight - DS.Size.hairline
            : DS.Onboarding.benefitRowHeight - DS.Size.hairline,
          alignment: .top
        )
        .accessibilityElement(children: .combine)
      }

      Rectangle()
        .fill(DS.Color.strokeHairline)
        .frame(height: DS.Size.hairline)
    }
  }
}
