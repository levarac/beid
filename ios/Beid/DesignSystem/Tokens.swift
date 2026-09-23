// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import SwiftUI
import UIKit

/// Canonical design tokens for beid. This file and `Colors.xcassets` are the
/// only places raw color/font/spacing/radius/motion values may appear —
/// see DESIGN.md §0 "Source of Truth" and §4 "Token Architecture".
///
/// Views consume tokens exclusively through the `DS` namespace
/// (`DS.Color.*`, `DS.Space.*`, `DS.Radius.*`, `DS.Font.*`, `DS.Motion.*`).
/// SwiftLint custom rules (.swiftlint.yml at repo root) flag raw values
/// outside this directory.
enum DS {

  // MARK: - Color
  //
  // Two tiers (DESIGN.md §4). Tier 1 is the Flat 2b Library palette: one
  // colorset per Library variable in Colors.xcassets, each a single
  // appearance (one sRGB value, no dark variant) — DESIGN.md §5 allows
  // only the Library colors. Tier 2 is `DS.Color`: tokens named by role,
  // each mapped onto one primitive; several roles may share a primitive.
  // Views use tier 2 only. Roles and allowed uses are in DESIGN.md §5.
  enum Color {
    /// Page ground of every screen. Library `bg`.
    static let surfaceCanvas = SwiftUI.Color(.bg)
    /// Primary text and marks (icons, neutral dots) on the page ground.
    /// Library `ink`.
    static let textPrimary = SwiftUI.Color(.ink)
    /// Secondary text and section labels on the page ground. Library `sub`.
    static let textSecondary = SwiftUI.Color(.sub)
    /// 1pt row and list dividers on the page ground. Library `line`.
    static let strokeHairline = SwiftUI.Color(.line)
    /// Dashed 1pt frame of the empty block (`Block/Empty`). Library
    /// `line-dashed`.
    static let strokeEmptyState = SwiftUI.Color(.lineDashed)
    /// Gray tiles and the timeline track. Library `tile`.
    static let surfaceTile = SwiftUI.Color(.tile)
    /// "Detected" bars in charts. Library `chart-muted`.
    static let chartDetected = SwiftUI.Color(.chartMuted)
    /// Secondary text on an ink ground. Library `on-ink/sub`.
    static let textSecondaryOnInk = SwiftUI.Color(.onInkSub)
    /// Dividers, graph rings and future-window bars on an ink ground.
    /// Library `on-ink/line`.
    static let strokeHairlineOnInk = SwiftUI.Color(.onInkLine)
    /// Detected-only (idle) graph nodes on an ink ground. Library
    /// `on-ink/idle`.
    static let graphNodeIdle = SwiftUI.Color(.onInkIdle)
    /// `Button/Primary` Tone=Primary fill; also the app-level tint.
    /// Library `ink`.
    static let actionPrimary = SwiftUI.Color(.ink)
    /// Label on an `actionPrimary` fill. Library `bg`.
    static let labelOnActionPrimary = SwiftUI.Color(.bg)
    /// `Button/Primary` Tone=Inverse fill, for black screens and the black
    /// sheet. Library `bg`.
    static let actionInverse = SwiftUI.Color(.bg)
    /// Label on an `actionInverse` fill. Library `ink`.
    static let labelOnActionInverse = SwiftUI.Color(.ink)
    /// Active / on. An indicator dot paired with a text label on the page
    /// ground; text only on an ink ground (DESIGN.md §5). Library
    /// `semantic/green`.
    static let statusOn = SwiftUI.Color(.semanticGreen)
    /// Verifying / pending. Same restriction as `statusOn`. Library
    /// `semantic/amber`.
    static let statusPending = SwiftUI.Color(.semanticAmber)
    /// Destructive / off. Same restriction as `statusOn`. Library
    /// `semantic/red`.
    static let statusOff = SwiftUI.Color(.semanticRed)
  }

