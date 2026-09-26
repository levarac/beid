// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import BeidSharedKit
import Foundation
import SwiftUI

/// Every place a record's Sigil is drawn, with its size and both grounds.
///
/// The grounds were measured from the Flat 2b Figma exports (beid#653 OD-6),
/// not chosen: 07 and 09 draw the Sigil on a filled ink disc; 04, 04c, 06, 08
/// and 12 draw it with no ground, and 04's active card and 06 sit on an ink
/// page. The variant (full or mini) is not decided here: `layoutSigil` picks it
/// from the size, so 04's past rows (60), 08's rows (48) and 12's rows (40) are
/// minis.
enum RecordSigilPlacement: CaseIterable {
  /// Frame 04, the in-progress card (node 183:13).
  case homeActiveCard
  /// Frames 04 / 04c, a past event row (nodes 183:54, 203:47).
  case homePastRow
  /// Frame 06, Sensing — Sealed (node 184:65).
  case sensingSealed
  /// Frame 07, Proof Collected (node 183:222).
  case proofCollected
  /// Frame 08, an Event Detail session row (node 184:266).
  case eventDetailRow
  /// Frame 09, Proof Detail (node 204:36).
  case proofDetail
  /// Frame 12, a Report Detail session-proof row (nodes 206:174, 206:213;
  /// 40×40, no ground, `#0B0B0F` strokes).
  case reportDetailRow

  var size: CGFloat {
    switch self {
    case .homeActiveCard: 84
    case .homePastRow: 60
    case .sensingSealed: DS.Size.sensingSealedSigil
    case .proofCollected: 290
    case .eventDetailRow: DS.Size.proofRowMinHeight - DS.Space.l
    case .proofDetail: DS.Size.proofDetailSigil
    case .reportDetailRow: 40
    }
  }

  var page: RecordSigilSlot.Ground {
    switch self {
    case .homeActiveCard, .sensingSealed: .ink
    case .homePastRow, .proofCollected, .eventDetailRow, .proofDetail, .reportDetailRow: .canvas
    }
  }

  var sigilGround: BeidSharedKit.sigil.SigilGround {
    switch self {
    case .proofCollected, .proofDetail: .DISC
    case .homeActiveCard, .homePastRow, .sensingSealed, .eventDetailRow, .reportDetailRow: .NONE
    }
  }
}

/// A record's Sigil (beid#653), or the neutral ring when the record has no
/// Sigil data.
///
/// `input` comes from `SensingCoordinator.sigilInput(forProofId:)` (stored)
/// or `liveSigilInput` (frame 04's in-progress card). `nil` is the only "no
/// data" signal: records from before #653, killed sessions, sessions over
/// 1,024 peers and restored records all have no row. They keep the ring,
/// hidden from VoiceOver, exactly as before. Nothing is inferred from counts.
///
/// With data, the real Sigil is drawn by `BeidSigilView` and carries its
/// VoiceOver summary (DESIGN.md §13). Presence 2 (mutual) never exists on the
/// device, so a mini (≤ 60) is the centre dot alone. That is the shared
/// layout's own output for measured data, not a placeholder (OD-3).
struct RecordSigilSlot: View {
  /// The page the slot sits on.
  enum Ground {
    case canvas
    case ink

    fileprivate var ringColor: SwiftUI.Color {
      switch self {
      case .canvas: DS.Color.strokeHairline
      case .ink: DS.Color.strokeHairlineOnInk
      }
    }

    var sigilPage: SigilPage {
      switch self {
      case .canvas: .canvas
      case .ink: .ink
      }
    }
  }

  /// What the slot draws for a given input. Pure, so the "no data → ring"
  /// rule can be pinned by a test.
  enum Artwork {
    case neutralRing
    case sigil(BeidSharedKit.sigil.SigilInput)
  }

  static func artwork(for input: BeidSharedKit.sigil.SigilInput?) -> Artwork {
    guard let input else { return .neutralRing }
    return .sigil(input)
  }

  let input: BeidSharedKit.sigil.SigilInput?
  let placement: RecordSigilPlacement

  var body: some View {
    switch Self.artwork(for: input) {
    case .neutralRing:
      Circle()
        .strokeBorder(placement.page.ringColor, lineWidth: DS.Size.hairline)
        .frame(width: placement.size, height: placement.size)
        .accessibilityHidden(true)
    case let .sigil(input):
      BeidSigilView(
        input: input,
        size: placement.size,
        ground: placement.sigilGround,
        page: placement.page.sigilPage
      )
    }
  }
}
