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
  /// Fill and label pairing. `.inverse` is for ink grounds (DESIGN.md §5).
  enum Tone {
    case primary
    case inverse
  }

  let title: LocalizedStringKey
  let labelColor: Color
  let tone: Tone
  let hapticStyle: UIImpactFeedbackGenerator.FeedbackStyle
  let role: ButtonRole?
  let action: () -> Void

  init(
    _ title: LocalizedStringKey,
    tone: Tone = .primary,
    labelColor: Color? = nil,
    haptic: UIImpactFeedbackGenerator.FeedbackStyle = .light,
    role: ButtonRole? = nil,
    action: @escaping () -> Void
  ) {
    self.title = title
    self.tone = tone
    self.labelColor = labelColor ?? (tone == .inverse ? DS.Color.labelOnActionInverse : DS.Color.labelOnActionPrimary)
    self.hapticStyle = haptic
    self.role = role
    self.action = action
  }

  var body: some View {
    Button(role: role, action: performAction, label: label)
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
      .background(tone == .inverse ? DS.Color.actionInverse : DS.Color.actionPrimary, in: Capsule())
      .contentShape(Capsule())
  }

  private func performAction() {
    BeidDesign.haptic(hapticStyle)
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
      .frame(maxWidth: .infinity, minHeight: DS.Size.minHitTarget)
  }

  private func performAction() {
    BeidDesign.haptic(.soft)
    action()
  }
}

struct BeidStatusPill: View {
  enum State {
    case sensingPaused

    fileprivate var label: LocalizedStringKey {
      switch self {
      case .sensingPaused: "Sensing paused"
      }
    }

