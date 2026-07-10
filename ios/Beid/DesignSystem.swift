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
    static let entrance = SwiftUI.Animation.spring(response: 0.48, dampingFraction: 0.84)
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
      Color(.systemGroupedBackground)
        .ignoresSafeArea()

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

struct BeidHeroHeader: View {
  let systemImage: String
  let title: String
  let subtitle: String?
  let tint: Color

  init(systemImage: String, title: String, subtitle: String? = nil, tint: Color = .accentColor) {
    self.systemImage = systemImage
    self.title = title
    self.subtitle = subtitle
    self.tint = tint
  }

  var body: some View {
    VStack(spacing: BeidDesign.Spacing.content) {
      BeidGlyph(systemImage: systemImage, tint: tint)

      VStack(spacing: BeidDesign.Spacing.compact) {
        Text(title)
          .font(.largeTitle.weight(.semibold))
          .multilineTextAlignment(.center)
          .lineLimit(2)
          .minimumScaleFactor(0.82)

        if let subtitle {
          Text(subtitle)
            .font(.body)
            .foregroundStyle(.secondary)
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
  let tint: Color
  var size: CGFloat = 72

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: BeidDesign.Radius.glyph, style: .continuous)
        .fill(.thinMaterial)
        .overlay {
          RoundedRectangle(cornerRadius: BeidDesign.Radius.glyph, style: .continuous)
            .strokeBorder(.separator.opacity(0.35), lineWidth: 1)
        }

      Image(systemName: systemImage)
        .font(.system(size: size * 0.38, weight: .semibold))
        .foregroundStyle(tint)
        .symbolRenderingMode(.hierarchical)
    }
    .frame(width: size, height: size)
    .beidGlass(interactive: false, cornerRadius: BeidDesign.Radius.glyph)
    .accessibilityHidden(true)
  }
}

struct BeidPrimaryButton: View {
  let title: String
  let systemImage: String?
  let action: () -> Void

  init(_ title: String, systemImage: String? = nil, action: @escaping () -> Void) {
    self.title = title
    self.systemImage = systemImage
    self.action = action
  }

  var body: some View {
    Button(action: performAction) {
      HStack(spacing: 8) {
        if let systemImage {
          Image(systemName: systemImage)
        }
        Text(title)
      }
      .font(.headline)
      .frame(maxWidth: .infinity)
      .frame(minHeight: 52)
    }
    .buttonStyle(.borderedProminent)
    .buttonBorderShape(.roundedRectangle(radius: BeidDesign.Radius.control))
    .controlSize(.large)
  }

  private func performAction() {
    BeidDesign.haptic()
    action()
  }
}

struct BeidSecondaryButton: View {
  let title: String
  let action: () -> Void

  var body: some View {
    Button(action: performAction) {
      Text(title)
        .font(.subheadline.weight(.semibold))
        .frame(maxWidth: .infinity, minHeight: 44)
    }
    .buttonStyle(.bordered)
    .buttonBorderShape(.roundedRectangle(radius: BeidDesign.Radius.control))
  }

  private func performAction() {
    BeidDesign.haptic(.soft)
    action()
  }
}

struct BeidBulletRow: View {
  let systemImage: String
  let title: String

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: systemImage)
        .font(.body.weight(.semibold))
        .foregroundStyle(.tint)
        .symbolRenderingMode(.hierarchical)
        .frame(width: 28, height: 28)
        .background(.thinMaterial, in: Circle())

      Text(title)
        .font(.body)
        .foregroundStyle(.primary)

      Spacer(minLength: 0)
    }
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
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: BeidDesign.Radius.card, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: BeidDesign.Radius.card, style: .continuous)
          .strokeBorder(.separator.opacity(0.32), lineWidth: 1)
      }
      .beidGlass(interactive: false, cornerRadius: BeidDesign.Radius.card)
  }
}

struct BeidStatusLayout<Accessory: View, Footer: View>: View {
  let systemImage: String
  let title: String
  let message: String
  let tint: Color
  let accessory: Accessory
  let footer: Footer

  init(
    systemImage: String,
    title: String,
    message: String,
    tint: Color = .accentColor,
    @ViewBuilder accessory: () -> Accessory = { EmptyView() },
    @ViewBuilder footer: () -> Footer = { EmptyView() }
  ) {
    self.systemImage = systemImage
    self.title = title
    self.message = message
    self.tint = tint
    self.accessory = accessory()
    self.footer = footer()
  }

  var body: some View {
    BeidScreen {
      VStack(spacing: BeidDesign.Spacing.section) {
        BeidHeroHeader(systemImage: systemImage, title: title, subtitle: message, tint: tint)
        accessory
      }
    } footer: {
      footer
    }
  }
}

struct BeidMetricRow: View {
  let label: String
  let value: String
  var valueStyle: AnyShapeStyle = AnyShapeStyle(.primary)

  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      Text(label)
        .font(.subheadline)
        .foregroundStyle(.secondary)
      Spacer(minLength: 16)
      Text(value)
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(valueStyle)
        .multilineTextAlignment(.trailing)
    }
  }
}

extension View {
  @ViewBuilder
  func beidGlass(interactive: Bool, cornerRadius: CGFloat) -> some View {
    if #available(iOS 26.0, *) {
      if interactive {
        self.glassEffect(.regular.interactive(), in: .rect(cornerRadius: cornerRadius))
      } else {
        self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
      }
    } else {
      self
    }
  }
}
