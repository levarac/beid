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
  // Values live in Colors.xcassets as adaptive (light + dark) sets and are
  // exposed via Xcode's generated asset symbols. Semantic roles and hex
  // anchors are documented in DESIGN.md §5.
  enum Color {
    /// Root background of every screen.
    static let surfaceCanvas = SwiftUI.Color(.surfaceCanvas)
    /// Card and sheet surfaces sitting on the canvas.
    static let surfaceRaised = SwiftUI.Color(.surfaceRaised)
    /// Primary text.
    static let textPrimary = SwiftUI.Color(.textPrimary)
    /// Secondary/supporting text.
    static let textSecondary = SwiftUI.Color(.textSecondary)
    /// Neutral primary action. CTA tint on screens that have no motif
    /// accent; also the intended app-level accent once views migrate.
    static let actionPrimary = SwiftUI.Color(.actionPrimary)
    /// Live sensing signal. The single accent of sensing screens
    /// (SensingView, EventFoundView, VerifyingView) — DESIGN.md §5 map.
    static let signalActive = SwiftUI.Color(.signalActive)
    /// Degraded/lost signal. The single accent of recovery screens
    /// (SignalLostView, BluetoothOffView); not for generic warnings.
    static let signalWarning = SwiftUI.Color(.signalWarning)
    /// Verified proof artifacts: seals, seal success, ceremony moments.
    static let proofSeal = SwiftUI.Color(.proofSeal)
    /// Hairline strokes and dividers.
    static let strokeHairline = SwiftUI.Color(.strokeHairline)
  }

  // MARK: - Space
  //
  // 4 pt base scale. See DESIGN.md §7.
  enum Space {
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 16
    static let l: CGFloat = 24
    static let xl: CGFloat = 32
    static let xxl: CGFloat = 48
    /// Default horizontal page margin for full-width content and CTAs.
    static let pageMargin: CGFloat = 32
  }

  // MARK: - Radius
  //
  // See DESIGN.md §8.
  enum Radius {
    /// Small controls and inline chips.
    static let control: CGFloat = 12
    /// Standard cards (proof cards, event cards).
    static let card: CGFloat = 16
    /// Proof seal artwork and ceremony surfaces.
    static let seal: CGFloat = 28
    /// Fully rounded pills.
    static let pill: CGFloat = 999
  }

  // MARK: - Size
  enum Size {
    /// HIG minimum hit region for interactive elements.
    static let minHitTarget: CGFloat = 44
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
    /// The proof seal/resolve ceremony (VerifiedView → ProofCollectedView).
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
