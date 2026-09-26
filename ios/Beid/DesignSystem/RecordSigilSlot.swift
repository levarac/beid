// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import Foundation
import SwiftUI

/// Reserves a record's Sigil footprint until #653 supplies truthful inputs.
///
/// The record ID is carried to the slot for that future integration. It does
/// not currently select artwork: every real record gets the same neutral ring.
struct RecordSigilSlot: View {
  enum Ground {
    case canvas
    case ink

    fileprivate var ringColor: SwiftUI.Color {
      switch self {
      case .canvas: DS.Color.strokeHairline
      case .ink: DS.Color.strokeHairlineOnInk
      }
    }
  }

  let recordID: UUID?
  let size: CGFloat
  let ground: Ground

  var body: some View {
    artwork
      .frame(width: size, height: size)
      .accessibilityHidden(true)
  }

  // #653 can replace the artwork here once a record has real Sigil inputs.
  @ViewBuilder private var artwork: some View {
    Circle()
      .strokeBorder(ground.ringColor, lineWidth: DS.Size.hairline)
  }
}
