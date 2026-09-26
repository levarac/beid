// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import Barnard
import Foundation

/// Why `toggleOn(eventCode:)` refused to start broadcasting.
enum VenueDeviceValidationError: Equatable {
  /// No event joined yet (`SensingCoordinator.joinedEventCode` is `nil` or
  /// empty) — a venue-device assignment has no eventCode to bind to, and
  /// Barnard's own B005 payload requires one (`BarnardEventInfoCodec.
  /// payloadIfServing` returns `nil` without it).
  case noJoinedEvent
  case missingLabel
  case invalidLabel
  case validityPeriodOutOfOrder
}

/// Drives the venue-device organizer screen (gh#138): validates the label
/// and validity period locally before ever calling into Barnard, calls the
/// injected `VenueDeviceBroadcasting` facade, and records each successful
/// activation as a reassignment-history entry via `VenueDeviceAssignmentStore`.
///
/// Owns no `SensingCoordinator` reference — the joined event code is passed
/// into `toggleOn(eventCode:)` by the caller (read from `SensingCoordinator.
/// joinedEventCode`, a published, externally-readable property), keeping
/// this type decoupled from the participation-lifecycle region per
/// `docs/specs/participation-surface.md` §2.
@MainActor
final class VenueDeviceOrganizerViewModel: ObservableObject {
  @Published var label: String
  @Published var validityStart: Date
  @Published var validityEnd: Date
  @Published private(set) var isBroadcasting = false
  @Published private(set) var validationError: VenueDeviceValidationError?
  @Published private(set) var history: [VenueDeviceAssignmentRecord]

  private let broadcasting: any VenueDeviceBroadcasting
  private let store: VenueDeviceAssignmentStore

  init(
    broadcasting: any VenueDeviceBroadcasting = BarnardVenueDeviceBroadcasting(),
    store: VenueDeviceAssignmentStore? = nil
  ) {
    self.broadcasting = broadcasting
    // `VenueDeviceAssignmentStore` is `@MainActor`; a default-argument
    // expression is not evaluated in the initializer's own isolation, so
    // the default is constructed here in the (main-actor) init body
    // instead of as a parameter default.
    let store = store ?? VenueDeviceAssignmentStore()
    self.store = store
    history = store.records
    let now = Date()
    if let latest = store.records.first {
      label = latest.label
      validityStart = latest.validityStart
      validityEnd = latest.validityEnd
    } else {
      label = ""
      validityStart = now
      validityEnd = now
    }
  }

  /// Attempts to start broadcasting with the current `label`/`validityStart`/
  /// `validityEnd` field values. Validates locally first (empty label,
  /// invalid label per Barnard's own display-name rule, and an out-of-order
  /// validity period all set `validationError` and return without touching
  /// Barnard) so the UI's first signal for a bad label is never the SDK's
  /// thrown error. On success, appends a new reassignment-history record.
  func toggleOn(eventCode: String?) {
    guard let eventCode, !eventCode.isEmpty else {
      validationError = .noJoinedEvent
      return
    }
    let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedLabel.isEmpty else {
      validationError = .missingLabel
      return
    }
    guard (try? BarnardEventInfoCodec.validateEventDisplayName(trimmedLabel)) != nil else {
      validationError = .invalidLabel
      return
    }
    guard validityEnd > validityStart else {
      validationError = .validityPeriodOutOfOrder
      return
    }

    do {
      try broadcasting.startBroadcasting(eventCode: eventCode, label: trimmedLabel)
    } catch {
      validationError = .invalidLabel
      return
    }

    validationError = nil
    isBroadcasting = true
    let assignedAt = Date()
    let record = VenueDeviceAssignmentRecord(
      label: trimmedLabel,
      validityStart: validityStart,
      validityEnd: validityEnd,
      assignedAt: assignedAt
    )
    store.add(record)
    history = store.records
  }

  func toggleOff() {
    broadcasting.stopBroadcasting()
    isBroadcasting = false
  }
}
