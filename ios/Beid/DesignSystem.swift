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

/// The filled capsule: one per screen (DESIGN.md §10). Drawn by
/// `BeidPrimaryButtonStyle`, which owns the pressed, disabled and busy states.
struct BeidPrimaryButton: View {
  /// Fill and label pairing. `.inverse` is for ink grounds (DESIGN.md §5) and
  /// is passed explicitly at each ink call site: a white screen that inherits
  /// an ink ground must not draw a white capsule on white.
  enum Tone {
    case primary
    case inverse
  }

  let title: LocalizedStringKey
  let labelColor: Color?
  let tone: Tone
  let hapticStyle: UIImpactFeedbackGenerator.FeedbackStyle
  let role: ButtonRole?
  let isBusy: Bool
  let action: () -> Void

  /// `labelColor` overrides the enabled label only; a disabled capsule always
  /// uses its disabled pairing. `isBusy` shows a small activity indicator in
  /// the capsule for an action that does not finish instantly; pair it with
  /// `.disabled(...)`.
  init(
    _ title: LocalizedStringKey,
    tone: Tone = .primary,
    labelColor: Color? = nil,
    haptic: UIImpactFeedbackGenerator.FeedbackStyle = .light,
    role: ButtonRole? = nil,
    isBusy: Bool = false,
    action: @escaping () -> Void
  ) {
    self.title = title
    self.tone = tone
    self.labelColor = labelColor
    self.hapticStyle = haptic
    self.role = role
    self.isBusy = isBusy
    self.action = action
  }

  var body: some View {
    Button(role: role, action: performAction) {
      Text(title)
    }
    .buttonStyle(.beidPrimary(tone: tone, labelColor: labelColor, isBusy: isBusy))
  }

  private func performAction() {
    BeidDesign.haptic(hapticStyle)
    action()
  }
}

/// The transparent capsule with a 1 pt accent outline (DESIGN.md §10), in
/// three sizes. Drawn by `BeidSecondaryButtonStyle`.
struct BeidSecondaryButton: View {
  let title: LocalizedStringKey
  let size: BeidButtonSize
  let accessibilityLabel: LocalizedStringKey?
  let hapticStyle: UIImpactFeedbackGenerator.FeedbackStyle?
  let action: () -> Void

  /// The compact tier renders its title uppercase; VoiceOver and UI tests
  /// still read the title as written (or `accessibilityLabel`).
  ///
  /// `haptic` keeps the soft tap the previous `BeidSecondaryButton` always
  /// played, so existing call sites are unchanged; pass `nil` for none.
  init(
    title: LocalizedStringKey,
    size: BeidButtonSize = .large,
    accessibilityLabel: LocalizedStringKey? = nil,
    haptic: UIImpactFeedbackGenerator.FeedbackStyle? = .soft,
    action: @escaping () -> Void
  ) {
    self.title = title
    self.size = size
    self.accessibilityLabel = accessibilityLabel
    self.hapticStyle = haptic
    self.action = action
  }

  var body: some View {
    Button(action: performAction) {
      Text(title)
    }
    .buttonStyle(.beidSecondary(size: size))
    .accessibilityLabel(Text(accessibilityLabel ?? title))
  }

  private func performAction() {
    if let hapticStyle { BeidDesign.haptic(hapticStyle) }
    action()
  }
}

/// Static status: an 8 pt dot plus a text label, with no capsule. Capsules are
/// reserved for buttons (DESIGN.md §8).
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
  }
}

