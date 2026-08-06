// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import Foundation
import XCTest
@testable import Beid

@MainActor
final class WindowReportStoreDurabilityTests: XCTestCase {
  func testFailedAtomicWriteDoesNotPublishAnUndurableReport() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("beid-window-report-store-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let blockingFile = directory.appendingPathComponent("not-a-directory")
    try Data([0x01]).write(to: blockingFile)
    let store = WindowReportStore(
      fileURL: blockingFile.appendingPathComponent("window-reports.json")
    )
    let reportData = Data(
      """
      {
        "id":"00000000-0000-0000-0000-000000000001",
        "eventCode":"event-1",
        "enin":1,
        "peerCount":1,
        "commitHex":"00",
        "signatureRHex":"01",
        "signatureSHex":"02",
        "signatureV":0,
        "signedAt":0
      }
      """.utf8
    )
    let report = try JSONDecoder().decode(WindowReport.self, from: reportData)

    XCTAssertThrowsError(try store.add(report))
    XCTAssertTrue(store.reports.isEmpty)
  }
}
