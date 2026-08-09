// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import Barnard
import XCTest
@testable import Beid

@MainActor
final class VenueDeviceOrganizerViewModelTests: XCTestCase {
  private func makeTempFileURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("venue-device-assignments-test-\(UUID().uuidString).json")
  }

  private func makeViewModel(
    broadcasting: FakeVenueDeviceBroadcasting = FakeVenueDeviceBroadcasting(),
    fileURL: URL? = nil
  ) -> (VenueDeviceOrganizerViewModel, URL) {
    let url = fileURL ?? makeTempFileURL()
    let store = VenueDeviceAssignmentStore(fileURL: url)
    let viewModel = VenueDeviceOrganizerViewModel(broadcasting: broadcasting, store: store)
    return (viewModel, url)
  }

  func testTogglingOnWithNoJoinedEventIsRefusedWithoutCallingBarnard() {
    let broadcasting = FakeVenueDeviceBroadcasting()
    let (viewModel, fileURL) = makeViewModel(broadcasting: broadcasting)
    defer { try? FileManager.default.removeItem(at: fileURL) }
    viewModel.label = "Front Desk"
    viewModel.validityEnd = viewModel.validityStart.addingTimeInterval(3600)

    viewModel.toggleOn(eventCode: nil)

    XCTAssertEqual(viewModel.validationError, .noJoinedEvent)
    XCTAssertFalse(viewModel.isBroadcasting)
    XCTAssertTrue(broadcasting.calls.isEmpty)
  }

  func testTogglingOnWithAnEmptyLabelIsRefusedWithoutCallingBarnard() {
    let broadcasting = FakeVenueDeviceBroadcasting()
    let (viewModel, fileURL) = makeViewModel(broadcasting: broadcasting)
    defer { try? FileManager.default.removeItem(at: fileURL) }
    viewModel.label = "   "
    viewModel.validityEnd = viewModel.validityStart.addingTimeInterval(3600)

    viewModel.toggleOn(eventCode: "EVENT-A")

    XCTAssertEqual(viewModel.validationError, .missingLabel)
    XCTAssertFalse(viewModel.isBroadcasting)
    XCTAssertTrue(broadcasting.calls.isEmpty)
  }

  func testTogglingOnWithAnOverlongLabelIsRefusedWithoutCallingBarnard() {
    let broadcasting = FakeVenueDeviceBroadcasting()
    let (viewModel, fileURL) = makeViewModel(broadcasting: broadcasting)
    defer { try? FileManager.default.removeItem(at: fileURL) }
    viewModel.label = String(repeating: "a", count: 65)
    viewModel.validityEnd = viewModel.validityStart.addingTimeInterval(3600)

    viewModel.toggleOn(eventCode: "EVENT-A")

    XCTAssertEqual(viewModel.validationError, .invalidLabel)
    XCTAssertFalse(viewModel.isBroadcasting)
    XCTAssertTrue(
      broadcasting.calls.isEmpty,
      "local pre-validation must catch this before Barnard's own throw is the first signal"
    )
  }

  func testTogglingOnWithoutAdvancingTheEndDateIsRefused() {
    let broadcasting = FakeVenueDeviceBroadcasting()
    let (viewModel, fileURL) = makeViewModel(broadcasting: broadcasting)
    defer { try? FileManager.default.removeItem(at: fileURL) }
    viewModel.label = "Front Desk"
    // Fresh view model with no history defaults start == end, so this is
    // exactly the "validity-period-less assignment" the acceptance
    // criterion (docs/specs/participation-surface.md §7.1) rules out.

    viewModel.toggleOn(eventCode: "EVENT-A")

    XCTAssertEqual(viewModel.validationError, .validityPeriodOutOfOrder)
    XCTAssertFalse(viewModel.isBroadcasting)
    XCTAssertTrue(broadcasting.calls.isEmpty)
  }

  func testSuccessfulToggleOnCallsBroadcastingAndAppendsHistory() {
    let broadcasting = FakeVenueDeviceBroadcasting()
    let (viewModel, fileURL) = makeViewModel(broadcasting: broadcasting)
    defer { try? FileManager.default.removeItem(at: fileURL) }
    viewModel.label = "Front Desk"
    viewModel.validityEnd = viewModel.validityStart.addingTimeInterval(3600)

    viewModel.toggleOn(eventCode: "EVENT-A")

    XCTAssertNil(viewModel.validationError)
    XCTAssertTrue(viewModel.isBroadcasting)
    XCTAssertEqual(broadcasting.calls, [.startBroadcasting(eventCode: "EVENT-A", label: "Front Desk")])
    XCTAssertEqual(viewModel.history.count, 1)
    XCTAssertEqual(viewModel.history.first?.label, "Front Desk")
  }

  func testLabelIsTrimmedBeforeValidationAndBroadcasting() {
    let broadcasting = FakeVenueDeviceBroadcasting()
    let (viewModel, fileURL) = makeViewModel(broadcasting: broadcasting)
    defer { try? FileManager.default.removeItem(at: fileURL) }
    viewModel.label = "  Front Desk  "
    viewModel.validityEnd = viewModel.validityStart.addingTimeInterval(3600)

    viewModel.toggleOn(eventCode: "EVENT-A")

    XCTAssertEqual(broadcasting.calls, [.startBroadcasting(eventCode: "EVENT-A", label: "Front Desk")])
  }

  func testToggleOffCallsBroadcastingAndClearsBroadcastingState() {
    let broadcasting = FakeVenueDeviceBroadcasting()
    let (viewModel, fileURL) = makeViewModel(broadcasting: broadcasting)
    defer { try? FileManager.default.removeItem(at: fileURL) }
    viewModel.label = "Front Desk"
    viewModel.validityEnd = viewModel.validityStart.addingTimeInterval(3600)
    viewModel.toggleOn(eventCode: "EVENT-A")
    XCTAssertTrue(viewModel.isBroadcasting)

    viewModel.toggleOff()

    XCTAssertFalse(viewModel.isBroadcasting)
    XCTAssertEqual(
      broadcasting.calls,
      [
        .startBroadcasting(eventCode: "EVENT-A", label: "Front Desk"),
        .stopBroadcasting,
      ]
    )
  }

  func testWhenBarnardThrowsTheViewModelSurfacesInvalidLabelAndDoesNotRecordHistory() {
    let broadcasting = FakeVenueDeviceBroadcasting()
    broadcasting.startBroadcastingError = BarnardEventInfoError.invalidDisplayName
    let (viewModel, fileURL) = makeViewModel(broadcasting: broadcasting)
    defer { try? FileManager.default.removeItem(at: fileURL) }
    viewModel.label = "Front Desk"
    viewModel.validityEnd = viewModel.validityStart.addingTimeInterval(3600)

    viewModel.toggleOn(eventCode: "EVENT-A")

    XCTAssertEqual(viewModel.validationError, .invalidLabel)
    XCTAssertFalse(viewModel.isBroadcasting)
    XCTAssertTrue(viewModel.history.isEmpty)
  }

  func testReassignmentAppendsANewHistoryEntryRatherThanReplacingTheFirst() {
    let broadcasting = FakeVenueDeviceBroadcasting()
    let (viewModel, fileURL) = makeViewModel(broadcasting: broadcasting)
    defer { try? FileManager.default.removeItem(at: fileURL) }
    viewModel.label = "Front Desk"
    viewModel.validityEnd = viewModel.validityStart.addingTimeInterval(3600)
    viewModel.toggleOn(eventCode: "EVENT-A")
    viewModel.toggleOff()

    viewModel.label = "Side Door"
    viewModel.validityStart = viewModel.validityEnd
    viewModel.validityEnd = viewModel.validityStart.addingTimeInterval(3600)
    viewModel.toggleOn(eventCode: "EVENT-A")

    XCTAssertEqual(viewModel.history.count, 2)
    // Newest first, matching VenueDeviceAssignmentStore's ordering.
    XCTAssertEqual(viewModel.history.map(\.label), ["Side Door", "Front Desk"])
  }

  func testInitialFieldsAreSeededFromTheMostRecentPersistedRecord() {
    let fileURL = makeTempFileURL()
    defer { try? FileManager.default.removeItem(at: fileURL) }
    let seededStore = VenueDeviceAssignmentStore(fileURL: fileURL)
    let start = Date()
    let end = start.addingTimeInterval(7200)
    seededStore.add(
      VenueDeviceAssignmentRecord(label: "Loading Dock", validityStart: start, validityEnd: end, assignedAt: start)
    )

    let reloadedStore = VenueDeviceAssignmentStore(fileURL: fileURL)
    let viewModel = VenueDeviceOrganizerViewModel(
      broadcasting: FakeVenueDeviceBroadcasting(),
      store: reloadedStore
    )

    XCTAssertEqual(viewModel.label, "Loading Dock")
    XCTAssertEqual(viewModel.validityStart.timeIntervalSince1970, start.timeIntervalSince1970, accuracy: 0.001)
    XCTAssertEqual(viewModel.validityEnd.timeIntervalSince1970, end.timeIntervalSince1970, accuracy: 0.001)
    XCTAssertEqual(viewModel.history.count, 1)
  }
}
