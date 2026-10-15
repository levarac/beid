// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import BeidSharedKit
import SwiftUI
import XCTest
@testable import Beid

/// Pins the mapping from `BeidSharedKit.sigil`'s layout output to the draw
/// commands `BeidSigilView` renders (beid#633).
///
/// What this file is for: `SigilLayoutTest` (Kotlin) already pins every
/// number the Sigil is made of. Nothing pinned the *transport* — that iOS
/// emits one command per primitive, in the layout's order, carrying the
/// layout's own coordinates rather than anything re-derived in Swift. That is
/// the regression this file prevents, and it is the evidence for #633's
/// acceptance criterion "no geometry decisions in the iOS layer": every
/// number asserted below is read back out of the layout, never written as a
/// literal here.
///
/// The presence-2 (mutual) cases matter disproportionately. Mutual data does
/// not exist on the device today — presence is not persisted per peer per
/// window and `mutual` is always false (DECISIONS 2026-08-09, 2026-09-23) —
/// so feeding presence 2 straight into `addSigilPresence` is the only thing
/// protecting the mutual drawing path from silently rotting before beid#653
/// supplies it for real.
@MainActor
final class SigilViewTests: XCTestCase {

  // MARK: - Fixtures

  /// `(peerKey, windowIndex, presence)`, the same tuple shape
  /// `SigilLayoutTest` uses.
  private typealias Entry = (key: String, window: Int32, presence: Int32)

  private func makeInput(
    windowCount: Int32,
    _ entries: [Entry],
    file: StaticString = #filePath,
    line: UInt = #line
  ) -> BeidSharedKit.sigil.SigilInput {
    let input = BeidSharedKit.sigil.createSigilInput(windowCount: windowCount)
    for entry in entries {
      XCTAssertTrue(
        BeidSharedKit.sigil.addSigilPresence(
          input: input,
          peerKey: entry.key,
          windowIndex: entry.window,
          presence: entry.presence
        ),
        "rejected \(entry.key)/\(entry.window)/\(entry.presence)",
        file: file,
        line: line
      )
    }
    return input
  }

  /// A mixed input: three peers, four windows, both presences, so the full
  /// variant emits all six mark kinds and the mini emits both of its own.
  private static let mixedEntries: [Entry] = [
    (key: "peer-a", window: 0, presence: 2),
    (key: "peer-a", window: 1, presence: 2),
    (key: "peer-a", window: 2, presence: 1),
    (key: "peer-b", window: 1, presence: 1),
    (key: "peer-b", window: 2, presence: 1),
    (key: "peer-b", window: 3, presence: 2),
    (key: "peer-c", window: 0, presence: 1),
    (key: "peer-c", window: 3, presence: 2),
  ]

  private static let allKinds: [BeidSharedKit.sigil.SigilPrimitiveKind] = [
    .GROUND_DISC, .GROUND_OUTLINE, .RING, .DETECTED_LINE,
    .MUTUAL_LINE, .DETECTED_DOT, .MUTUAL_DOT, .CENTER_DOT,
  ]

  private static let allGrounds: [BeidSharedKit.sigil.SigilGround] = [.DISC, .OUTLINE, .NONE]

  /// A full-variant size and a mini-variant size. Which variant each produces
  /// is asserted through `layout.isMini` rather than assumed — the threshold
  /// is `shared/`'s and is deliberately not visible here.
  private static let fullSize: Double = 200
  private static let miniSize: Double = 60

  // MARK: - Command inspection helpers

  private func fills(_ commands: [SigilDrawCommand]) -> [(center: CGPoint, radius: CGFloat, role: SigilInkRole)] {
    commands.compactMap {
      guard case let .fill(center, radius, role) = $0 else { return nil }
      return (center, radius, role)
    }
  }

  private func strokeCircles(
    _ commands: [SigilDrawCommand]
  ) -> [(center: CGPoint, radius: CGFloat, lineWidth: CGFloat, role: SigilInkRole)] {
    commands.compactMap {
      guard case let .strokeCircle(center, radius, lineWidth, role) = $0 else { return nil }
      return (center, radius, lineWidth, role)
    }
  }

