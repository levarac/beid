// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import SwiftUI

/// A control affix (`←`, `→`) bound to what the control announces instead of
/// it — one value, so the two cannot be written apart (DESIGN.md §12's third
/// MUST, §13).
///
/// The glyph is not an icon: it is a literal character in the control's own
/// monospaced text, which is exactly why it needs a spoken label. `←` announces
/// as a symbol name, not as a destination.
///
/// The typed glyph initializers always require the spoken label; a call site
/// cannot use this glyph API without providing one. As with any text API,
/// callers still need to avoid putting a raw arrow in the title itself.
struct BeidTextControlGlyph {
  enum Placement {
    case leading
    case trailing
  }

  let placement: Placement
  let character: String
  /// What VoiceOver announces for the **whole** control, glyph included.
  let accessibilityLabel: LocalizedStringKey

  private init(placement: Placement, character: String, accessibilityLabel: LocalizedStringKey) {
    self.placement = placement
    self.character = character
    self.accessibilityLabel = accessibilityLabel
  }

  /// A glyph before the title, e.g. `.leading("←", announcing: "Back to Events")`.
  static func leading(
    _ character: String,
    announcing accessibilityLabel: LocalizedStringKey
  ) -> BeidTextControlGlyph {
    BeidTextControlGlyph(
      placement: .leading,
      character: character,
      accessibilityLabel: accessibilityLabel
    )
  }

  /// A glyph after the title, e.g. `.trailing("→", announcing: "Open event")`.
  static func trailing(
    _ character: String,
    announcing accessibilityLabel: LocalizedStringKey
  ) -> BeidTextControlGlyph {
    BeidTextControlGlyph(
      placement: .trailing,
      character: character,
      accessibilityLabel: accessibilityLabel
    )
  }
}

/// The label half of a Flat 2b text control: monospaced uppercase text with a
/// guaranteed 44×44pt hit region (DESIGN.md §12 "no icons", §2 rule 5).
///
/// Separate from `BeidTextControl` because several call sites are
/// `NavigationLink`s and `ToolbarItem`s that already own their action and need
/// only the label.
///
/// **Accessibility.** Two initializers, and which one you reach for decides the
/// announcement:
///
/// - Plain text (`CLOSE`, `DONE`) reads correctly aloud as it stands, so
///   `accessibilityLabel` is optional and omitting it keeps SwiftUI's default —
///   the control's own visible text.
/// - A glyph-bearing control takes a `BeidTextControlGlyph`, which carries its
///   spoken label with it. There is no way to pass the one without the other.
struct BeidTextControlLabel: View {
  let title: LocalizedStringKey
  let glyph: BeidTextControlGlyph?
  let labelColor: Color
  let accessibilityLabel: LocalizedStringKey?

  /// A plain text control, with no glyph. `accessibilityLabel` is an override
  /// for copy that reads badly aloud; omit it and the visible text is used.
  init(
    _ title: LocalizedStringKey,
    labelColor: Color = DS.Color.textPrimary,
    accessibilityLabel: LocalizedStringKey? = nil
  ) {
    self.title = title
    self.glyph = nil
    self.labelColor = labelColor
    self.accessibilityLabel = accessibilityLabel
  }

  /// A glyph-bearing control. The glyph supplies the VoiceOver label, so there
  /// is no `accessibilityLabel` parameter to forget.
  init(
    _ title: LocalizedStringKey,
    glyph: BeidTextControlGlyph,
    labelColor: Color = DS.Color.textPrimary
  ) {
    self.title = title
    self.glyph = glyph
    self.labelColor = labelColor
    self.accessibilityLabel = glyph.accessibilityLabel
  }

  var body: some View {
    labelContent
      .accessibilityLabelIfProvided(accessibilityLabel)
  }

