// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import XCTest
@testable import Beid

@MainActor
final class VenueDeviceAssignmentStoreTests: XCTestCase {
  private func makeTempFileURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("venue-device-assignments-test-\(UUID().uuidString).json")
  }

  func testAddPersistsAndReloadsRoundTrip() {
    let fileURL = makeTempFileURL()
    defer { try? FileManager.default.removeItem(at: fileURL) }

    let store = VenueDeviceAssignmentStore(fileURL: fileURL)
    let now = Date()
    let record = VenueDeviceAssignmentRecord(
      label: "Front Desk",
      validityStart: now,
      validityEnd: now.addingTimeInterval(3600),
      assignedAt: now
    )
    store.add(record)

    XCTAssertEqual(store.records.count, 1)

    let reloaded = VenueDeviceAssignmentStore(fileURL: fileURL)
    XCTAssertEqual(reloaded.records.count, 1)
    XCTAssertEqual(reloaded.records.first?.label, "Front Desk")
    XCTAssertEqual(reloaded.records.first?.id, record.id)
  }

  func testNewestAssignmentIsFirst() {
    let fileURL = makeTempFileURL()
    defer { try? FileManager.default.removeItem(at: fileURL) }

    let store = VenueDeviceAssignmentStore(fileURL: fileURL)
    let now = Date()
    let first = VenueDeviceAssignmentRecord(
      label: "Front Desk",
      validityStart: now,
      validityEnd: now.addingTimeInterval(3600),
      assignedAt: now
    )
    let second = VenueDeviceAssignmentRecord(
      label: "Side Door",
      validityStart: now.addingTimeInterval(3600),
      validityEnd: now.addingTimeInterval(7200),
      assignedAt: now.addingTimeInterval(3600)
    )
    store.add(first)
    store.add(second)

    XCTAssertEqual(store.records.map(\.label), ["Side Door", "Front Desk"])
  }

  func testEmptyStoreLoadsWithNoFile() {
    let fileURL = makeTempFileURL()
    let store = VenueDeviceAssignmentStore(fileURL: fileURL)
    XCTAssertTrue(store.records.isEmpty)
    XCTAssertFalse(store.isPersistenceSuspended)
  }

  func testCorruptFileIsQuarantinedAndStoreContinuesEmpty() throws {
    let fileURL = makeTempFileURL()
    defer {
      try? FileManager.default.removeItem(at: fileURL)
    }
    try Data("not valid json".utf8).write(to: fileURL)

    let store = VenueDeviceAssignmentStore(fileURL: fileURL)

    XCTAssertTrue(store.records.isEmpty)
    let quarantinedURL = try XCTUnwrap(store.quarantinedFileURL)
    XCTAssertTrue(FileManager.default.fileExists(atPath: quarantinedURL.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    XCTAssertFalse(store.isPersistenceSuspended)
    defer { try? FileManager.default.removeItem(at: quarantinedURL) }

    // Continues to work: a fresh add writes a brand-new file rather than
    // touching the quarantined bytes.
    let now = Date()
    store.add(
      VenueDeviceAssignmentRecord(label: "Front Desk", validityStart: now, validityEnd: now.addingTimeInterval(3600), assignedAt: now)
    )
    XCTAssertEqual(store.records.count, 1)
  }
}
