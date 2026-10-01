// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import BeidSharedKit
import SwiftUI

/// The Proof 紋様 (Sigil) drawing component (beid#633).
///
/// Ownership. `shared/`'s `BeidSharedKit.sigil.layoutSigil` owns *every*
/// number: angles, radii, stroke widths, the full/mini variant choice, the
/// ring count, and the draw order. This file owns only two things the shared
/// layer deliberately does not: which `DS.Color` token paints a mark, and the
/// SwiftUI calls that put it on screen. There is therefore no arithmetic on
/// any coordinate, radius or width anywhere below — `CGFloat(_:)` /
/// `Double(_:)` conversion is the only thing that touches a layout number.
/// If a future change needs a geometry value here, it belongs in
/// `SigilLayout.kt` instead (see that file's "Ownership" paragraph).
///
/// Wired by beid#653 through `RecordSigilSlot`, which draws a record's own
/// stored presence (or the live session's, on frame 04's active card) and
/// keeps the neutral ring for a record without data. The previews at the
/// bottom document the contexts #633 names, from fixture input only.

// MARK: - Ink roles

/// The palette role a Sigil mark is painted with.
///
/// Two roles, because DESIGN.md §5 gives the Sigil exactly two grounds to sit
/// on: `ink` is "Text, primary button fill, black-screen ground, Sigil" and
/// `bg` is "Screen ground; text and Sigil on `ink`". A Sigil on the filled
/// ink disc is drawn in `bg`; everywhere else it is drawn in `ink`.
enum SigilInkRole: Equatable {
  /// Library `ink` — `DS.Color.textPrimary`. Marks on the page ground, and
  /// the ground disc/outline itself.
  case ink
  /// Library `bg` — `DS.Color.surfaceCanvas`. Marks sitting *on* the filled
  /// ink disc.
  case onInk

  var color: Color {
    switch self {
    case .ink: return DS.Color.textPrimary
    case .onInk: return DS.Color.surfaceCanvas
    }
  }
}

/// The page a Sigil sits on (beid#653 OD-6). Frames 04 (the active card)
/// and 06 put a Sigil with no ground on an ink page; its marks must then be
/// `bg`, or they would be ink on ink. A color decision only: the page moves
/// no geometry.
enum SigilPage: Equatable {
  case canvas
  case ink
}

// MARK: - Draw commands

/// The drawing operation one `SigilPrimitive` needs.
///
/// Not a geometry decision: `SigilPrimitiveKind`'s own documentation in
/// `SigilLayout.kt` states each kind's shape ("Filled circle", "Stroked
/// circle", "Segment"). This transcribes that statement.
enum SigilMarkShape: Equatable {
  case filledCircle
  case strokedCircle
  case segment
}

/// One primitive, transported into SwiftUI terms. Carries no kind: by this
/// point the kind has already decided the shape and the role, and nothing
/// downstream may branch on it again.
enum SigilDrawCommand: Equatable {
  case fill(center: CGPoint, radius: CGFloat, role: SigilInkRole)
  case strokeCircle(center: CGPoint, radius: CGFloat, lineWidth: CGFloat, role: SigilInkRole)
  case strokeLine(from: CGPoint, to: CGPoint, lineWidth: CGFloat, role: SigilInkRole)
}

/// The pure half of the component: shared layout in, ordered draw commands
/// out. Separated from `BeidSigilView` so the mapping is testable without a
/// renderer, which is what `SigilViewTests` pins.
enum SigilDrawing {

  /// Swift Export represents a Kotlin enum as a class of static members, not
  /// a native `enum`, so this compares by value (`==`) rather than
  /// `switch`-pattern-matching — the same idiom as
  /// `SensingCoordinator.payloadlessNativePhase`. That also means there is no
  /// exhaustiveness check from the compiler, so an unrecognized kind returns
  /// `nil` and is dropped rather than guessed at;
  /// `SigilViewTests.testEveryPrimitiveKindMapsToAShape` is what keeps a new
  /// kind from silently disappearing.
  static func markShape(for kind: BeidSharedKit.sigil.SigilPrimitiveKind) -> SigilMarkShape? {
    if kind == .GROUND_DISC { return .filledCircle }
    if kind == .GROUND_OUTLINE { return .strokedCircle }
    if kind == .RING { return .strokedCircle }
    if kind == .DETECTED_LINE { return .segment }
    if kind == .MUTUAL_LINE { return .segment }
    if kind == .DETECTED_DOT { return .filledCircle }
    if kind == .MUTUAL_DOT { return .filledCircle }
    if kind == .CENTER_DOT { return .filledCircle }
    return nil
  }

  /// The ground itself is always `ink`. A mark is `bg` when it sits on ink
  /// (the filled disc, or an ink page), and `ink` otherwise (DESIGN.md §5:
  /// "text and Sigil on `ink`" use `bg`). Returns `nil` for an unrecognized
  /// kind, for the reason given on `markShape`.
  static func inkRole(
    for kind: BeidSharedKit.sigil.SigilPrimitiveKind,
    ground: BeidSharedKit.sigil.SigilGround,
    page: SigilPage = .canvas
  ) -> SigilInkRole? {
    if kind == .GROUND_DISC || kind == .GROUND_OUTLINE {
      return .ink
    }
    if kind == .RING || kind == .DETECTED_LINE || kind == .MUTUAL_LINE
      || kind == .DETECTED_DOT || kind == .MUTUAL_DOT || kind == .CENTER_DOT {
      return ground == .DISC || page == .ink ? .onInk : .ink
    }
    return nil
  }

