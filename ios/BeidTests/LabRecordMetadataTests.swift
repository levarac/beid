import XCTest

final class LabRecordMetadataTests: XCTestCase {
  func testTerminalErrorProjectionAllowsOnlyExistingCodes() {
    XCTAssertEqual(boundedLabTerminalError("timeout"), "timeout")
    XCTAssertNil(boundedLabTerminalError("raw_private_error_detail"))
    XCTAssertNil(boundedLabTerminalError(nil))
  }
}