struct BeidPanel<Content: View>: View {
  let content: Content

  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  var body: some View {
    content
      .beidGround(.canvas)
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

// MARK: - Button styles, ground and control palette (2026-11-18)
//
// What can be tapped (DESIGN.md §10, §12, §13; docs/decisions/issue-pending-tap-accent.md).
// One interaction accent with one meaning ("you can tap this, now"), three
// capsule tiers, row cues, and real pressed, disabled and busy states. Screens
// declare the ground they sit on; controls resolve their colors from it, so
// call sites no longer pass label colors. The two accent values are a
// PROPOSAL awaiting the maintainer's choice.

/// The surface a control sits on: the white page ground or the black
/// "what is happening now" ground. It picks the accent value (`actionAccent`
/// on `.canvas`, `actionAccentOnInk` on `.ink`) and the disabled colors.
enum BeidGround: Equatable {
  case canvas
  case ink
}

private struct BeidGroundKey: EnvironmentKey {
  static let defaultValue = BeidGround.canvas
}

extension EnvironmentValues {
  /// The ground the current view sits on. A forgotten declaration degrades to
  /// the canvas accent, which is still 3.54:1 on ink, so a control never turns
  /// invisible.
  var beidGround: BeidGround {
    get { self[BeidGroundKey.self] }
    set { self[BeidGroundKey.self] = newValue }
  }
}

extension View {
  /// Declares the ground a subtree sits on and applies its accent as the tint.
  /// Apply it outside (after) `.toolbar` and `.safeAreaInset` so bar items and
  /// insets inherit it.
  func beidGround(_ ground: BeidGround) -> some View {
    self
      .environment(\.beidGround, ground)
      .tint(ground == .ink ? DS.Color.actionAccentOnInk : DS.Color.actionAccent)
  }

  /// `beidGround(_:)` plus the ground itself, painted behind the view and
  /// ignoring safe areas. The only way a screen paints its ground.
  func beidScreenGround(_ ground: BeidGround) -> some View {
    self
      .background {
        (ground == .ink ? DS.Color.surfaceNow : DS.Color.surfaceCanvas)
          .ignoresSafeArea()
      }
      .beidGround(ground)
  }

  /// Puts the canvas accent on an OS alert or confirmation dialog. OS alert
  /// surfaces are always white, so an alert attached inside a subtree whose tint
  /// can be the on-ink accent (3.54:1 on white) is followed directly by this.
  func beidAlertTint() -> some View {
    tint(DS.Color.actionAccent)
  }
}

/// Maps (ground, enabled state, tone) to `DS.Color` tokens in one place, so
/// every style and helper agrees and the mapping can be pinned by tests.
enum BeidControlPalette {
  /// The accent of an enabled control, or its disabled replacement.
  static func interactive(ground: BeidGround, isEnabled: Bool) -> Color {
    switch (ground, isEnabled) {
    case (.canvas, true): DS.Color.actionAccent
    case (.ink, true): DS.Color.actionAccentOnInk
    case (.canvas, false): DS.Color.labelDisabled
    case (.ink, false): DS.Color.labelDisabledOnInk
    }
  }

  static func primaryFill(tone: BeidPrimaryButton.Tone, isEnabled: Bool) -> Color {
    switch (tone, isEnabled) {
    case (.primary, true): DS.Color.actionPrimary
    case (.inverse, true): DS.Color.actionInverse
    case (.primary, false): DS.Color.actionDisabled
    case (.inverse, false): DS.Color.actionDisabledOnInk
    }
  }

  static func primaryLabel(tone: BeidPrimaryButton.Tone, isEnabled: Bool) -> Color {
    switch (tone, isEnabled) {
    case (.primary, true): DS.Color.labelOnActionPrimary
    case (.inverse, true): DS.Color.labelOnActionInverse
    case (.primary, false): DS.Color.labelOnActionDisabled
    case (.inverse, false): DS.Color.labelOnActionDisabledOnInk
    }
  }

  /// The title of a row that is the action's own label (Account "Join event").
  static func actionTitle(ground: BeidGround, isEnabled: Bool) -> Color {
    switch (ground, isEnabled) {
    case (.canvas, true): DS.Color.textPrimary
    case (.ink, true): DS.Color.labelOnActionPrimary
    case (.canvas, false): DS.Color.labelDisabled
    case (.ink, false): DS.Color.labelDisabledOnInk
    }
  }

  /// Enabled text controls are underlined when Button Shapes or Differentiate
  /// Without Color is on, and under Increase Contrast, where the accent is only
  /// 2.74:1 against adjacent ink text. Disabled controls are never underlined.
  static func underlinesTextControl(
    isEnabled: Bool,
    showsButtonShapes: Bool,
    differentiatesWithoutColor: Bool,
    contrast: ColorSchemeContrast
  ) -> Bool {
    isEnabled && (showsButtonShapes || differentiatesWithoutColor || contrast == .increased)
  }
}

/// How large a secondary capsule is.
enum BeidButtonSize {
  /// Screen-level actions and footers: full width, at least 56 pt, `DS.Font.cta`.
  case large
  /// Height-constrained strips: full width, at least 44 pt, `DS.Font.cta`.
  case regular
  /// In-place actions next to their object: hugs its label, at least 32 pt
  /// visible inside a 44 x 44 pt hit region, Label/Mono 11 uppercase.
  case compact
}

/// Pressed feedback shared by every style: opacity only, animated with
/// `DS.Motion.fast`, not at all under Reduce Motion, and none while disabled.
private struct BeidPressFeedback: ViewModifier {
  let isPressed: Bool
  let pressedOpacity: Double
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func body(content: Content) -> some View {
    let pressed = isPressed && isEnabled
    content
      .opacity(pressed ? pressedOpacity : 1)
      .animation(reduceMotion ? nil : DS.Motion.fast, value: pressed)
  }
}

/// The filled capsule. Use through `BeidPrimaryButton` or `.beidPrimary(...)`.
struct BeidPrimaryButtonStyle: ButtonStyle {
  var tone: BeidPrimaryButton.Tone = .primary
  var labelColor: Color?
  var isBusy = false

  func makeBody(configuration: Configuration) -> some View {
    StyledBody(configuration: configuration, tone: tone, labelColor: labelColor, isBusy: isBusy)
  }

  private struct StyledBody: View {
    let configuration: ButtonStyleConfiguration
    let tone: BeidPrimaryButton.Tone
    let labelColor: Color?
    let isBusy: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
      let label = isEnabled
        ? (labelColor ?? BeidControlPalette.primaryLabel(tone: tone, isEnabled: true))
        : BeidControlPalette.primaryLabel(tone: tone, isEnabled: false)

      HStack(spacing: DS.Space.s) {
        if isBusy {
          ProgressView()
            .controlSize(.small)
            .tint(label)
            .accessibilityHidden(true)
        }
        configuration.label
          .font(DS.Font.cta)
          .multilineTextAlignment(.center)
      }
      .foregroundStyle(label)
      .padding(.horizontal, DS.Space.l)
      .frame(maxWidth: .infinity, minHeight: DS.Size.primaryButtonMinHeight)
      .background(BeidControlPalette.primaryFill(tone: tone, isEnabled: isEnabled), in: Capsule())
      .contentShape(Capsule())
      .modifier(BeidPressFeedback(isPressed: configuration.isPressed, pressedOpacity: DS.Opacity.pressedFill))
    }
  }
}

/// The transparent capsule with a 1 pt accent outline. Use through
/// `BeidSecondaryButton` or `.beidSecondary(size:)`.
struct BeidSecondaryButtonStyle: ButtonStyle {
  var size: BeidButtonSize = .large

