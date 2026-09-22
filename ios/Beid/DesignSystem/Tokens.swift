// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import SwiftUI

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
  // System font (SF Pro) ramp, Dynamic Type compatible. `Font.system` is
  // allowed here and nowhere else. See DESIGN.md §6.
  enum Font {
    /// One per screen. Large screen title.
    static let screenTitle = SwiftUI.Font.system(.largeTitle, weight: .bold)
    /// Ceremony moments: Verified, Proof Collected.
    static let ceremonyTitle = SwiftUI.Font.system(.title, weight: .bold)
    /// Section and state titles (e.g. "Sensing automatically").
    static let sectionTitle = SwiftUI.Font.system(.title3, weight: .semibold)
    /// Card titles (e.g. event name on a proof card).
    static let cardTitle = SwiftUI.Font.system(.subheadline, weight: .semibold)
    /// Body copy.
    static let body = SwiftUI.Font.system(.body)
    /// Supporting copy under titles.
    static let supporting = SwiftUI.Font.system(.subheadline)
    /// Metadata: dates, counts, fine print.
    static let meta = SwiftUI.Font.system(.caption)
    /// Ledger traces: wallet addresses, hashes, proof identifiers.
    static let ledgerMono = SwiftUI.Font.system(.footnote, design: .monospaced)
    /// Primary CTA label.
    static let cta = SwiftUI.Font.system(.headline)
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