  private func strokeLines(
    _ commands: [SigilDrawCommand]
  ) -> [(from: CGPoint, to: CGPoint, lineWidth: CGFloat, role: SigilInkRole)] {
    commands.compactMap {
      guard case let .strokeLine(from, to, lineWidth, role) = $0 else { return nil }
      return (from, to, lineWidth, role)
    }
  }

  /// Counts primitives of one kind. Written as a loop rather than a `filter`
  /// over optionals because Swift Export exposes a Kotlin enum as a class of
  /// static members, so only a non-optional `==` between two of them is
  /// guaranteed to be available.
  private func count(
    of kind: BeidSharedKit.sigil.SigilPrimitiveKind,
    in layout: BeidSharedKit.sigil.SigilLayout
  ) -> Int {
    var total = 0
    for index in 0..<Int(layout.primitiveCount) {
      guard let primitive = layout.primitiveAt(index: Int32(index)) else { continue }
      if primitive.kind == kind {
        total += 1
      }
    }
    return total
  }

  // MARK: - The core assertion

  /// Every command's numbers, shape, role and position come from the layout.
  ///
  /// This is the file's central claim and the one that proves criterion 3: if
  /// any coordinate, radius or width were computed in Swift rather than
  /// transported, the exact comparisons below would fail. They are exact, not
  /// approximate, on purpose — a transport performs no arithmetic, so there
  /// is no rounding to tolerate.
  private func assertCommandsMatchLayout(
    _ commands: [SigilDrawCommand],
    _ layout: BeidSharedKit.sigil.SigilLayout,
    ground: BeidSharedKit.sigil.SigilGround,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertTrue(layout.isSuccess, "layout failed: \(layout.errorCode ?? "nil")", file: file, line: line)
    XCTAssertEqual(
      commands.count,
      Int(layout.primitiveCount),
      "exactly one command per primitive",
      file: file,
      line: line
    )
    guard commands.count == Int(layout.primitiveCount) else { return }

    for index in 0..<commands.count {
      guard let primitive = layout.primitiveAt(index: Int32(index)) else {
        XCTFail("no primitive at \(index)", file: file, line: line)
        return
      }
      guard let expectedShape = SigilDrawing.markShape(for: primitive.kind) else {
        XCTFail("primitive \(index) has a kind that maps to no shape", file: file, line: line)
        return
      }
      guard let expectedRole = SigilDrawing.inkRole(for: primitive.kind, ground: ground) else {
        XCTFail("primitive \(index) has a kind that maps to no ink role", file: file, line: line)
        return
      }

      switch commands[index] {
      case let .fill(center, radius, role):
        XCTAssertEqual(expectedShape, .filledCircle, "[\(index)] shape", file: file, line: line)
        XCTAssertEqual(center.x, CGFloat(primitive.x), "[\(index)] x", file: file, line: line)
        XCTAssertEqual(center.y, CGFloat(primitive.y), "[\(index)] y", file: file, line: line)
        XCTAssertEqual(radius, CGFloat(primitive.radius), "[\(index)] radius", file: file, line: line)
        XCTAssertEqual(role, expectedRole, "[\(index)] role", file: file, line: line)
      case let .strokeCircle(center, radius, lineWidth, role):
        XCTAssertEqual(expectedShape, .strokedCircle, "[\(index)] shape", file: file, line: line)
        XCTAssertEqual(center.x, CGFloat(primitive.x), "[\(index)] x", file: file, line: line)
        XCTAssertEqual(center.y, CGFloat(primitive.y), "[\(index)] y", file: file, line: line)
        XCTAssertEqual(radius, CGFloat(primitive.radius), "[\(index)] radius", file: file, line: line)
        XCTAssertEqual(lineWidth, CGFloat(primitive.lineWidth), "[\(index)] lineWidth", file: file, line: line)
        XCTAssertEqual(role, expectedRole, "[\(index)] role", file: file, line: line)
      case let .strokeLine(from, to, lineWidth, role):
        XCTAssertEqual(expectedShape, .segment, "[\(index)] shape", file: file, line: line)
        XCTAssertEqual(from.x, CGFloat(primitive.x), "[\(index)] from.x", file: file, line: line)
        XCTAssertEqual(from.y, CGFloat(primitive.y), "[\(index)] from.y", file: file, line: line)
        XCTAssertEqual(to.x, CGFloat(primitive.x2), "[\(index)] to.x", file: file, line: line)
        XCTAssertEqual(to.y, CGFloat(primitive.y2), "[\(index)] to.y", file: file, line: line)
        XCTAssertEqual(lineWidth, CGFloat(primitive.lineWidth), "[\(index)] lineWidth", file: file, line: line)
        XCTAssertEqual(role, expectedRole, "[\(index)] role", file: file, line: line)
      }
    }
  }

