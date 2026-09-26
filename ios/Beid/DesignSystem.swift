// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import SwiftUI
import UIKit

enum BeidDesign {
  // Design values live in `DS` (DesignSystem/Tokens.swift); this keeps only UIKit feedback behavior.
  static func haptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .light) {
    UIImpactFeedbackGenerator(style: style).impactOccurred()
  }
}

struct BeidScreen<Content: View, Footer: View>: View {
  let content: Content
  let footer: Footer

  init(
    @ViewBuilder content: () -> Content,
    @ViewBuilder footer: () -> Footer = { EmptyView() }
  ) {
    self.content = content()
    self.footer = footer()
  }

  var body: some View {
    ZStack {
      DS.Color.surfaceCanvas
        .ignoresSafeArea()

      BeidAdaptiveContent {
        VStack(spacing: DS.Space.l) {
          Spacer(minLength: 20)
          content
          Spacer(minLength: 20)
          footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, DS.Space.pageMargin)
        .padding(.bottom, 28)
      }
    }
  }
}

struct BeidHeroHeader: View {
  let title: LocalizedStringKey
  let subtitle: LocalizedStringKey?

  init(
    title: LocalizedStringKey,
    subtitle: LocalizedStringKey? = nil
  ) {
    self.title = title
    self.subtitle = subtitle
  }

