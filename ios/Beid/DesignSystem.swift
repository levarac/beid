// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import SwiftUI
import UIKit

enum BeidDesign {
  enum Spacing {
    static let screenHorizontal: CGFloat = 24
    static let section: CGFloat = 24
    static let content: CGFloat = 14
    static let compact: CGFloat = 8
  }

  enum Radius {
    static let card: CGFloat = 18
    static let control: CGFloat = 14
    static let glyph: CGFloat = 24
  }

  enum Animation {
    static let entrance = DS.Motion.entrance
    static let soft = SwiftUI.Animation.spring(response: 0.36, dampingFraction: 0.88)
  }

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
        BeidGlassGroup(spacing: BeidDesign.Spacing.section) {
          VStack(spacing: BeidDesign.Spacing.section) {
            Spacer(minLength: 20)
            content
            Spacer(minLength: 20)
            footer
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .padding(.horizontal, BeidDesign.Spacing.screenHorizontal)
          .padding(.bottom, 28)
        }
      }
    }
  }
}

struct BeidHeroHeader: View {
  let systemImage: String
  /// Original SVG artwork asset name (DesignSystem/Illustrations.xcassets). Takes
  /// precedence over `systemImage` when set — see DESIGN.md §12 custom-asset policy.
  var assetImage: String?
  let title: LocalizedStringKey
  let subtitle: LocalizedStringKey?
  let tint: Color

  init(
    systemImage: String,
    assetImage: String? = nil,
    title: LocalizedStringKey,
    subtitle: LocalizedStringKey? = nil,
    tint: Color = .accentColor
  ) {
    self.systemImage = systemImage
    self.assetImage = assetImage
    self.title = title
    self.subtitle = subtitle
    self.tint = tint
  }

  var body: some View {
    VStack(spacing: BeidDesign.Spacing.content) {
      BeidGlyph(systemImage: systemImage, assetImage: assetImage, tint: tint)

      VStack(spacing: BeidDesign.Spacing.compact) {
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
    }
    .frame(maxWidth: .infinity)
  }
}

struct BeidGlyph: View {
  let systemImage: String
  /// Original SVG artwork asset name. Takes precedence over `systemImage` when set.
  var assetImage: String?
  let tint: Color
  var size: CGFloat = 72

  var body: some View {
    Group {
      if let assetImage {
        Image(assetImage)
          .resizable()
          .scaledToFit()
          .padding(size * 0.16)
      } else {
        Image(systemName: systemImage)
          .font(.system(size: size * 0.38, weight: .semibold))
          .foregroundStyle(tint)
          .symbolRenderingMode(.hierarchical)
      }
    }
    .frame(width: size, height: size)
    .beidSurface(cornerRadius: BeidDesign.Radius.glyph, fallback: .thinMaterial)
    .accessibilityHidden(true)
  }
}

struct BeidPrimaryButton: View {
  let title: LocalizedStringKey
  let systemImage: String?
  let labelColor: Color
  let action: () -> Void

  init(
    _ title: LocalizedStringKey,
    systemImage: String? = nil,
    labelColor: Color = DS.Color.surfaceCanvas,
    action: @escaping () -> Void
  ) {
    self.title = title
    self.systemImage = systemImage
    self.labelColor = labelColor
    self.action = action
  }

  var body: some View {
    Group {
      if #available(iOS 26.0, *) {
        Button(action: performAction, label: label)
          .buttonStyle(.glassProminent)
      } else {
        Button(action: performAction, label: label)
          .buttonStyle(.borderedProminent)
          .buttonBorderShape(.roundedRectangle(radius: BeidDesign.Radius.control))
      }
    }
    .controlSize(.large)
  }

  private func label() -> some View {
    HStack(spacing: DS.Space.s) {
      if let systemImage {
        Image(systemName: systemImage)
      }
      Text(title)
    }
    .font(DS.Font.cta)
    // Prominent styles default the label to white, which disappears on the
    // light fills this palette uses in dark mode (actionPrimary dark is
    // #E8EAEC → 1.2:1). Label pairing lives in DESIGN.md §5's CTA-label
    // rule: the surfaceCanvas default fits actionPrimary; proofSeal and
    // signalWarning call sites pass labelOnSeal / labelOnWarning; a future
    // signalActive CTA needs its own on-fill token before it exists.
    .foregroundStyle(labelColor)
    .frame(maxWidth: .infinity)
    .frame(minHeight: 52)
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
    if #available(iOS 26.0, *) {
      Button(action: performAction, label: label)
        .buttonStyle(.glass)
    } else {
      Button(action: performAction, label: label)
        .buttonStyle(.bordered)
        .buttonBorderShape(.roundedRectangle(radius: BeidDesign.Radius.control))
    }
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

struct BeidBulletRow: View {
  let systemImage: String
  let title: LocalizedStringKey

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: systemImage)
        .font(.body.weight(.semibold))
        .foregroundStyle(.tint)
        .symbolRenderingMode(.hierarchical)
        .frame(width: 28, height: 28)
        .beidSurface(cornerRadius: BeidDesign.Radius.control, fallback: .thinMaterial)