  /// Walks `primitiveAt` in index order and emits exactly one command per
  /// primitive.
  ///
  /// The order is the draw order and it is load-bearing: `layoutSigil`'s
  /// doc comment explains that every mutual layer is emitted after its
  /// detected counterpart precisely so a mutual mark is never painted over by
  /// a detected-only one. Never sort, group or de-duplicate this.
  ///
  /// A failed layout (`isSuccess` false — e.g. a size under the shared
  /// minimum) has nothing to draw and yields no commands.
  static func commands(
    for layout: BeidSharedKit.sigil.SigilLayout,
    ground: BeidSharedKit.sigil.SigilGround,
    page: SigilPage = .canvas
  ) -> [SigilDrawCommand] {
    guard layout.isSuccess else { return [] }

    var commands: [SigilDrawCommand] = []
    commands.reserveCapacity(Int(layout.primitiveCount))

    for index in 0..<Int(layout.primitiveCount) {
      guard let primitive = layout.primitiveAt(index: Int32(index)),
        let shape = markShape(for: primitive.kind),
        let role = inkRole(for: primitive.kind, ground: ground, page: page)
      else { continue }

      switch shape {
      case .filledCircle:
        commands.append(
          .fill(
            center: CGPoint(x: primitive.x, y: primitive.y),
            radius: CGFloat(primitive.radius),
            role: role
          )
        )
      case .strokedCircle:
        commands.append(
          .strokeCircle(
            center: CGPoint(x: primitive.x, y: primitive.y),
            radius: CGFloat(primitive.radius),
            lineWidth: CGFloat(primitive.lineWidth),
            role: role
          )
        )
      case .segment:
        commands.append(
          .strokeLine(
            from: CGPoint(x: primitive.x, y: primitive.y),
            to: CGPoint(x: primitive.x2, y: primitive.y2),
            lineWidth: CGFloat(primitive.lineWidth),
            role: role
          )
        )
      }
    }

    return commands
  }

  /// VoiceOver summary for one Sigil.
  ///
  /// DESIGN.md §13 (Flat 2b spec §9) makes this a MUST and names #633: a
  /// Sigil carries information, not decoration, so it carries a spoken
  /// summary — the section's own example shape is
  /// "7 mutual, 13 detected, window 6". This implements that shape from the
  /// three counts `SigilLayout` exports for it.
  ///
  /// Kept as one small pure function so the summary's source can be changed
  /// in a single place.
  static func accessibilitySummary(for layout: BeidSharedKit.sigil.SigilLayout) -> String {
    let mutualPeers = Int(layout.mutualPeerCount)
    let detectedPeers = Int(layout.detectedPeerCount)
    let windows = Int(layout.windowCount)
    return String(
      localized: "sigil.accessibilitySummary",
      defaultValue: "\(mutualPeers) mutual, \(detectedPeers) detected, window \(windows)",
      comment: "VoiceOver summary spoken in place of the Proof Sigil, the generated circular mark on a proof. It replaces the whole drawing, so it is the only thing a VoiceOver user gets — keep all three numbers. The first number counts nearby people's devices whose presence was mutual (both devices confirmed each other); the second counts devices this device merely detected, without that confirmation; the two never overlap and together they are every device drawn. The third is how many time windows the whole mark spans, not a position or an index into them — \"window\" is the unit of recorded time, roughly a few seconds each, and is not a GUI window. On current builds the first number is always 0, because mutual confirmation is not measurable on the device yet and this project deliberately shows 0 rather than guessing; translate it as a real count of zero, never as \"unknown\" or \"not available\"."
    )
  }

  /// Whether VoiceOver should skip the Sigil entirely.
  ///
  /// A failed layout (`isSuccess` false) draws nothing, so there is no mark
  /// for a summary to stand in for. Speaking one anyway announces
  /// "0 mutual, 0 detected, window 0" over an empty square, and a VoiceOver
  /// user has no way to tell that apart from a real all-zero proof: it
  /// states something false about their own data rather than merely
  /// omitting it. An element that drew nothing is skipped instead.
  ///
  /// Pure, and separate from the modifier, for the same reason as the rest
  /// of `SigilDrawing` — plus one specific to accessibility: a modifier on a
  /// `View` cannot be read back in XCTest without a view-inspection library,
  /// which this repository does not have. As a function the decision can be
  /// pinned by a test; inlined in the modifier it could not be.
  static func isAccessibilityHidden(for layout: BeidSharedKit.sigil.SigilLayout) -> Bool {
    !layout.isSuccess
  }

