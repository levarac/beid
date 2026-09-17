// Use of this source code is governed by a BSD-style license.

import XCTest

@testable import BeidLabCliCore

/// Argument validation is tested rather than exercised because the tool is
/// driven over ssh from a room where a measurement is running: a flag that is
/// silently ignored spends a device-seat window, and there is no second one.
final class LabArgumentsTests: XCTestCase {
  private func parse(_ arguments: String...) throws -> LabOptions {
    try LabOptions.parse(arguments)
  }

  // MARK: Subcommand

  func testSubcommandIsRequiredAndMustComeFirst() {
    XCTAssertThrowsError(try parse()) { XCTAssertEqual($0 as? LabArgumentError, .missingSubcommand) }
    XCTAssertThrowsError(try parse("--timeout", "5", "observe")) {
      XCTAssertEqual($0 as? LabArgumentError, .unknownSubcommand("--timeout"))
    }
    XCTAssertThrowsError(try parse("scan")) {
      XCTAssertEqual($0 as? LabArgumentError, .unknownSubcommand("scan"))
    }
  }

  func testThreeSubcommandsParse() throws {
    XCTAssertEqual(try parse("observe").subcommand, .observe)
    XCTAssertEqual(try parse("venue", "--container", "/tmp/c.bin").subcommand, .venue)
    XCTAssertEqual(try parse("participate", "--event-code", "BND").subcommand, .participate)
  }

  func testHelpIsRecognisedWithAndWithoutASubcommand() {
    XCTAssertThrowsError(try parse("--help")) {
      XCTAssertEqual($0 as? LabArgumentError, .helpRequested)
    }
    XCTAssertThrowsError(try parse("observe", "-h")) {
      XCTAssertEqual($0 as? LabArgumentError, .helpRequested)
    }
  }

  // MARK: Log level

  func testLogLevelDefaultsToInfo() throws {
    XCTAssertEqual(try parse("observe").logLevel, .info)
  }

  func testLogLevelAcceptsEachNameAndTheVerboseShorthands() throws {
    XCTAssertEqual(try parse("observe", "--log-level", "error").logLevel, .error)
    XCTAssertEqual(try parse("observe", "--log-level", "trace").logLevel, .trace)
    XCTAssertEqual(try parse("observe", "-v").logLevel, .debug)
    XCTAssertEqual(try parse("observe", "-vv").logLevel, .trace)
  }

  func testLogLevelRejectsAnUnknownName() {
    XCTAssertThrowsError(try parse("observe", "--log-level", "verbose")) {
      XCTAssertEqual($0 as? LabArgumentError, .badValue("--log-level", "verbose"))
    }
  }

  /// Last one wins, stated rather than accidental: a shell wrapper that
  /// appends `-vv` to a command line that already carries `--log-level info`
  /// should raise the level, not be ignored.
  func testTheLastLevelArgumentWins() throws {
    XCTAssertEqual(try parse("observe", "--log-level", "info", "-vv").logLevel, .trace)
    XCTAssertEqual(try parse("observe", "-vv", "--log-level", "error").logLevel, .error)
  }

  // MARK: Common options

  func testTimeoutMustBePositive() throws {
    XCTAssertEqual(try parse("observe", "--timeout", "45").timeoutSeconds, 45)
    for bad in ["0", "-1", "abc", ""] {
      XCTAssertThrowsError(try parse("observe", "--timeout", bad)) {
        XCTAssertEqual($0 as? LabArgumentError, .badValue("--timeout", bad))
      }
    }
  }

  func testEventIdIsARunLabelReducedToEightHex() throws {
    let options = try parse(
      "observe", "--event-id",
      "0x9F3C71AA0000000000000000000000000000000000000000000000000000BEEF")
    XCTAssertEqual(options.eventIdPrefix, "9f3c71aa")
    XCTAssertNil(try parse("observe").eventIdPrefix)
  }

  func testEventIdRejectsNonHex() {
    XCTAssertThrowsError(try parse("observe", "--event-id", "not-hex")) {
      XCTAssertEqual($0 as? LabArgumentError, .badValue("--event-id", "not-hex"))
    }
  }

