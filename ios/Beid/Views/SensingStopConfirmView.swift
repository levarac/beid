// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import SwiftUI

/// Identity held while sensing continues. A record ID may not exist yet
/// when the participant requests a stop during initial detection.
struct SensingStopConfirmSnapshot {
  let proofID: UUID?
  let event: EventSession

  /// What the confirmation says. Before any record exists, stopping saves
  /// nothing, so the copy must not promise a record.
  var copy: SensingStopConfirmCopy { SensingStopConfirmCopy(hasRecord: proofID != nil) }
}

struct SensingStopConfirmCopy: Equatable {
  let body: String
  let stopTitle: String

  init(hasRecord: Bool) {
    if hasRecord {
      body = String(localized: "Your record will be saved on this device.")
      stopTitle = String(localized: "Stop and keep record")
    } else {
      body = String(localized: "Any record created will be saved on this device.")
      stopTitle = String(localized: "Stop sensing")
    }
  }
}