  // MARK: - Space
  //
  // 4 pt base scale. See DESIGN.md §7.
  enum Space {
    /// 4 pt.
    static let xs: CGFloat = 4
    /// 8 pt.
    static let s: CGFloat = 8
    /// 16 pt.
    static let m: CGFloat = 16
    /// 24 pt.
    static let l: CGFloat = 24
    /// 32 pt.
    static let xl: CGFloat = 32
    /// 48 pt.
    static let xxl: CGFloat = 48
    /// Default horizontal page margin for full-width content and CTAs
    /// (Flat 2b: 354 pt content width on a 402 pt screen).
    static let pageMargin: CGFloat = 24
    /// Vertical padding of the empty block (`Block/Empty`, DESIGN.md §8).
    static let emptyBlockVertical: CGFloat = 40
  }

  // MARK: - Radius
  //
  // See DESIGN.md §8. `Button/Primary` is a capsule (radius = height / 2),
  // expressed with `pill`, not a separate token.
  enum Radius {
    /// Small controls and inline chips.
    static let control: CGFloat = 12
    /// Standard cards (proof cards, event cards).
    static let card: CGFloat = 16
    /// Proof seal artwork and ceremony surfaces.
    static let seal: CGFloat = 28
    /// Fully rounded pills and capsule buttons.
    static let pill: CGFloat = 999
    /// `BeidGlyph`'s icon roundel.
    static let glyph: CGFloat = 24
    /// Frame of the empty block (`Block/Empty`).
    static let emptyBlock: CGFloat = 16
    /// The now-sensing ink card (DESIGN.md §8).
    static let nowCard: CGFloat = 20
  }

  // MARK: - Size
  //
  // Row heights are minimums: rows grow with Dynamic Type (DESIGN.md §16).
  enum Size {
    /// HIG minimum hit region for interactive elements.
    static let minHitTarget: CGFloat = 44
    /// `BeidStatusPill` indicator dot diameter.
    static let statusDot: CGFloat = 8
    /// Sensing radar field — width/height of the concentric-ring frame in `SensingView`.
    static let radarField: CGFloat = 210
    /// Sensing radar center glyph size in `SensingView`.
    static let radarCore: CGFloat = 86
    /// `ProofCardView`'s circular per-proof gradient avatar diameter.
    static let proofCardArtwork: CGFloat = 76
    /// `ItemDetailView`'s circular per-proof gradient avatar diameter —
    /// the same artwork generator as `proofCardArtwork`, at detail scale.
    static let itemDetailArtwork: CGFloat = 190
    /// The 1 pt rule: hairline dividers and the empty block's dashed frame.
    static let hairline: CGFloat = 1
    /// Dash and gap length of the empty block's dashed frame (`Block/Empty`
    /// dashPattern [4, 4]).
    static let emptyBlockDash: CGFloat = 4
    /// `Row/List` minimum height (content, excluding its top hairline).
    static let listRowMinHeight: CGFloat = 92
    /// `Row/KeyValue` minimum height.
    static let keyValueRowMinHeight: CGFloat = 44
    /// Session row minimum height.
    static let sessionRowMinHeight: CGFloat = 48
    /// Report row minimum height.
    static let reportRowMinHeight: CGFloat = 60
    /// Proof row minimum height.
    static let proofRowMinHeight: CGFloat = 72
    /// `Button/Primary` Size=Large minimum height. Its width is the full
    /// content width at `Space.pageMargin`, so it has no width token.
    static let primaryButtonMinHeight: CGFloat = 56
    /// `Button/Primary` Size=Small minimum height (Home's Scan).
    static let compactPrimaryButtonMinHeight: CGFloat = 52
    /// `Button/Primary` Size=Small width (Home's Scan).
    static let compactPrimaryButtonWidth: CGFloat = 140
    /// Icon roundel diameter for two-line bullet rows (`BeidBulletRow`).
    static let bulletIcon: CGFloat = 32
    /// Numbered badge diameter for step lists (`BeidNumberedStepList`).
    static let stepBadge: CGFloat = 28
  }