  // MARK: - AC1: determinism

  /// Same input, same drawing — and insertion order must not reach the
  /// output. `SigilLayout`'s invariant 2 makes the shared side order-
  /// independent; this pins that the Swift transport does not reintroduce an
  /// order dependency of its own (a dictionary walk, a sort, a set).
  func testIdenticalInputsBuiltInDifferentOrdersProduceIdenticalCommands() {
    for ground in Self.allGrounds {
      for size in [Self.fullSize, Self.miniSize] {
        let forward = makeInput(windowCount: 4, Self.mixedEntries)
        let reversed = makeInput(windowCount: 4, Array(Self.mixedEntries.reversed()))

        let first = SigilDrawing.commands(
          for: BeidSharedKit.sigil.layoutSigil(input: forward, size: size, ground: ground),
          ground: ground
        )
        let second = SigilDrawing.commands(
          for: BeidSharedKit.sigil.layoutSigil(input: reversed, size: size, ground: ground),
          ground: ground
        )

        XCTAssertFalse(first.isEmpty, "size \(size)")
        XCTAssertEqual(first, second, "size \(size)")
      }
    }
  }

  // MARK: - AC3 / AC4: every number comes from the layout, in order

  func testEveryCommandCarriesTheLayoutsOwnNumbersInOrder() {
    for ground in Self.allGrounds {
      for size in [Self.fullSize, Self.miniSize] {
        let layout = BeidSharedKit.sigil.layoutSigil(
          input: makeInput(windowCount: 4, Self.mixedEntries),
          size: size,
          ground: ground
        )
        assertCommandsMatchLayout(
          SigilDrawing.commands(for: layout, ground: ground),
          layout,
          ground: ground
        )
      }
    }
  }

  /// The draw order is load-bearing: `layoutSigil` emits every mutual layer
  /// after its detected counterpart so a mutual mark is never painted over by
  /// a detected-only one. A transport that sorted, grouped or de-duplicated
  /// would lose that, and would not be caught by any per-command assertion.
  func testCommandOrderIsThePrimitiveOrderOneForOne() {
    let ground = BeidSharedKit.sigil.SigilGround.DISC
    let layout = BeidSharedKit.sigil.layoutSigil(
      input: makeInput(windowCount: 4, Self.mixedEntries),
      size: Self.fullSize,
      ground: ground
    )
    let commands = SigilDrawing.commands(for: layout, ground: ground)

    XCTAssertEqual(commands.count, Int(layout.primitiveCount))
    // Fixed against the golden full-variant layout in SigilLayoutTest:
    // ground, rings, detected lines, mutual lines, detected dots, mutual
    // dots, centre. Read back from the layout rather than written out here.
    var shapes: [SigilMarkShape] = []
    for index in 0..<Int(layout.primitiveCount) {
      guard let primitive = layout.primitiveAt(index: Int32(index)) else {
        return XCTFail("no primitive at \(index)")
      }
      guard let shape = SigilDrawing.markShape(for: primitive.kind) else {
        return XCTFail("unmapped kind at \(index)")
      }
      shapes.append(shape)
    }
    XCTAssertEqual(
      commands.map {
        switch $0 {
        case .fill: return SigilMarkShape.filledCircle
        case .strokeCircle: return SigilMarkShape.strokedCircle
        case .strokeLine: return SigilMarkShape.segment
        }
      },
      shapes
    )
  }

