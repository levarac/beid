// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import Foundation
import XCTest
@testable import Beid

/// beid#701 T3: a link row for a window changes nothing that is signed or
/// sent for that window. The same fixed capture runs once with no link file
/// and once with a link row for its id beside the submission queue; both
/// runs must produce identical bytes, equal to the golden values recorded on
/// `62531fe` (`ReportSubmissionGoldenScenario`).
@MainActor
final class ReportProofLinkByteIdentityTests: XCTestCase {
  func testALinkRowForTheWindowLeavesSignedAndPostedBytesUnchanged() async throws {
    let unlinkedDirectory = try makeReportProofLinkTestDirectory(
      for: self,
      named: "beid-report-proof-link-bytes-unlinked"
    )
    let unlinked = try await ReportSubmissionGoldenScenario.run(in: unlinkedDirectory)

    let linkedDirectory = try makeReportProofLinkTestDirectory(
      for: self,
      named: "beid-report-proof-link-bytes-linked"
    )
    let linkFileURL = linkedDirectory.appendingPathComponent("report-proof-links.json")
    let proofId = UUID(uuidString: "70100000-0000-4000-8000-0000000000f1")!
    try ReportProofLinkStore(fileURL: linkFileURL).add(
      windowId: ReportSubmissionGoldenScenario.captureId,
      proofId: proofId
    )
    let linked = try await ReportSubmissionGoldenScenario.run(in: linkedDirectory)

    // The link row really was there for the whole linked run.
    XCTAssertEqual(
      ReportProofLinkStore(fileURL: linkFileURL).proofId(
        forWindowId: ReportSubmissionGoldenScenario.captureId
      ),
      .success(proofId)
    )
    XCTAssertEqual(
      linked,
      unlinked,
      "a report-to-proof link must not change the signature input, the signed Observation or the POST body"
    )
    ReportSubmissionGoldenScenario.assertMatchesGolden(linked)
  }
}