  var body: some View {
    VStack(spacing: DS.Space.s) {
      Text(title)
        .font(DS.Font.screenTitle)
        .multilineTextAlignment(.center)
        .lineLimit(2)
        .minimumScaleFactor(0.82)

      if let subtitle {
        Text(subtitle)
          .font(DS.Font.body)
          .foregroundStyle(DS.Color.textSecondary)
          .multilineTextAlignment(.center)
          .lineSpacing(2)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .frame(maxWidth: .infinity)
  }
}

struct BeidPrimaryButton: View {
  let title: LocalizedStringKey
  let labelColor: Color
  let action: () -> Void

  init(
    _ title: LocalizedStringKey,
    labelColor: Color = DS.Color.labelOnActionPrimary,
    action: @escaping () -> Void
  ) {
    self.title = title
    self.labelColor = labelColor
    self.action = action
  }

  var body: some View {
    Button(action: performAction, label: label)
      .buttonStyle(.plain)
  }

  private func label() -> some View {
    Text(title)
      .font(DS.Font.cta)
      // DESIGN.md §5 pairs the actionPrimary fill with its on-fill label.
      // Keep the existing labelColor override for callers that supply one.
      .foregroundStyle(labelColor)
      .frame(maxWidth: .infinity)
      .frame(minHeight: DS.Size.primaryButtonMinHeight)
      .background(DS.Color.actionPrimary, in: Capsule())
      .contentShape(Capsule())
  }

  private func performAction() {
    BeidDesign.haptic()
    action()
  }
}

struct BeidSecondaryButton: View {
  let title: LocalizedStringKey
  let action: () -> Void

  var body: some View {
    Button(action: performAction, label: label)
      .buttonStyle(.bordered)
      .buttonBorderShape(.roundedRectangle(radius: DS.Radius.control))
  }

  private func label() -> some View {
    Text(title)
      .font(DS.Font.cardTitle)
      .frame(maxWidth: .infinity, minHeight: 44)
  }

  private func performAction() {
    BeidDesign.haptic(.soft)
    action()
  }
}

/// One benefit/permission bullet: a title and optionally a second, smaller
/// supporting sentence (screen 02's three Bluetooth benefits — DESIGN.md §10).
/// Omit `subtitle` for a title-only row.
struct BeidBulletRow: View {
  let title: LocalizedStringKey
  var subtitle: LocalizedStringKey?

  var body: some View {
    HStack(alignment: subtitle == nil ? .center : .top, spacing: DS.Space.s) {
      VStack(alignment: .leading, spacing: DS.Space.xs) {
        Text(title)
          .font(DS.Font.cardTitle)
          .foregroundStyle(DS.Color.textPrimary)

        if let subtitle {
          Text(subtitle)
            .font(DS.Font.meta)
            .foregroundStyle(DS.Color.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }

      Spacer(minLength: 0)
    }
  }
}

struct BeidStatusPill: View {
  enum State {
    case sensingAutomatically
    case sensingPaused
    /// `EventBindingSheetView`'s connect+binding sheet: sensing is active
    /// and running underneath while the sheet is up (never paused by it —
    /// see that view's `sensingLiveIndicator`).
    case sensingNearby

    fileprivate var label: LocalizedStringKey {
      switch self {
      case .sensingAutomatically: "Sensing automatically"
      case .sensingPaused: "Sensing paused"
      case .sensingNearby: "Sensing nearby"
      }
    }

    fileprivate var dotColor: Color {
      switch self {
      case .sensingAutomatically, .sensingNearby: DS.Color.statusOn
      case .sensingPaused: DS.Color.statusPending
      }
    }
  }

  let state: State

  var body: some View {
    HStack(spacing: DS.Space.s) {
      Circle()
        .fill(state.dotColor)
        .frame(width: DS.Size.statusDot, height: DS.Size.statusDot)
        .accessibilityHidden(true)

      Text(state.label)
        .font(DS.Font.supporting)
        .foregroundStyle(DS.Color.textSecondary)
    }
    .padding(.horizontal, DS.Space.m)
    .padding(.vertical, DS.Space.s)
    .beidSurface(cornerRadius: DS.Radius.pill)
  }
}

/// Sequential numbered instructions in a bordered card — one filled index
/// badge + one line per step (screen 03's "Open Settings / Tap Bluetooth /
/// Switch it on" — DESIGN.md §10). The badge fill follows the ambient
/// `.tint()` (so it picks up whichever fill the hosting screen sets, e.g.
/// `actionPrimary` on a recovery screen); `labelColor` must be the on-fill
/// pairing token for that same tint (see DESIGN.md §5's CTA-label rule —
/// the same pairing applies to any text sitting on a tint fill).
struct BeidNumberedStepList: View {
  let steps: [LocalizedStringKey]
  var labelColor: Color = DS.Color.labelOnActionPrimary

  var body: some View {
    VStack(spacing: 0) {
      ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
        HStack(spacing: DS.Space.m) {
          Text("\(index + 1)")
            .font(DS.Font.meta.weight(.semibold))
            .foregroundStyle(labelColor)
            .frame(width: DS.Size.stepBadge, height: DS.Size.stepBadge)
            .background(.tint, in: Circle())

          Text(step)
            .font(DS.Font.body)
            .foregroundStyle(DS.Color.textPrimary)

          Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Space.m)
        .padding(.vertical, DS.Space.s)
        .accessibilityElement(children: .combine)

        if index < steps.count - 1 {
          Divider()
            .padding(.leading, DS.Space.m + DS.Size.stepBadge + DS.Space.m)
        }
      }
    }
    .padding(.vertical, DS.Space.xs)
    .beidSurface(cornerRadius: DS.Radius.card)
  }
}

struct BeidPanel<Content: View>: View {
  let content: Content

  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  var body: some View {
    content
      .padding(18)
      .frame(maxWidth: .infinity, alignment: .leading)
      .beidSurface(cornerRadius: DS.Radius.card)
  }
}

struct BeidStatusLayout<Accessory: View, Footer: View>: View {
  let title: LocalizedStringKey
  let message: LocalizedStringKey
  let accessory: Accessory
  let footer: Footer

  init(
    title: LocalizedStringKey,
    message: LocalizedStringKey,
    @ViewBuilder accessory: () -> Accessory = { EmptyView() },
    @ViewBuilder footer: () -> Footer = { EmptyView() }
  ) {
    self.title = title
    self.message = message
    self.accessory = accessory()
    self.footer = footer()
  }

  var body: some View {
    BeidScreen {
      VStack(spacing: DS.Space.l) {
        BeidHeroHeader(title: title, subtitle: message)
        accessory
      }
    } footer: {
      footer
    }
  }
}

struct BeidMetricRow: View {
  let label: LocalizedStringKey
  let value: Text
  let valueStyle: AnyShapeStyle

  init(
    label: LocalizedStringKey,
    value: LocalizedStringKey,
    valueStyle: AnyShapeStyle = AnyShapeStyle(.primary)
  ) {
    self.label = label
    self.value = Text(value)
    self.valueStyle = valueStyle
  }

  init(
    label: LocalizedStringKey,
    verbatimValue: String,
    valueStyle: AnyShapeStyle = AnyShapeStyle(.primary)
  ) {
    self.label = label
    self.value = Text(verbatim: verbatimValue)
    self.valueStyle = valueStyle
  }

  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      Text(label)
        .font(DS.Font.supporting)
        .foregroundStyle(DS.Color.textSecondary)
      Spacer(minLength: DS.Space.m)
      value
        .font(DS.Font.cardTitle)
        .foregroundStyle(valueStyle)
        .multilineTextAlignment(.trailing)
    }
  }
}

/// The empty state's dashed 1 pt frame — the repository home of the Figma
/// Library component `Block/Empty` (file xf2uFHceIYg0h0gJndUkmI, node
/// 190:53; DESIGN.md §8): a `line-dashed` inside stroke with a 4/4 dash,
/// radius 16, 24 pt horizontal and 40 pt vertical padding, no fill, content
/// centered. This is the frame only: the block's 10 pt title/body gap and its
/// mono title belong to the content the caller passes in (#635).
struct BeidEmptyBlock<Content: View>: View {
  let content: Content

  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  var body: some View {
    content
      .padding(.horizontal, DS.Space.l)
      .padding(.vertical, DS.Space.emptyBlockVertical)
      .frame(maxWidth: .infinity)
      .overlay {
        RoundedRectangle(cornerRadius: DS.Radius.emptyBlock, style: .continuous)
          .strokeBorder(
            DS.Color.strokeEmptyState,
            style: StrokeStyle(lineWidth: DS.Size.hairline, dash: [DS.Size.emptyBlockDash, DS.Size.emptyBlockDash])
          )
      }
  }
}

extension ToolbarContent {
  /// Removes the iOS 26 per-item glass from explicit toolbar content.
  /// #630 removed branches that ADDED iOS 26 glass and made versions differ;
  /// the owner approved this #631 branch because it REMOVES glass that exists
  /// only on iOS 26, keeping explicit items consistent across OS versions.
  /// The system-created navigation back item remains OS-owned.
  @ToolbarContentBuilder
  func beidWithoutSharedBackground() -> some ToolbarContent {
    if #available(iOS 26, *) {
      self.sharedBackgroundVisibility(.hidden)
    } else {
      self
    }
  }
}

extension View {
  /// The one sanctioned way to give a view a surface under Flat 2b: the
  /// `bg` fill plus a 1 pt `line` hairline border (DESIGN.md §8 — no glass,
  /// no materials, no blur). This modifier owns the entire surface fill —
  /// MUST NOT be paired with a separate `.background(...)` call, which would
  /// stack a second fill directly underneath it.
  func beidSurface(cornerRadius: CGFloat) -> some View {
    self
      .background(DS.Color.surfaceCanvas, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .strokeBorder(DS.Color.strokeHairline, lineWidth: DS.Size.hairline)
      }
  }

  /// The opaque bar behind a bottom `safeAreaInset` under Flat 2b: the `bg`
  /// fill, reaching under the home indicator like the system bar style did,
  /// with a 1 pt `line` rule on its top edge (DESIGN.md §8: hairlines sit on
  /// the top edge).
  func beidBottomBar() -> some View {
    self
      .background(DS.Color.surfaceCanvas)
      .overlay(alignment: .top) {
        Rectangle()
          .fill(DS.Color.strokeHairline)
          .frame(height: DS.Size.hairline)
      }
  }
}