  // MARK: - Kind mapping

  /// Swift Export gives no exhaustive `switch` over a Kotlin enum, so the
  /// shape and role maps end in a `nil` fallback. This is the test that makes
  /// that fallback loud: a ninth kind added to `SigilPrimitiveKind`, or a
  /// kind dropped from either map, fails here instead of silently vanishing
  /// from the drawing.
  func testEveryPrimitiveKindMapsToAShape() {
    let expected: [(kind: BeidSharedKit.sigil.SigilPrimitiveKind, shape: SigilMarkShape)] = [
      (.GROUND_DISC, .filledCircle),
      (.GROUND_OUTLINE, .strokedCircle),
      (.RING, .strokedCircle),
      (.DETECTED_LINE, .segment),
      (.MUTUAL_LINE, .segment),
      (.DETECTED_DOT, .filledCircle),
      (.MUTUAL_DOT, .filledCircle),
      (.CENTER_DOT, .filledCircle),
    ]
    XCTAssertEqual(expected.count, Self.allKinds.count)
    for (kind, shape) in expected {
      XCTAssertEqual(SigilDrawing.markShape(for: kind), shape)
    }
  }

  /// DESIGN.md §5: `ink` is "Text, primary button fill, black-screen ground,
  /// Sigil"; `bg` is "Screen ground; text and Sigil on `ink`". So the ground
  /// itself is always ink, and a mark is bg exactly when it sits on the
  /// filled ink disc.
  func testEveryPrimitiveKindMapsToAnInkRoleOnEveryGround() {
    for ground in Self.allGrounds {
      for kind in Self.allKinds {
        XCTAssertNotNil(SigilDrawing.inkRole(for: kind, ground: ground))
      }
      XCTAssertEqual(SigilDrawing.inkRole(for: .GROUND_DISC, ground: ground), .ink)
      XCTAssertEqual(SigilDrawing.inkRole(for: .GROUND_OUTLINE, ground: ground), .ink)
    }

    let markKinds: [BeidSharedKit.sigil.SigilPrimitiveKind] = [
      .RING, .DETECTED_LINE, .MUTUAL_LINE, .DETECTED_DOT, .MUTUAL_DOT, .CENTER_DOT,
    ]
    for kind in markKinds {
      XCTAssertEqual(SigilDrawing.inkRole(for: kind, ground: .DISC), .onInk)
      XCTAssertEqual(SigilDrawing.inkRole(for: kind, ground: .OUTLINE), .ink)
      XCTAssertEqual(SigilDrawing.inkRole(for: kind, ground: .NONE), .ink)
    }
  }

  // MARK: - Grounds

  func testDiscGroundLeadsWithAFilledInkDiscAndPaintsItsMarksInBg() {
    let ground = BeidSharedKit.sigil.SigilGround.DISC
    let layout = BeidSharedKit.sigil.layoutSigil(
      input: makeInput(windowCount: 4, Self.mixedEntries),
      size: Self.fullSize,
      ground: ground
    )
    let commands = SigilDrawing.commands(for: layout, ground: ground)

    XCTAssertEqual(count(of: .GROUND_DISC, in: layout), 1)
    guard let firstCommand = commands.first,
      let first = layout.primitiveAt(index: 0),
      case let .fill(center, radius, role) = firstCommand
    else {
      return XCTFail("DISC must lead with a filled ground disc")
    }
    XCTAssertEqual(center.x, CGFloat(first.x))
    XCTAssertEqual(center.y, CGFloat(first.y))
    XCTAssertEqual(radius, CGFloat(first.radius))
    XCTAssertEqual(role, .ink)

    // Every other command — the marks on that ink disc — is bg.
    for command in commands.dropFirst() {
      switch command {
      case .fill(_, _, let role), .strokeCircle(_, _, _, let role), .strokeLine(_, _, _, let role):
        XCTAssertEqual(role, .onInk)
      }
    }
  }