  func makeBody(configuration: Configuration) -> some View {
    StyledBody(configuration: configuration, size: size)
  }

  private struct StyledBody: View {
    let configuration: ButtonStyleConfiguration
    let size: BeidButtonSize
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.beidGround) private var ground

    var body: some View {
      let color = BeidControlPalette.interactive(ground: ground, isEnabled: isEnabled)

      sized(configuration.label, color: color)
        .modifier(BeidPressFeedback(isPressed: configuration.isPressed, pressedOpacity: DS.Opacity.pressedLabel))
    }

    @ViewBuilder
    private func sized(_ label: ButtonStyleConfiguration.Label, color: Color) -> some View {
      switch size {
      case .large:
        capsule(label, color: color, minHeight: DS.Size.primaryButtonMinHeight)
      case .regular:
        capsule(label, color: color, minHeight: DS.Size.minHitTarget)
      case .compact:
        label
          .beidTextStyle(DS.Font.Library.labelMono11)
          .multilineTextAlignment(.center)
          .foregroundStyle(color)
          .padding(.horizontal, DS.Space.m)
          .frame(minHeight: DS.Size.compactControlMinHeight)
          .overlay { Capsule().strokeBorder(color, lineWidth: DS.Size.hairline) }
          // The visible capsule is 32 pt; the hit region is at least 44 x 44.
          .frame(minWidth: DS.Size.minHitTarget, minHeight: DS.Size.minHitTarget)
          .contentShape(Rectangle())
      }
    }

    private func capsule(_ label: ButtonStyleConfiguration.Label, color: Color, minHeight: CGFloat) -> some View {
      label
        .font(DS.Font.cta)
        .multilineTextAlignment(.center)
        .foregroundStyle(color)
        .padding(.horizontal, DS.Space.l)
        .frame(maxWidth: .infinity, minHeight: minHeight)
        .overlay { Capsule().strokeBorder(color, lineWidth: DS.Size.hairline) }
        .contentShape(Capsule())
    }
  }
}