  func testMissingValueIsReportedAgainstItsFlag() {
    XCTAssertThrowsError(try parse("observe", "--timeout")) {
      XCTAssertEqual($0 as? LabArgumentError, .missingValue("--timeout"))
    }
  }

  func testUnknownFlagIsRejectedRatherThanIgnored() {
    XCTAssertThrowsError(try parse("observe", "--role", "scan")) {
      XCTAssertEqual($0 as? LabArgumentError, .flagNotValidHere("--role", .observe))
    }
    XCTAssertThrowsError(try parse("observe", "--nonsense")) {
      XCTAssertEqual($0 as? LabArgumentError, .unknownFlag("--nonsense"))
    }
  }

  // MARK: observe

  func testObserveDefaults() throws {
    let options = try parse("observe")
    XCTAssertEqual(options.observe.lostAfterSeconds, 10)
    XCTAssertEqual(options.observe.repeatEverySeconds, 5)
    XCTAssertEqual(options.timeoutSeconds, 120)
  }

  func testObserveWindowsMustBePositive() {
    XCTAssertThrowsError(try parse("observe", "--lost-after", "0")) {
      XCTAssertEqual($0 as? LabArgumentError, .badValue("--lost-after", "0"))
    }
    XCTAssertThrowsError(try parse("observe", "--repeat-every", "-2")) {
      XCTAssertEqual($0 as? LabArgumentError, .badValue("--repeat-every", "-2"))
    }
  }

  /// `--repeat-every 0` prints every advertisement. It is the one zero that
  /// means something, so it is admitted where the other windows are not.
  func testRepeatEveryZeroMeansPrintEverySighting() throws {
    XCTAssertEqual(try parse("observe", "--repeat-every", "0").observe.repeatEverySeconds, 0)
  }

  // MARK: venue

  func testVenueRequiresExactlyOneContainerSource() {
    XCTAssertThrowsError(try parse("venue")) {
      XCTAssertEqual($0 as? LabArgumentError, .missingContainerSource)
    }
    XCTAssertThrowsError(try parse("venue", "--container", "/tmp/c.bin", "--container-hex", "03ff")) {
      XCTAssertEqual($0 as? LabArgumentError, .conflictingContainerSources)
    }
  }

  func testVenueAcceptsAFileOrHexContainer() throws {
    XCTAssertEqual(
      try parse("venue", "--container", "/tmp/c.bin").venue.container, .file("/tmp/c.bin"))
    XCTAssertEqual(
      try parse("venue", "--container-hex", "03FF00").venue.container, .hex("03ff00"))
  }

  func testVenueRejectsNonHexContainerBytes() {
    XCTAssertThrowsError(try parse("venue", "--container-hex", "03f")) {
      XCTAssertEqual($0 as? LabArgumentError, .badValue("--container-hex", "03f"))
    }
    XCTAssertThrowsError(try parse("venue", "--container-hex", "zz")) {
      XCTAssertEqual($0 as? LabArgumentError, .badValue("--container-hex", "zz"))
    }
  }

  /// The CLI has no network by instruction (Ken, 2026-09-17), so a URL is
  /// refused with an explanation rather than parsed as a file path and
  /// failing later as a missing file.
  func testVenueRefusesAUrlWithAnExplanation() {
    XCTAssertThrowsError(try parse("venue", "--container", "https://example.test/c.bin")) {
      XCTAssertEqual($0 as? LabArgumentError, .networkSourceRefused("--container"))
    }
  }

  /// A venue device serves signed bytes and joins nothing, exactly as
  /// `BarnardVenueSignedContainerBroadcasting` does on iOS. Accepting an
  /// event code here would put a participant B004 on the air during a live
  /// measurement.
  func testVenueRefusesAnEventCode() {
    XCTAssertThrowsError(try parse("venue", "--container", "/tmp/c.bin", "--event-code", "BND")) {
      XCTAssertEqual($0 as? LabArgumentError, .flagNotValidHere("--event-code", .venue))
    }
  }