  // MARK: - Layout
  //
  // Readable-width limits for adaptive iPad layouts. Compact width keeps the
  // screen's existing edge-to-edge treatment; regular width uses these caps.
  enum Layout {
    /// Maximum readable width for state screens and their primary CTA.
    static let stateContentMaxWidth: CGFloat = 600
    /// Maximum width for collection content in regular horizontal size classes.
    static let collectionContentMaxWidth: CGFloat = 960
    /// Minimum proof-card width for regular-width collection grids.
    static let regularGridCardMinimumWidth: CGFloat = 260
    /// Minimum proof-card width for compact-width collection grids.
    static let compactGridCardMinimumWidth: CGFloat = 150
  }

  // MARK: - Font
  //
  // Two tiers (DESIGN.md §4), the same shape #628 gave `DS.Color`. Tier 1
  // is `Font.Library`: the 17 Flat 2b Library text styles, carrying the
  // bundled face, the base size and the typographic settings §6 records.
  // Tier 2 is `DS.Font` itself: tokens named by role, each pointing at one
  // Library style; several roles may share one. Views use tier 2 only.
  //
  // `Font.custom(_:size:relativeTo:)` is the only font constructor here
  // (§6's Dynamic Type MUST) and is allowed in this directory and nowhere
  // else. The three families are bundled with the app (#629); their
  // PostScript names appear only in `Library`.
  enum Font {

    /// One Flat 2b Library text style: the bundled face, its base size at
    /// the default content size, and the settings §6's ramp table records
    /// for it.
    ///
    /// `font` alone carries family, size and Dynamic Type. Tracking, line
    /// height and case reach a view only through `beidTextStyle(_:)`, which
    /// needs the whole value — which is why this is a value type and not
    /// nine parallel `SwiftUI.Font` constants.
    struct Style {
      /// PostScript name of the bundled face (`UIAppFonts`, #629).
      let postScriptName: String
      /// Base size in points at the default content size (`.large`).
      let size: CGFloat
      /// Apple text style whose Dynamic Type curve scales `size`.
      let textStyle: SwiftUI.Font.TextStyle
      /// Letter spacing as a fraction of the point size — the Library's
      /// percentage over 100, so it scales with the text rather than
      /// staying a fixed point offset.
      let tracking: CGFloat
      /// Line height as a multiple of the point size. `nil` is the
      /// Library's "auto": the face's own line height, untouched.
      let lineHeight: CGFloat?
      /// Whether the style renders uppercase.
      let isUppercase: Bool
      /// Whether digits are forced to equal width.
      let usesMonospacedDigits: Bool

      init(
        postScriptName: String,
        size: CGFloat,
        textStyle: SwiftUI.Font.TextStyle,
        tracking: CGFloat = 0,
        lineHeight: CGFloat? = nil,
        isUppercase: Bool = false,
        usesMonospacedDigits: Bool = false
      ) {
        self.postScriptName = postScriptName
        self.size = size
        self.textStyle = textStyle
        self.tracking = tracking
        self.lineHeight = lineHeight
        self.isUppercase = isUppercase
        self.usesMonospacedDigits = usesMonospacedDigits
      }

      /// The face at its base size, scaling on `textStyle`'s curve.
      var font: SwiftUI.Font {
        let scaling = SwiftUI.Font.custom(postScriptName, size: size, relativeTo: textStyle)
        return usesMonospacedDigits ? scaling.monospacedDigit() : scaling
      }

      /// Letter spacing in points at `pointSize` — the Dynamic Type-scaled
      /// size, not `size`, so tracking keeps its proportion as text grows.
      func tracking(atPointSize pointSize: CGFloat) -> CGFloat {
        tracking * pointSize
      }

      /// Extra space to add *between* lines at `pointSize` so the line box
      /// measures `lineHeight × pointSize`.
      ///
      /// Returns 0 when `lineHeight` is nil, when the face is unavailable,
      /// and — deliberately — whenever the requested line height is below
      /// the face's own: `lineSpacing` is additive and
      /// `NSParagraphStyle.lineSpacing` "is always nonnegative", so there is
      /// no supported way to tighten a line box on this deployment target.
      /// Display/60 · 52 · 46 ask for 100% against Bricolage's 1.2 em face
      /// and therefore land on the face's line height, not the Library's —
      /// see §6's line-height gap.
      func lineSpacing(atPointSize pointSize: CGFloat) -> CGFloat {
        guard
          let lineHeight,
          let face = UIFont(name: postScriptName, size: pointSize)
        else { return 0 }
        return max(0, lineHeight * pointSize - face.lineHeight)
      }
    }