  /// A closed circle at a centre and radius, built with `addArc` rather than
  /// `Path(ellipseIn:)` because the arc API takes the centre and the radius
  /// as they already arrive from `SigilPrimitive` — a rect would mean
  /// subtracting the radius from the centre, which is exactly the coordinate
  /// arithmetic this layer must not contain.
  private static func circlePath(center: CGPoint, radius: CGFloat) -> Path {
    var path = Path()
    path.addArc(
      center: center,
      radius: radius,
      startAngle: .zero,
      endAngle: .degrees(360),
      clockwise: false
    )
    return path
  }

  /// Renders one command. Strokes use the default butt cap deliberately: a
  /// round cap would extend a segment half its width past each endpoint, and
  /// the endpoints are the layout's, not this layer's, to move.
  fileprivate static func draw(_ command: SigilDrawCommand, into context: inout GraphicsContext) {
    switch command {
    case let .fill(center, radius, role):
      context.fill(circlePath(center: center, radius: radius), with: .color(role.color))
    case let .strokeCircle(center, radius, lineWidth, role):
      context.stroke(
        circlePath(center: center, radius: radius),
        with: .color(role.color),
        lineWidth: lineWidth
      )
    case let .strokeLine(from, to, lineWidth, role):
      var path = Path()
      path.move(to: from)
      path.addLine(to: to)
      context.stroke(path, with: .color(role.color), lineWidth: lineWidth)
    }
  }
}

// MARK: - View

/// Draws one Sigil.
///
/// One view for every context, including the mini. The mini is not a second
/// renderer: `layoutSigil` already decided the variant from `size` (its
/// `isMini`) and already returned a different primitive list, so this view
/// never asks how big it is. A size branch here would be a geometry decision
/// and is forbidden.
///
/// The view takes the *input* rather than a layout and calls `layoutSigil`
/// itself, so the geometry it draws and the frame it occupies can never
/// disagree about `size`.
struct BeidSigilView: View {
  let input: BeidSharedKit.sigil.SigilInput
  let size: CGFloat
  let ground: BeidSharedKit.sigil.SigilGround
  /// The page under the Sigil; decides mark color only (`SigilPage`).
  var page: SigilPage = .canvas

  var body: some View {
    let layout = BeidSharedKit.sigil.layoutSigil(
      input: input,
      size: Double(size),
      ground: ground
    )
    let commands = SigilDrawing.commands(for: layout, ground: ground, page: page)

    Canvas { context, _ in
      for command in commands {
        SigilDrawing.draw(command, into: &context)
      }
    }
    .frame(width: size, height: size)
    .accessibilityElement()
    .accessibilityLabel(Text(SigilDrawing.accessibilitySummary(for: layout)))
    .accessibilityHidden(SigilDrawing.isAccessibilityHidden(for: layout))
  }
}

// MARK: - Preview fixtures

/// Preview-only helper, built through the same shared calls production code
/// would use rather than a hand-rolled stand-in — the same arrangement, and
/// the same reason, as `PreviewAggregateFactory`.
///
/// Fixture data only. Presence 2 (mutual) does not exist on the device today
/// (DECISIONS 2026-08-09, 2026-09-23), so a preview is the only place the
/// mutual marks can be seen at all; nothing production reads this.
///
/// Named without "demo" or "scenario" so it stays outside the source walk in
/// `ParticipantRelayIsolationTests`, which is scoped to those on purpose.
enum SigilPreviewInputFactory {
  static var sample: BeidSharedKit.sigil.SigilInput {
    let windowCount: Int32 = 12
    let peerCount: Int32 = 9
    let input = BeidSharedKit.sigil.createSigilInput(windowCount: windowCount)
    for peer in 0..<peerCount {
      for window in 0..<windowCount where (peer + window) % 3 != 0 {
        _ = BeidSharedKit.sigil.addSigilPresence(
          input: input,
          peerKey: "preview-peer-\(peer)",
          windowIndex: window,
          presence: (peer + window) % 4 == 0 ? 2 : 1
        )
      }
    }
    return input
  }
}

// MARK: - Previews
//
// The five contexts issue #633 names. Documentation of the contexts only —
// none of these is wiring; production screens draw through `RecordSigilSlot`
// and `RecordSigilPlacement` (beid#653). The sizes here come from #633 and are
// illustrative; the measured ones live in `RecordSigilPlacement`.

#Preview("Proof Collected — 290, disc") {
  BeidSigilView(input: SigilPreviewInputFactory.sample, size: 290, ground: .DISC)
    .padding()
}

#Preview("Proof Detail — 240, disc") {
  BeidSigilView(input: SigilPreviewInputFactory.sample, size: 240, ground: .DISC)
    .padding()
}

#Preview("Welcome hero — outline, line art") {
  BeidSigilView(input: SigilPreviewInputFactory.sample, size: 200, ground: .OUTLINE)
    .padding()
}

#Preview("Sensing verified — no ground") {
  BeidSigilView(input: SigilPreviewInputFactory.sample, size: 200, ground: .NONE)
    .padding()
}

#Preview("Mini — 60, no ground") {
  BeidSigilView(input: SigilPreviewInputFactory.sample, size: 60, ground: .NONE)
    .padding()
}