/// The tertiary text control's button style: the label is drawn by
/// `BeidTextControlLabel` (accent, hit region, underline conditions); this adds
/// the pressed state and nothing else.
struct BeidTextButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .modifier(BeidPressFeedback(isPressed: configuration.isPressed, pressedOpacity: DS.Opacity.pressedLabel))
  }
}

/// For whole-row and whole-card buttons and navigation links: the content keeps
/// its ink or gray and only the pressed state is added. The row carries a
/// `BeidRowCue` to show that it acts.
struct BeidRowButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .contentShape(Rectangle())
      .modifier(BeidPressFeedback(isPressed: configuration.isPressed, pressedOpacity: DS.Opacity.pressedLabel))
  }
}

extension ButtonStyle where Self == BeidPrimaryButtonStyle {
  static func beidPrimary(
    tone: BeidPrimaryButton.Tone = .primary,
    labelColor: Color? = nil,
    isBusy: Bool = false
  ) -> BeidPrimaryButtonStyle {
    BeidPrimaryButtonStyle(tone: tone, labelColor: labelColor, isBusy: isBusy)
  }
}

extension ButtonStyle where Self == BeidSecondaryButtonStyle {
  static func beidSecondary(size: BeidButtonSize = .large) -> BeidSecondaryButtonStyle {
    BeidSecondaryButtonStyle(size: size)
  }
}

extension ButtonStyle where Self == BeidTextButtonStyle {
  static var beidText: BeidTextButtonStyle { BeidTextButtonStyle() }
}

extension ButtonStyle where Self == BeidRowButtonStyle {
  static var beidRow: BeidRowButtonStyle { BeidRowButtonStyle() }
}

/// The trailing cue of a tappable row or card, in the accent: → opens another
/// screen in the app, ↗ leaves the app, or an existing action word (JOIN,
/// Rejoin). Arrows are hidden from VoiceOver because the row's own label
/// carries the meaning; a word stays in the spoken label.
struct BeidRowCue: View {
  enum Kind {
    case forward
    case external
  }

  private enum Content {
    case glyph(String)
    case word(LocalizedStringKey)
  }

  private let content: Content

  init(_ kind: Kind) {
    switch kind {
    case .forward: content = .glyph("→")
    case .external: content = .glyph("↗")
    }
  }

  init(word: LocalizedStringKey) {
    content = .word(word)
  }

  var body: some View {
    Group {
      switch content {
      case .glyph(let character):
        Text(verbatim: character).accessibilityHidden(true)
      case .word(let word):
        Text(word)
      }
    }
    .beidTextStyle(DS.Font.Library.labelMono11)
    .beidAccentForeground()
  }
}

private struct BeidAccentForeground: ViewModifier {
  let underlinesWhenNeeded: Bool
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.beidGround) private var ground
  @Environment(\.accessibilityShowButtonShapes) private var showsButtonShapes
  @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiatesWithoutColor
  @Environment(\.colorSchemeContrast) private var contrast

  func body(content: Content) -> some View {
    content
      .foregroundStyle(BeidControlPalette.interactive(ground: ground, isEnabled: isEnabled))
      .underline(
        underlinesWhenNeeded
          && BeidControlPalette.underlinesTextControl(
            isEnabled: isEnabled,
            showsButtonShapes: showsButtonShapes,
            differentiatesWithoutColor: differentiatesWithoutColor,
            contrast: contrast
          )
      )
  }
}

private struct BeidActionRowTitle: ViewModifier {
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.beidGround) private var ground

  func body(content: Content) -> some View {
    content.foregroundStyle(BeidControlPalette.actionTitle(ground: ground, isEnabled: isEnabled))
  }
}

extension View {
  /// Colors an existing arrow or action text ("→", "JOIN →", "N records →",
  /// "Copy") with the ground's accent, or its disabled replacement. With
  /// `underlinesWhenNeeded`, it also underlines when Button Shapes, Differentiate
  /// Without Color or Increase Contrast is on; only the glyphless "Copy" needs
  /// that, because row cues are already separated by position and a glyph.
  func beidAccentForeground(underlinesWhenNeeded: Bool = false) -> some View {
    modifier(BeidAccentForeground(underlinesWhenNeeded: underlinesWhenNeeded))
  }

  /// Colors a row title that is the action's own label (Account "Join event").
  func beidActionRowTitle() -> some View {
    modifier(BeidActionRowTitle())
  }
}