      Text(title)
        .font(DS.Font.body)
        .foregroundStyle(DS.Color.textPrimary)

      Spacer(minLength: 0)
    }
  }
}

struct BeidStatusPill: View {
  enum State {
    case sensingAutomatically
    case sensingPaused

    fileprivate var label: LocalizedStringKey {
      switch self {
      case .sensingAutomatically: "Sensing automatically"
      case .sensingPaused: "Sensing paused"
      }
    }

    fileprivate var dotColor: Color {
      switch self {
      case .sensingAutomatically: DS.Color.signalActive
      case .sensingPaused: DS.Color.signalWarning
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

struct BeidPanel<Content: View>: View {
  let content: Content

  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  var body: some View {
    content
      .padding(18)
      .frame(maxWidth: .infinity, alignment: .leading)
      .beidSurface(cornerRadius: BeidDesign.Radius.card)
  }
}

struct BeidStatusLayout<Accessory: View, Footer: View>: View {
  let systemImage: String
  /// Original SVG artwork asset name. Takes precedence over `systemImage` when set.
  var assetImage: String?
  let title: LocalizedStringKey
  let message: LocalizedStringKey
  let tint: Color
  let accessory: Accessory
  let footer: Footer

  init(
    systemImage: String,
    assetImage: String? = nil,
    title: LocalizedStringKey,
    message: LocalizedStringKey,
    tint: Color = .accentColor,
    @ViewBuilder accessory: () -> Accessory = { EmptyView() },
    @ViewBuilder footer: () -> Footer = { EmptyView() }
  ) {
    self.systemImage = systemImage
    self.assetImage = assetImage
    self.title = title
    self.message = message
    self.tint = tint
    self.accessory = accessory()
    self.footer = footer()
  }

  var body: some View {
    BeidScreen {
      VStack(spacing: BeidDesign.Spacing.section) {
        BeidHeroHeader(systemImage: systemImage, assetImage: assetImage, title: title, subtitle: message, tint: tint)
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

/// Groups nearby Liquid Glass surfaces so iOS 26 can blend and morph them
/// as one material instead of compositing each independently — see
/// DESIGN.md §8 "Materials". Below iOS 26 there is no glass to group, so
/// this is a plain passthrough. Wrap any cluster of `beidSurface`-backed
/// views that sit visually close together on one screen (a glyph, a panel,
/// a footer button); do not wrap views that are far apart or on different
/// screens — that defeats the container's purpose.
struct BeidGlassGroup<Content: View>: View {
  var spacing: CGFloat = BeidDesign.Spacing.content
  @ViewBuilder let content: () -> Content

  var body: some View {
    if #available(iOS 26.0, *) {
      GlassEffectContainer(spacing: spacing) {
        content()
      }
    } else {
      content()
    }
  }
}

extension View {
  /// The one sanctioned way to give a view a physical surface: Liquid
  /// Glass on iOS 26+, a system material + hairline stroke below it. This
  /// modifier owns the entire surface fill — MUST NOT be paired with a
  /// separate `.background(material:)`/`.background(color:)` call, which
  /// would stack a second material or color directly underneath the glass
  /// (DESIGN.md §8: no glass-on-glass nesting).
  @ViewBuilder
  func beidSurface(
    interactive: Bool = false,
    cornerRadius: CGFloat,
    fallback: Material = .regularMaterial
  ) -> some View {
    if #available(iOS 26.0, *) {
      self.glassEffect(
        interactive ? .regular.interactive() : .regular,
        in: .rect(cornerRadius: cornerRadius)
      )
    } else {
      self
        .background(fallback, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
          RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(DS.Color.strokeHairline, lineWidth: 1)
        }
    }
  }
}