  func testOutlineGroundLeadsWithAStrokedInkCircle() {
    let ground = BeidSharedKit.sigil.SigilGround.OUTLINE
    let layout = BeidSharedKit.sigil.layoutSigil(
      input: makeInput(windowCount: 4, Self.mixedEntries),
      size: Self.fullSize,
      ground: ground
    )
    let commands = SigilDrawing.commands(for: layout, ground: ground)

    XCTAssertEqual(count(of: .GROUND_OUTLINE, in: layout), 1)
    guard let firstCommand = commands.first,
      let first = layout.primitiveAt(index: 0),
      case let .strokeCircle(center, radius, lineWidth, role) = firstCommand
    else {
      return XCTFail("OUTLINE must lead with a stroked ground circle")
    }
    XCTAssertEqual(center.x, CGFloat(first.x))
    XCTAssertEqual(center.y, CGFloat(first.y))
    XCTAssertEqual(radius, CGFloat(first.radius))
    XCTAssertEqual(lineWidth, CGFloat(first.lineWidth))
    XCTAssertEqual(role, .ink)

    for command in commands.dropFirst() {
      switch command {
      case .fill(_, _, let role), .strokeCircle(_, _, _, let role), .strokeLine(_, _, _, let role):
        XCTAssertEqual(role, .ink)
      }
    }
  }

  func testNoGroundEmitsNeitherGroundPrimitiveAndIsExactlyOneCommandShorter() {
    let entries = Self.mixedEntries
    func commands(_ ground: BeidSharedKit.sigil.SigilGround) -> [SigilDrawCommand] {
      SigilDrawing.commands(
        for: BeidSharedKit.sigil.layoutSigil(
          input: makeInput(windowCount: 4, entries),
          size: Self.fullSize,
          ground: ground
        ),
        ground: ground
      )
    }
    let none = BeidSharedKit.sigil.layoutSigil(
      input: makeInput(windowCount: 4, entries),
      size: Self.fullSize,
      ground: .NONE
    )

    XCTAssertEqual(count(of: .GROUND_DISC, in: none), 0)
    XCTAssertEqual(count(of: .GROUND_OUTLINE, in: none), 0)
    XCTAssertEqual(commands(.NONE).count, commands(.DISC).count - 1)
    XCTAssertEqual(commands(.NONE).count, commands(.OUTLINE).count - 1)
  }

  // MARK: - One view, two variants (AC2)

  /// The mini is not a second renderer. `shared/` already chose the variant
  /// and already returned a different primitive list; the only thing that
  /// changes here is `size`, and nothing in the Swift layer looks at it.
  func testMiniSizeDropsTheFullVariantOnlyKindsAndFullSizeDrawsRings() {
    let ground = BeidSharedKit.sigil.SigilGround.NONE

    let mini = BeidSharedKit.sigil.layoutSigil(
      input: makeInput(windowCount: 4, Self.mixedEntries),
      size: Self.miniSize,
      ground: ground
    )
    XCTAssertTrue(mini.isMini)
    XCTAssertEqual(count(of: .RING, in: mini), 0)
    XCTAssertEqual(count(of: .DETECTED_LINE, in: mini), 0)
    XCTAssertEqual(count(of: .DETECTED_DOT, in: mini), 0)
    // On a no-ground mini there is no stroked circle left to draw at all.
    XCTAssertEqual(strokeCircles(SigilDrawing.commands(for: mini, ground: ground)).count, 0)
    assertCommandsMatchLayout(SigilDrawing.commands(for: mini, ground: ground), mini, ground: ground)

    let full = BeidSharedKit.sigil.layoutSigil(
      input: makeInput(windowCount: 4, Self.mixedEntries),
      size: Self.fullSize,
      ground: ground
    )
    XCTAssertFalse(full.isMini)
    XCTAssertEqual(count(of: .RING, in: full), Int(full.ringCount))
    XCTAssertEqual(
      strokeCircles(SigilDrawing.commands(for: full, ground: ground)).count,
      Int(full.ringCount)
    )
    assertCommandsMatchLayout(SigilDrawing.commands(for: full, ground: ground), full, ground: ground)
  }