    /// Tier 1: the 17 Flat 2b Library text styles, one constant per style
    /// in §6's ramp table.
    ///
    /// Named after the Library rather than by role — the §4 role-naming
    /// MUST governs tier 2, and only `DS.Font` reads these, exactly as
    /// `Colors.xcassets`' primitives are named after the Library variables
    /// while `DS.Color` names roles. Views use tier 2.
    ///
    /// **Text styles (§6, #629).** Each style takes the Apple text style
    /// whose *default* size is nearest its base size, so the Dynamic Type
    /// multiplier starts near 1. Every Display style is the exception: they
    /// all take `.largeTitle`, the flattest curve available.
    ///
    /// What `UIFontMetrics.scaledValue` does, measured on iOS 26.5: for a
    /// given (text style, content size category) it applies a *single*
    /// constant multiplier to any base size, quantised to 1/3 pt. That
    /// multiplier is **not** the ratio of the text style's own preferred
    /// sizes: `.largeTitle`'s own size goes 34 → 52 at AX3, a ratio of
    /// 1.53, while the multiplier it scales by is about 1.49. Measured at
    /// AX3, `.largeTitle` is about 1.49, `.body` about 2.18 and `.caption2`
    /// about 2.69 — the multiplier falls as the text style's own size
    /// rises, which is why `.largeTitle`, the largest text style, is the
    /// flattest curve available. So Display/60 reaches 89.33 pt at AX3 and
    /// 102.33 pt at AX5, where the same 60 pt on `.body`'s curve would
    /// reach 131.0 pt and 169.0 pt — sizes the layout §6 requires to
    /// survive AX3 would not take. The curve and the style's own size
    /// progression are different things; do not derive one from the other.
    enum Library {
      private static let displayFace = "BricolageGrotesque-ExtraBold"
      private static let titleFace = "DMSans-Bold"
      private static let bodyFace = "DMSans-Regular"
      private static let monoFace = "DMMono-Medium"