  // MARK: participate

  func testParticipateRequiresAnEventCode() {
    XCTAssertThrowsError(try parse("participate")) {
      XCTAssertEqual($0 as? LabArgumentError, .missingEventCode)
    }
    XCTAssertThrowsError(try parse("participate", "--event-code", "")) {
      XCTAssertEqual($0 as? LabArgumentError, .badValue("--event-code", ""))
    }
  }

  /// `--event-id` cannot join: Barnard joins by code, and B004 is that code's
  /// hash. So an event id supplied alone is refused rather than quietly
  /// treated as a code that will never match anything on the air.
  func testParticipateRefusesAnEventIdWithoutAnEventCode() {
    XCTAssertThrowsError(try parse("participate", "--event-id", String(repeating: "a", count: 64))) {
      XCTAssertEqual($0 as? LabArgumentError, .missingEventCode)
    }
  }

  func testParticipateDefaults() throws {
    let options = try parse("participate", "--event-code", "BND")
    XCTAssertEqual(options.participate.eventCode, "BND")
    XCTAssertEqual(options.participate.role, .auto)
    XCTAssertEqual(options.participate.expectPeers, 0)
    XCTAssertFalse(options.participate.relayEnabled)
    XCTAssertNil(options.participate.eninSeconds)
    XCTAssertNil(options.participate.eninMode)
  }

  func testParticipateRoleRelayAndPeerCount() throws {
    let options = try parse(
      "participate", "--event-code", "BND", "--role", "scan",
      "--expect-peers", "2", "--relay", "on")
    XCTAssertEqual(options.participate.role, .scan)
    XCTAssertEqual(options.participate.expectPeers, 2)
    XCTAssertTrue(options.participate.relayEnabled)
  }

  func testParticipateRejectsBadRoleRelayAndPeerCount() {
    XCTAssertThrowsError(try parse("participate", "--event-code", "B", "--role", "sniff")) {
      XCTAssertEqual($0 as? LabArgumentError, .badValue("--role", "sniff"))
    }
    XCTAssertThrowsError(try parse("participate", "--event-code", "B", "--relay", "yes")) {
      XCTAssertEqual($0 as? LabArgumentError, .badValue("--relay", "yes"))
    }
    XCTAssertThrowsError(try parse("participate", "--event-code", "B", "--expect-peers", "-1")) {
      XCTAssertEqual($0 as? LabArgumentError, .badValue("--expect-peers", "-1"))
    }
  }

  /// The engine clamps to 12...3600 silently. Refusing out-of-range input here
  /// means an operator who asks for 5 learns that they got 12, instead of
  /// reading a comparable-looking log derived from a different window.
  func testParticipateEninSecondsIsBoundedToTheEnginesRange() throws {
    XCTAssertEqual(
      try parse("participate", "--event-code", "B", "--enin-seconds", "600")
        .participate.eninSeconds, 600)
    for bad in ["11", "3601"] {
      XCTAssertThrowsError(try parse("participate", "--event-code", "B", "--enin-seconds", bad)) {
        XCTAssertEqual($0 as? LabArgumentError, .badValue("--enin-seconds", bad))
      }
    }
  }

  func testParticipateEninModeMatchesTheSdkSpelling() throws {
    XCTAssertEqual(
      try parse("participate", "--event-code", "B", "--enin-mode", "fixedLength")
        .participate.eninMode, .fixedLength)
    XCTAssertEqual(
      try parse("participate", "--event-code", "B", "--enin-mode", "beaconSlot")
        .participate.eninMode, .beaconSlot)
    XCTAssertThrowsError(try parse("participate", "--event-code", "B", "--enin-mode", "fixed")) {
      XCTAssertEqual($0 as? LabArgumentError, .badValue("--enin-mode", "fixed"))
    }
  }

  func testUsageNamesEverySubcommand() {
    for subcommand in LabSubcommand.allCases {
      XCTAssertTrue(
        LabOptions.usage.contains(subcommand.rawValue), "usage omits \(subcommand.rawValue)")
    }
  }
}