  // MARK: - The presence-2 / mutual paths

  /// An isolated mutual ring — nothing mutual next to it — is a dot in both
  /// variants. This is the only mutual mark the mini has besides its strand.
  func testAnIsolatedPresenceTwoDrawsADotAndNoLine() {
    let entries: [Entry] = [(key: "peer-a", window: 0, presence: 2)]

    for size in [Self.miniSize, Self.fullSize] {
      let layout = BeidSharedKit.sigil.layoutSigil(
        input: makeInput(windowCount: 2, entries),
        size: size,
        ground: .NONE
      )
      let commands = SigilDrawing.commands(for: layout, ground: .NONE)

      XCTAssertEqual(count(of: .MUTUAL_DOT, in: layout), 1, "size \(size)")
      XCTAssertEqual(count(of: .MUTUAL_LINE, in: layout), 0, "size \(size)")
      XCTAssertEqual(count(of: .DETECTED_LINE, in: layout), 0, "size \(size)")
      XCTAssertEqual(strokeLines(commands).count, 0, "size \(size)")
      // The mutual dot plus the centre dot; the mini adds nothing else.
      XCTAssertEqual(fills(commands).count, 2, "size \(size)")
      assertCommandsMatchLayout(commands, layout, ground: .NONE)
    }
  }

  /// Two consecutive mutual rings are one strand, not two dots — and in the
  /// mini that strand is the whole mark.
  func testTwoConsecutivePresenceTwoRingsDrawAMutualLine() {
    let entries: [Entry] = [
      (key: "peer-a", window: 0, presence: 2),
      (key: "peer-a", window: 1, presence: 2),
    ]

    let mini = BeidSharedKit.sigil.layoutSigil(
      input: makeInput(windowCount: 2, entries),
      size: Self.miniSize,
      ground: .NONE
    )
    let miniCommands = SigilDrawing.commands(for: mini, ground: .NONE)
    XCTAssertTrue(mini.isMini)
    XCTAssertEqual(count(of: .MUTUAL_LINE, in: mini), 1)
    XCTAssertEqual(count(of: .MUTUAL_DOT, in: mini), 0)
    XCTAssertEqual(strokeLines(miniCommands).count, 1)
    assertCommandsMatchLayout(miniCommands, mini, ground: .NONE)

    let full = BeidSharedKit.sigil.layoutSigil(
      input: makeInput(windowCount: 2, entries),
      size: Self.fullSize,
      ground: .NONE
    )
    let fullCommands = SigilDrawing.commands(for: full, ground: .NONE)
    XCTAssertEqual(count(of: .MUTUAL_LINE, in: full), 1)
    XCTAssertEqual(count(of: .DETECTED_LINE, in: full), 0)
    XCTAssertEqual(strokeLines(fullCommands).count, 1)
    assertCommandsMatchLayout(fullCommands, full, ground: .NONE)
  }