      /// `Display/60` — Home title "Events".
      static let display60 = Style(
        postScriptName: displayFace, size: 60, textStyle: .largeTitle,
        tracking: -0.02, lineHeight: 1.0
      )
      /// `Display/52` — onboarding titles.
      static let display52 = Style(
        postScriptName: displayFace, size: 52, textStyle: .largeTitle,
        tracking: -0.02, lineHeight: 1.0
      )
      /// `Display/46` — screen titles (event name, Session 1, Report #2).
      static let display46 = Style(
        postScriptName: displayFace, size: 46, textStyle: .largeTitle,
        tracking: -0.015, lineHeight: 1.0
      )
      /// `Display/Number 40` — sensing figures. The only style with
      /// monospaced digits: these are the numbers that change while
      /// someone is watching them, and proportional digits make the figure
      /// jitter sideways as it counts. DM Mono needs no such setting — it
      /// is already monospaced.
      static let displayNumber40 = Style(
        postScriptName: displayFace, size: 40, textStyle: .largeTitle,
        tracking: -0.01, usesMonospacedDigits: true
      )
      /// `Display/Address 34` — the Account sheet address (typeface still
      /// open: spec §10-5, #642).
      static let displayAddress34 = Style(
        postScriptName: displayFace, size: 34, textStyle: .largeTitle,
        tracking: -0.01
      )
      /// `Title/19` — section and state titles.
      static let title19 = Style(postScriptName: titleFace, size: 19, textStyle: .title3)
      /// `Title/17` — `Row/List` titles.
      static let title17 = Style(postScriptName: titleFace, size: 17, textStyle: .headline)
      /// `Title/16` — `Button/Primary` label.
      static let title16 = Style(postScriptName: titleFace, size: 16, textStyle: .callout)
      /// `Title/15` — `Row/KeyValue` values.
      static let title15 = Style(postScriptName: titleFace, size: 15, textStyle: .subheadline)
      /// `Body/15` — body copy.
      static let body15 = Style(
        postScriptName: bodyFace, size: 15, textStyle: .subheadline, lineHeight: 1.4
      )
      /// `Body/13` — supporting copy, metadata.
      static let body13 = Style(
        postScriptName: bodyFace, size: 13, textStyle: .footnote, lineHeight: 1.4
      )
      /// `Label/Mono 11` — section labels, nav, status.
      static let labelMono11 = Style(
        postScriptName: monoFace, size: 11, textStyle: .caption2,
        tracking: 0.08, isUppercase: true
      )
      /// `Label/Mono 10` — meta labels.
      static let labelMono10 = Style(
        postScriptName: monoFace, size: 10, textStyle: .caption2,
        tracking: 0.08, isUppercase: true
      )
      /// `Label/Mono 9` — the smallest labels.
      static let labelMono9 = Style(
        postScriptName: monoFace, size: 9, textStyle: .caption2,
        tracking: 0.06, isUppercase: true
      )
      /// `Label/Mono 10 tight` — in-row meta (IDs, session numbers). Not
      /// uppercased: it carries values, not labels — see `labelMono13Value`.
      static let labelMono10Tight = Style(
        postScriptName: monoFace, size: 10, textStyle: .caption2, tracking: 0.06
      )
      /// `Label/Mono 11 time` — times. Not uppercased, for the same reason
      /// as `labelMono13Value`.
      static let labelMono11Time = Style(
        postScriptName: monoFace, size: 11, textStyle: .caption2
      )
      /// `Label/Mono 13 value` — addresses, hashes, proof identifiers.
      ///
      /// The three value styles (this, `labelMono11Time`,
      /// `labelMono10Tight`) are deliberately *not* uppercased while the
      /// three label styles are. §6's uppercase MUST is about labels, and
      /// uppercasing a value here would be a correctness bug, not a style
      /// choice: an EIP-55 wallet address carries its checksum in the
      /// letter case of its hex digits, so `.uppercase` destroys it.
      static let labelMono13Value = Style(
        postScriptName: monoFace, size: 13, textStyle: .footnote
      )
    }

    // Tier 2: roles. Names and call sites are unchanged from the SF Pro
    // ramp — #629 re-points them at Flat 2b Library styles, so no View
    // changes. Tracking, line height and case are NOT carried by these:
    // a plain `.font(DS.Font.body)` call site gets family, size and
    // Dynamic Type only. The full style reaches a view through
    // `beidTextStyle(_:)`, which the screen issues adopt (§6).

    /// One per screen. Large screen title. `Display/46`.
    static let screenTitle = Library.display46.font
    /// Section and state titles (e.g. "Sensing automatically"). `Title/19`.
    static let sectionTitle = Library.title19.font
    /// Card and row titles (e.g. event name on a proof card). The Library's
    /// `Row/List` title, `Title/17`.
    static let cardTitle = Library.title17.font
    /// Body copy. `Body/15`.
    static let body = Library.body15.font
    /// Supporting copy under titles. `Body/13`.
    static let supporting = Library.body13.font
    /// Metadata: dates, counts, fine print. `Body/13`, deliberately the
    /// same style as `supporting` and deliberately *not* a mono label
    /// style: the Library's mono labels are uppercase, and today's 44
    /// `meta` call sites carry sentence-case copy that #629 does not
    /// re-author. A mono meta role belongs with the screen work.
    static let meta = Library.body13.font
    /// Ledger traces: wallet addresses, hashes, proof identifiers.
    /// `Label/Mono 13 value`.
    static let ledgerMono = Library.labelMono13Value.font
    /// Primary CTA label. The Library's `Button/Primary` label, `Title/16`.
    static let cta = Library.title16.font
  }