    fileprivate var dotColor: Color {
      switch self {
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
/// centered. Screen-level empty states use BeidEmptyState below.
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

/// Shared empty-content layout. Copy is passed as `LocalizedStringKey`; call
/// sites that hold prebuilt `Text` (runtime values, translator comments) use the
/// `text:` initializers. Identifiers stay on the individual accessible text elements.
struct BeidEmptyState<Actions: View>: View {
  let title: Text
  let description: Text?
  let symbol: String?
  let titleIdentifier: String
  let descriptionIdentifier: String
  let actions: Actions

  init(
    text title: Text, description: Text? = nil, symbol: String? = nil,
    titleIdentifier: String = "", descriptionIdentifier: String = "",
    @ViewBuilder actions: () -> Actions
  ) {
    self.title = title
    self.description = description
    self.symbol = symbol
    self.titleIdentifier = titleIdentifier
    self.descriptionIdentifier = descriptionIdentifier
    self.actions = actions()
  }

  init(
    _ title: LocalizedStringKey, description: LocalizedStringKey? = nil, symbol: String? = nil,
    titleIdentifier: String = "", descriptionIdentifier: String = "",
    @ViewBuilder actions: () -> Actions
  ) {
    self.init(
      text: Text(title), description: description.map { Text($0) }, symbol: symbol,
      titleIdentifier: titleIdentifier, descriptionIdentifier: descriptionIdentifier,
      actions: actions
    )
  }

  var body: some View {
    BeidEmptyBlock {
      VStack(spacing: DS.Space.m) {
        if let symbol {
          Image(systemName: symbol)
            .font(DS.Font.cardTitle)
            .dynamicTypeSize(.large)
            .foregroundStyle(DS.Color.textSecondary)
            .accessibilityHidden(true)
        }
        title
          .beidTextStyle(DS.Font.Library.title17)
          .foregroundStyle(DS.Color.textPrimary)
          .accessibilityIdentifier(titleIdentifier)
        if let description {
          description
            .beidTextStyle(DS.Font.Library.body13)
            .foregroundStyle(DS.Color.textSecondary)
            .accessibilityIdentifier(descriptionIdentifier)
        }
        actions
      }
      .multilineTextAlignment(.center)
      .fixedSize(horizontal: false, vertical: true)
    }
  }
}

extension BeidEmptyState where Actions == EmptyView {
  init(
    text title: Text, description: Text? = nil, symbol: String? = nil,
    titleIdentifier: String = "", descriptionIdentifier: String = ""
  ) {
    self.init(
      text: title, description: description, symbol: symbol,
      titleIdentifier: titleIdentifier, descriptionIdentifier: descriptionIdentifier
    ) { EmptyView() }
  }

  init(
    _ title: LocalizedStringKey, description: LocalizedStringKey? = nil, symbol: String? = nil,
    titleIdentifier: String = "", descriptionIdentifier: String = ""
  ) {
    self.init(
      text: Text(title), description: description.map { Text($0) }, symbol: symbol,
      titleIdentifier: titleIdentifier, descriptionIdentifier: descriptionIdentifier
    )
  }
}

extension ToolbarContent {
  /// Being removed under #730 (the OS's bar glass stays); no new call may be added.
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
  /// A screen's state color also owns the backing exposed by native transitions.
  /// This does not change the app's single Light appearance (DESIGN.md §14).
  func beidScreenBackground(_ color: Color, updatesBacking: Bool = true) -> some View {
    modifier(BeidScreenBackground(color: color, updatesBacking: updatesBacking))
  }

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

private struct BeidScreenBackground: ViewModifier {
  let color: Color
  let updatesBacking: Bool

  func body(content: Content) -> some View {
    navigationBackground(content)
      .background(color.ignoresSafeArea())
      .background {
        if updatesBacking {
          BeidBackingView(color: UIColor(color)).frame(width: 0, height: 0)
        }
      }
  }

  @ViewBuilder private func navigationBackground(_ content: Content) -> some View {
    if #available(iOS 18, *) {
      content.containerBackground(color, for: .navigation)
    } else {
      content
    }
  }
}

private struct BeidBackingView: UIViewControllerRepresentable {
  let color: UIColor

  func makeUIViewController(context: Context) -> BeidBackingController {
    BeidBackingController(color: color)
  }

  func updateUIViewController(_ controller: BeidBackingController, context: Context) {
    controller.setBackground(color)
  }
}

/// UIKit owns the window, hosting roots and tab container beneath SwiftUI.
/// Use public controller containment, never private UIKit class names or a
/// global UIView appearance proxy. Each appearing screen restores its ground
/// on pop/dismiss as well as push, without changing navigation or sheet behavior.
final class BeidBackingController: UIViewController {
  private static let visibleSurfaces = NSHashTable<BeidBackingController>.weakObjects()
  private var ground: UIColor
  private var isVisible = false
  private weak var backingWindow: UIWindow?

  init(color: UIColor) {
    ground = color
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { return nil }

  override func loadView() {
    view = UIView()
    view.isUserInteractionEnabled = false
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    isVisible = true
    Self.visibleSurfaces.add(self)
    applyBackground()
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    applyBackground()
  }

  override func viewWillDisappear(_ animated: Bool) {
    isVisible = false
    super.viewWillDisappear(animated)
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    Self.visibleSurfaces.remove(self)
    // A page sheet leaves its presenter visible, so dismissal does not always
    // send that presenter another viewWillAppear. Restore its backing here.
    guard let backingWindow else { return }
    for surface in Self.visibleSurfaces.allObjects
      .filter({ $0.viewIfLoaded?.window === backingWindow })
      .sorted(by: { $0.containmentDepth < $1.containmentDepth }) {
      surface.applyBackground()
    }
  }

  private var containmentDepth: Int {
    var depth = 0
    var owner = parent
    while let current = owner { depth += 1; owner = current.parent }
    return depth
  }

  func setBackground(_ color: UIColor) {
    guard !ground.resolvedColor(with: traitCollection).isEqual(color.resolvedColor(with: traitCollection)) else { return }
    ground = color
    if isVisible { applyBackground() }
  }

  private func applyBackground() {
    guard isVisible else { return }
    var chain: [UIViewController] = []
    var child: UIViewController = self
    while let owner = child.parent {
      if let navigation = owner as? UINavigationController, navigation.topViewController !== child { return }
      if let tabs = owner as? UITabBarController, tabs.selectedViewController !== child { return }
      if let presented = owner.presentedViewController, !presented.isBeingDismissed { return }
      chain.append(owner)
      child = owner
    }
    let window = chain.compactMap { $0.viewIfLoaded?.window }.first ?? viewIfLoaded?.window
    backingWindow = window
    for controller in chain { controller.viewIfLoaded?.backgroundColor = ground }
    window?.backgroundColor = ground
  }
}