  @ViewBuilder
  private var labelContent: some View {
    HStack(spacing: DS.Space.xs) {
      if let glyph, glyph.placement == .leading {
        Text(verbatim: glyph.character)
      }
      Text(title)
      if let glyph, glyph.placement == .trailing {
        Text(verbatim: glyph.character)
      }
    }
    // #629's full Label/Mono 11 style supplies the bundled face, uppercase,
    // tracking and Dynamic Type scaling. Keep the source strings in their
    // original case so String Catalog keys remain intact (DESIGN.md §15).
    .beidTextStyle(DS.Font.Library.labelMono11)
    .foregroundStyle(labelColor)
    // `minHeight`, never `height`: DESIGN.md §6 forbids fixed-height
    // containers around text, which would clip at accessibility Dynamic Type
    // sizes. The minimum is the §2 rule 5 hit region, which an 11pt label
    // cannot reach on its own.
    .frame(minWidth: DS.Size.minHitTarget, minHeight: DS.Size.minHitTarget)
    // Load-bearing. Without it the frame above does NOT enlarge the tappable
    // area: SwiftUI hit-tests the drawn glyphs, so a one-character label such
    // as "←" stays a ~10×13pt target and fails the 44×44pt requirement. This
    // single modifier is the difference between meeting §2 rule 5 and only
    // appearing to.
    .contentShape(Rectangle())
  }
}

private extension View {
  /// Applies `.accessibilityLabel` only when a label was supplied, so an
  /// unlabelled control keeps SwiftUI's default — its own visible text.
  ///
  /// `.accessibilityElement(children: .ignore)` is not optional here.
  /// A `← EVENTS` label is an `HStack` of two `Text`s, and a container with
  /// more than one child exposes one element per child; `.accessibilityLabel`
  /// on the container is then ignored and VoiceOver announces the raw `←`
  /// after all — the exact failure DESIGN.md §12's third MUST forbids, and one
  /// that looks correct in the source. Collapsing to a single element first
  /// makes the supplied label the only thing announced.
  @ViewBuilder
  func accessibilityLabelIfProvided(_ label: LocalizedStringKey?) -> some View {
    if let label {
      self
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    } else {
      self
    }
  }
}

/// A Flat 2b text control: `BeidTextControlLabel` in a `Button`
/// (DESIGN.md §12). Use it for `CLOSE`, `DONE`, `COPY`, `OPEN →`.
///
/// `.buttonStyle(.plain)` so no system chrome reappears around the text, and
/// the haptic fires before the action, matching `BeidPrimaryButton`.
///
/// **On `labelColor` and destructive roles.** `role: .destructive` changes the
/// semantics, not the color. DESIGN.md §5 permits `DS.Color.statusOff` as text
/// only on an ink ground; on the page ground a destructive control stays
/// `textPrimary` and carries its weight in the copy. Pass `labelColor`
/// explicitly only where §5 allows it.
struct BeidTextControl: View {
  let title: LocalizedStringKey
  let glyph: BeidTextControlGlyph?
  let labelColor: Color
  let accessibilityLabel: LocalizedStringKey?
  let role: ButtonRole?
  let action: () -> Void

  /// A plain text control, with no glyph. See `BeidTextControlLabel`'s
  /// matching initializer for what `accessibilityLabel` does and does not do.
  init(
    _ title: LocalizedStringKey,
    labelColor: Color = DS.Color.textPrimary,
    accessibilityLabel: LocalizedStringKey? = nil,
    role: ButtonRole? = nil,
    action: @escaping () -> Void
  ) {
    self.title = title
    self.glyph = nil
    self.labelColor = labelColor
    self.accessibilityLabel = accessibilityLabel
    self.role = role
    self.action = action
  }

  /// A glyph-bearing control. The glyph supplies the VoiceOver label, so there
  /// is no `accessibilityLabel` parameter to forget.
  init(
    _ title: LocalizedStringKey,
    glyph: BeidTextControlGlyph,
    labelColor: Color = DS.Color.textPrimary,
    role: ButtonRole? = nil,
    action: @escaping () -> Void
  ) {
    self.title = title
    self.glyph = glyph
    self.labelColor = labelColor
    self.accessibilityLabel = glyph.accessibilityLabel
    self.role = role
    self.action = action
  }

  var body: some View {
    Button(role: role, action: performAction) {
      label
    }
    .buttonStyle(.plain)
  }

  @ViewBuilder
  private var label: some View {
    if let glyph {
      BeidTextControlLabel(title, glyph: glyph, labelColor: labelColor)
    } else {
      BeidTextControlLabel(
        title,
        labelColor: labelColor,
        accessibilityLabel: accessibilityLabel
      )
    }
  }

  private func performAction() {
    BeidDesign.haptic()
    action()
  }
}
