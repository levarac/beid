// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import Foundation

/// One venue-device (gh#138) B005 assignment — local, unsigned bookkeeping
/// of what this device broadcast and when. Not cryptographically signed:
/// `docs/specs/participation-surface.md` §5.4's recommended shape is a
/// local, append-only, unsigned list, explicitly not meaningful to sign
/// under the app-editable design this sub-slice implements (a signed
/// history would only make sense under the audit's alternate
/// organizer-signed-assignment design, `levarac/barnard#127`, which this
/// milestone does not adopt).
struct VenueDeviceAssignmentRecord: Identifiable, Codable, Equatable, Hashable {
  let id: UUID
  let label: String
  let validityStart: Date
  let validityEnd: Date
  let assignedAt: Date

  init(
    id: UUID = UUID(),
    label: String,
    validityStart: Date,
    validityEnd: Date,
    assignedAt: Date
  ) {
    self.id = id
    self.label = label
    self.validityStart = validityStart
    self.validityEnd = validityEnd
    self.assignedAt = assignedAt
  }
}