  /// A line is mutual only when BOTH of its ends are presence 2 — a 2 next to
  /// a 1 is a detected line. The two are distinguished by stroke width, and
  /// the assertion compares the two layouts' own widths rather than naming
  /// either: the mutual strand is the heavier one, whatever the numbers are.
  func testAMixedPresencePairDrawsADetectedLineThinnerThanTheMutualOne() {
    let mixed = BeidSharedKit.sigil.layoutSigil(
      input: makeInput(
        windowCount: 2,
        [(key: "peer-a", window: 0, presence: 2), (key: "peer-a", window: 1, presence: 1)]
      ),
      size: Self.fullSize,
      ground: .NONE
    )
    let mixedCommands = SigilDrawing.commands(for: mixed, ground: .NONE)

    XCTAssertEqual(count(of: .DETECTED_LINE, in: mixed), 1)
    XCTAssertEqual(count(of: .MUTUAL_LINE, in: mixed), 0)
    // The presence-2 end still gets its mutual dot: only the LINE downgrades.
    XCTAssertEqual(count(of: .MUTUAL_DOT, in: mixed), 1)
    XCTAssertEqual(count(of: .DETECTED_DOT, in: mixed), 1)
    assertCommandsMatchLayout(mixedCommands, mixed, ground: .NONE)

    let mutual = BeidSharedKit.sigil.layoutSigil(
      input: makeInput(
        windowCount: 2,
        [(key: "peer-a", window: 0, presence: 2), (key: "peer-a", window: 1, presence: 2)]
      ),
      size: Self.fullSize,
      ground: .NONE
    )
    let mutualCommands = SigilDrawing.commands(for: mutual, ground: .NONE)

    guard let detectedLine = strokeLines(mixedCommands).first,
      let mutualLine = strokeLines(mutualCommands).first
    else {
      return XCTFail("both pairs must draw exactly one line")
    }
    XCTAssertGreaterThan(mutualLine.lineWidth, detectedLine.lineWidth)
  }

  // MARK: - Failure and empty input

  /// Below the shared minimum size the layout fails and there is nothing to
  /// draw. The threshold itself is `internal` in Kotlin and deliberately
  /// invisible here, so this asserts on `isSuccess`, never on a number.
  func testASizeBelowTheSharedMinimumProducesNoCommands() {
    for ground in Self.allGrounds {
      let layout = BeidSharedKit.sigil.layoutSigil(
        input: makeInput(windowCount: 4, Self.mixedEntries),
        size: 1,
        ground: ground
      )
      XCTAssertFalse(layout.isSuccess)
      XCTAssertNotNil(layout.errorCode)
      XCTAssertEqual(SigilDrawing.commands(for: layout, ground: ground), [])
    }
  }

  /// A proof with no peers is still a proof: it draws the viewer's own centre
  /// dot, and its ground where it has one.
  func testEmptyInputStillDrawsACentreDotAndItsGround() {
    let empty = { BeidSharedKit.sigil.createSigilInput(windowCount: 4) }

    let disc = BeidSharedKit.sigil.layoutSigil(input: empty(), size: Self.fullSize, ground: .DISC)
    let discCommands = SigilDrawing.commands(for: disc, ground: .DISC)
    XCTAssertEqual(disc.peerCount, 0)
    XCTAssertEqual(count(of: .GROUND_DISC, in: disc), 1)
    XCTAssertEqual(count(of: .CENTER_DOT, in: disc), 1)
    assertCommandsMatchLayout(discCommands, disc, ground: .DISC)

    let outline = BeidSharedKit.sigil.layoutSigil(input: empty(), size: Self.fullSize, ground: .OUTLINE)
    XCTAssertEqual(count(of: .GROUND_OUTLINE, in: outline), 1)
    XCTAssertEqual(count(of: .CENTER_DOT, in: outline), 1)
    assertCommandsMatchLayout(
      SigilDrawing.commands(for: outline, ground: .OUTLINE),
      outline,
      ground: .OUTLINE
    )

    // A mini with no peers is the centre dot and nothing else.
    let mini = BeidSharedKit.sigil.layoutSigil(input: empty(), size: Self.miniSize, ground: .NONE)
    let miniCommands = SigilDrawing.commands(for: mini, ground: .NONE)
    XCTAssertTrue(mini.isMini)
    XCTAssertEqual(miniCommands.count, 1)
    XCTAssertEqual(fills(miniCommands).count, 1)
    assertCommandsMatchLayout(miniCommands, mini, ground: .NONE)
  }

  // MARK: - Accessibility summary