  // MARK: - Motion
  //
  // Spring-first. Damping 1.0 (no overshoot) is the default; overshoot is
  // reserved for momentum/ceremony moments. See DESIGN.md §9.
  enum Motion {
    /// Immediate feedback: press states, small toggles.
    static let fast = Animation.spring(response: 0.25, dampingFraction: 1.0)
    /// Default UI transition.
    static let standard = Animation.spring(response: 0.35, dampingFraction: 1.0)
    /// Content entering the screen (e.g. event card slide-in on EventFoundView).
    static let entrance = Animation.spring(response: 0.5, dampingFraction: 0.85)
    /// Transition between top-level screens (RootView, ScanFlowView).
    static let screenTransition = Animation.spring(response: 0.36, dampingFraction: 0.88)
    /// The proof seal/resolve ceremony (RecordingView's one-time entrance
    /// ceremony fading into its steady state).
    static let proofResolve = Animation.spring(response: 0.6, dampingFraction: 0.8)
    /// Period of one sensing radar pulse cycle (SensingView).
    static let sensingPulsePeriod: TimeInterval = 1.8
    /// The sanctioned sensing-pulse animation (one ring's expand+fade,
    /// repeating). Views use this token; per-ring stagger MAY add
    /// `.delay(_:)` derived from `sensingPulsePeriod`.
    static let sensingPulse = Animation
      .easeOut(duration: sensingPulsePeriod)
      .repeatForever(autoreverses: false)
  }

  // MARK: - Artwork
  //
  // Data-driven artwork generators. Raw color construction is allowed here
  // and nowhere else. See DESIGN.md §5.
  enum Artwork {
    /// Per-proof Event Artifact gradient, derived from `Proof.gradientSeed`.
    /// The only sanctioned source of `Color(hue:)` in the app.
    static func proofCardGradient(seed: Int) -> LinearGradient {
      let hue = Double(seed.magnitude % 360) / 360.0
      return LinearGradient(
        colors: [
          SwiftUI.Color(hue: hue, saturation: 0.6, brightness: 0.9),
          SwiftUI.Color(
            hue: (hue + 0.12).truncatingRemainder(dividingBy: 1),
            saturation: 0.7,
            brightness: 0.75
          ),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
    }
  }
}

extension View {
  /// The one sanctioned way to apply a whole Flat 2b text style: the face
  /// and its Dynamic Type curve, plus the tracking, line height and case
  /// §6's ramp table records for it. Named for `beidSurface`, the same
  /// "this modifier owns the whole treatment" contract.
  ///
  /// `.font(DS.Font.someRole)` remains valid and is what today's call sites
  /// do; it carries family, size and Dynamic Type but none of the three
  /// settings above. Prefer this modifier when a screen is being built to
  /// the Library.
  ///
  /// Line height is applied as `lineSpacing`, which is additive, so a
  /// Library line height *below* the face's own is not applied — see
  /// `DS.Font.Style.lineSpacing(atPointSize:)` and §6's line-height gap.
  /// Tracking and line height scale with Dynamic Type: both are computed
  /// at the scaled point size, not the base size.
  func beidTextStyle(_ style: DS.Font.Style) -> some View {
    modifier(BeidTextStyleModifier(style: style))
  }
}

/// Applies a `DS.Font.Style` in full. Separate from the `View` extension
/// because `@ScaledMetric` needs a stored property to track the content
/// size category, and its text style is only known per style.
private struct BeidTextStyleModifier: ViewModifier {
  private let style: DS.Font.Style
  /// `style.size` after Dynamic Type, on `style.textStyle`'s curve — the
  /// same curve `Font.custom(_:size:relativeTo:)` scales the face on, so
  /// tracking and line spacing stay in proportion to the rendered text.
  @ScaledMetric private var scaledSize: CGFloat

  init(style: DS.Font.Style) {
    self.style = style
    _scaledSize = ScaledMetric(wrappedValue: style.size, relativeTo: style.textStyle)
  }

  func body(content: Content) -> some View {
    content
      .font(style.font)
      .tracking(style.tracking(atPointSize: scaledSize))
      .lineSpacing(style.lineSpacing(atPointSize: scaledSize))
      .textCase(style.isUppercase ? .uppercase : nil)
  }
}
