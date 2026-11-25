// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import SwiftUI

/// Identity held while sensing continues. A record ID may not exist yet
/// when the participant requests a stop during initial detection.
struct SensingStopConfirmSnapshot {
  let proofID: UUID?
  let event: EventSession

  /// What the confirmation says. There is one stop action; the message only
  /// differs by whether a Record exists yet.
  var copy: SensingStopConfirmCopy { SensingStopConfirmCopy(hasRecord: proofID != nil) }
}

struct SensingStopConfirmCopy: Equatable {
  let body: String
  let stopTitle: String

  init(hasRecord: Bool) {
    stopTitle = String(localized: "stop.confirm.action", defaultValue: "Stop sensing",
                       comment: "Stop alert confirm button. Ends the sensing session at this event.")
    if hasRecord {
      body = String(localized: "stop.confirm.message.record",
                    defaultValue: "This ends your sensing session at this event. Any saved Record stays in Records on this device.",
                    comment: "Stop alert message when a Record already exists. A Record is the item kept in the Records tab.")
    } else {
      body = String(localized: "stop.confirm.message.noRecord",
                    defaultValue: "This ends your sensing session at this event. No Record has been created yet.",
                    comment: "Stop alert message before any Record exists.")
    }
  }
}