  /// `SigilLayout`'s invariant 8. Asserted here as well as in Kotlin because
  /// the VoiceOver summary reads both numbers as a partition of the drawn
  /// peers — if they ever stopped partitioning, the sentence would be wrong
  /// rather than merely different.
  func testMutualAndDetectedPeerCountsPartitionThePeerCount() {
    for ground in Self.allGrounds {
      for size in [Self.fullSize, Self.miniSize] {
        let layout = BeidSharedKit.sigil.layoutSigil(
          input: makeInput(windowCount: 4, Self.mixedEntries),
          size: size,
          ground: ground
        )
        XCTAssertEqual(layout.mutualPeerCount + layout.detectedPeerCount, layout.peerCount)
      }
    }
  }

  /// DESIGN.md §13 makes the summary a MUST for Sigils and gives its shape by
  /// example: "7 mutual, 13 detected, window 6". Pinned as an exact sentence
  /// because the shape, not just the numbers, is the contract. If the
  /// designer's open question about speaking "0 mutual" resolves differently,
  /// this is the one place, plus `Localizable.xcstrings`, that changes.
  func testAccessibilitySummaryReportsMutualDetectedAndWindowCounts() {
    let layout = BeidSharedKit.sigil.layoutSigil(
      input: makeInput(
        windowCount: 7,
        [
          (key: "mutual-1", window: 0, presence: 2),
          (key: "mutual-2", window: 1, presence: 2),
          (key: "detected-1", window: 2, presence: 1),
          (key: "detected-2", window: 3, presence: 1),
          (key: "detected-3", window: 4, presence: 1),
        ]
      ),
      size: Self.fullSize,
      ground: .DISC
    )

    XCTAssertEqual(layout.mutualPeerCount, 2)
    XCTAssertEqual(layout.detectedPeerCount, 3)
    XCTAssertEqual(layout.windowCount, 7)
    XCTAssertEqual(
      SigilDrawing.accessibilitySummary(for: layout),
      "2 mutual, 3 detected, window 7"
    )
  }

  /// A failed layout is hidden from VoiceOver, and still reports zeros
  /// rather than stale or invented counts if anything ever un-hides it.
  ///
  /// The two halves are one test because they are one decision. A failed
  /// layout draws nothing, so an element announcing
  /// "0 mutual, 0 detected, window 0" tells a VoiceOver user something false
  /// about their own data — three counts indistinguishable from a real
  /// all-zero proof. Hiding it is the fix; the summary stays pinned because
  /// it is what would be spoken if the hide were ever removed.
  ///
  /// The success branch is asserted too: a test that only pinned `true`
  /// would pass just as happily against a function that always returned it.
  ///
  /// What this does NOT catch: it pins the *decision*, not its use. A
  /// `.accessibilityHidden(_:)` modifier cannot be read back in XCTest
  /// without a view-inspection library, which this repository does not have,
  /// so deleting that line from `BeidSigilView.body` while leaving
  /// `isAccessibilityHidden` in place would leave this test green and the
  /// bug restored. That is a real limit of the available tooling, not an
  /// oversight — treat the modifier as review-enforced.
  ///
  /// The size below is deliberately too small rather than a named threshold:
  /// the shared minimum is `internal` in Kotlin and invisible here, so
  /// failure is asserted through `isSuccess`, never against a literal.
  func testAFailedLayoutIsHiddenFromVoiceOverAndStillSummarizesAsAllZeros() {
    let failed = BeidSharedKit.sigil.layoutSigil(
      input: makeInput(windowCount: 4, Self.mixedEntries),
      size: 1,
      ground: .DISC
    )
    XCTAssertFalse(failed.isSuccess)
    XCTAssertTrue(SigilDrawing.isAccessibilityHidden(for: failed))
    XCTAssertEqual(
      SigilDrawing.accessibilitySummary(for: failed),
      "0 mutual, 0 detected, window 0"
    )

    let succeeded = BeidSharedKit.sigil.layoutSigil(
      input: makeInput(windowCount: 4, Self.mixedEntries),
      size: Self.fullSize,
      ground: .DISC
    )
    XCTAssertTrue(succeeded.isSuccess)
    XCTAssertFalse(SigilDrawing.isAccessibilityHidden(for: succeeded))
  }
}
