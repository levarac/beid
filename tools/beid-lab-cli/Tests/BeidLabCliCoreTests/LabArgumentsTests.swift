// SPDX-License-Identifier: MIT

import XCTest

@testable import BeidLabCliCore

/// Argument validation is tested rather than exercised because the tool is
/// driven over ssh from a room where a measurement is running: a flag that is
/// silently ignored spends a device-seat window, and there is no second one.
final class LabArgumentsTests: XCTestCase {
  /// A real-shaped 32-byte canonical Event ID -- the string beid actually
  /// hands the engine.
  private let eventId = "9f3c71aab20d4e58a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718"

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
    XCTAssertEqual(try parse("participate", "--event-id", eventId).subcommand, .participate)
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

  // MARK: participate -- the join string

  /// The 2026-09-17 session joined with the operator lookup code and
  /// measured nothing while reporting a clean run. These are the guard rails
  /// that came out of it.

  func testParticipateNeedsAJoinSource() {
    XCTAssertThrowsError(try parse("participate")) {
      XCTAssertEqual($0 as? LabArgumentError, .missingJoinSource)
    }
  }

  /// `--event-id` is the label everywhere else and the wire value here, so a
  /// truncated id -- which would label the log correctly -- is refused.
  func testParticipateJoinsWithTheFullEventId() throws {
    let options = try parse("participate", "--event-id", eventId)
    XCTAssertEqual(options.participate.join, .eventId(eventId))
    XCTAssertEqual(options.eventIdPrefix, String(eventId.prefix(8)))
  }

  func testParticipateNormalisesTheEventIdTheWayTheAppDoes() throws {
    let options = try parse("participate", "--event-id", "0x" + eventId.uppercased())
    XCTAssertEqual(options.participate.join, .eventId(eventId))
  }

  func testParticipateRefusesAnEventIdThatIsNotThirtyTwoBytes() {
    let short = String(eventId.dropLast(2))
    XCTAssertThrowsError(try parse("participate", "--event-id", short)) {
      XCTAssertEqual($0 as? LabArgumentError, .badValue("--event-id", short))
    }
  }

  /// The heart of it: a non-canonical `--event-code` is refused, not warned
  /// about. The failure it guards is silent -- a mismatched B004 makes the
  /// engine discard every peer before B002, so the run emits no detection and
  /// reads exactly like an empty room.
  func testANonCanonicalEventCodeIsRefusedRatherThanWarnedAbout() {
    XCTAssertThrowsError(
      try parse("participate", "--event-code", "parallax-sepolia-20260917-05")
    ) {
      XCTAssertEqual(
        $0 as? LabArgumentError,
        .nonCanonicalCodeRefused("parallax-sepolia-20260917-05"))
    }
  }

  func testTheRefusalNamesTheFlagToUseInstead() {
    let message = LabArgumentError.nonCanonicalCodeRefused("x").description
    XCTAssertTrue(message.contains("--event-id"))
    XCTAssertTrue(message.contains("--allow-noncanonical-code"))
  }

  /// A synthetic rehearsal is the safest thing this tool can do beside a live
  /// measurement, so it stays available -- behind one explicit flag.
  func testAnAcknowledgedSyntheticCodeIsAllowed() throws {
    let options = try parse(
      "participate", "--event-code", "LABPROBE1", "--allow-noncanonical-code")
    XCTAssertEqual(options.participate.join, .rawCode("LABPROBE1"))
    XCTAssertTrue(options.participate.allowNonCanonicalCode)
  }

  /// An `--event-code` that already is a canonical Event ID needs no
  /// acknowledgement: it is the same string `--event-id` would produce.
  func testACanonicalEventCodeNeedsNoAcknowledgement() throws {
    XCTAssertEqual(
      try parse("participate", "--event-code", eventId).participate.join, .rawCode(eventId))
  }

  /// Uppercase hex of the right length is a different join string and hashes
  /// to a different B004, so it is not canonical.
  func testAnUppercaseEventCodeIsStillRefused() {
    let upper = eventId.uppercased()
    XCTAssertThrowsError(try parse("participate", "--event-code", upper)) {
      XCTAssertEqual($0 as? LabArgumentError, .nonCanonicalCodeRefused(upper))
    }
  }

  func testParticipateCanTakeTheEventIdFromASignedContainer() throws {
    XCTAssertEqual(
      try parse("participate", "--container", "/tmp/c.bin").participate.join,
      .container("/tmp/c.bin"))
  }

  func testTwoJoinSourcesAreRefused() {
    XCTAssertThrowsError(
      try parse("participate", "--event-id", eventId, "--container", "/tmp/c.bin")
    ) {
      XCTAssertEqual($0 as? LabArgumentError, .conflictingJoinSources)
    }
    XCTAssertThrowsError(
      try parse("participate", "--event-id", eventId, "--event-code", eventId)
    ) {
      XCTAssertEqual($0 as? LabArgumentError, .conflictingJoinSources)
    }
  }

  func testParticipateDefaults() throws {
    let options = try parse("participate", "--event-id", eventId)
    XCTAssertEqual(options.participate.role, .auto)
    XCTAssertEqual(options.participate.expectPeers, 0)
    XCTAssertFalse(options.participate.relayEnabled)
    XCTAssertFalse(options.participate.allowNonCanonicalCode)
    XCTAssertNil(options.participate.eninSeconds)
    XCTAssertNil(options.participate.eninMode)
  }

  func testParticipateRoleRelayAndPeerCount() throws {
    let options = try parse(
      "participate", "--event-id", eventId, "--role", "scan",
      "--expect-peers", "2", "--relay", "on")
    XCTAssertEqual(options.participate.role, .scan)
    XCTAssertEqual(options.participate.expectPeers, 2)
    XCTAssertTrue(options.participate.relayEnabled)
  }

  func testParticipateRejectsBadRoleRelayAndPeerCount() {
    XCTAssertThrowsError(try parse("participate", "--event-id", eventId, "--role", "sniff")) {
      XCTAssertEqual($0 as? LabArgumentError, .badValue("--role", "sniff"))
    }
    XCTAssertThrowsError(try parse("participate", "--event-id", eventId, "--relay", "yes")) {
      XCTAssertEqual($0 as? LabArgumentError, .badValue("--relay", "yes"))
    }
    XCTAssertThrowsError(
      try parse("participate", "--event-id", eventId, "--expect-peers", "-1")
    ) {
      XCTAssertEqual($0 as? LabArgumentError, .badValue("--expect-peers", "-1"))
    }
  }

  /// The engine clamps to 12...3600 silently. Refusing out-of-range input here
  /// means an operator who asks for 5 learns that they got 12, instead of
  /// reading a comparable-looking log derived from a different window.
  func testParticipateEninSecondsIsBoundedToTheEnginesRange() throws {
    XCTAssertEqual(
      try parse("participate", "--event-id", eventId, "--enin-seconds", "600")
        .participate.eninSeconds, 600)
    for bad in ["11", "3601"] {
      XCTAssertThrowsError(
        try parse("participate", "--event-id", eventId, "--enin-seconds", bad)
      ) {
        XCTAssertEqual($0 as? LabArgumentError, .badValue("--enin-seconds", bad))
      }
    }
  }

  func testParticipateEninModeMatchesTheSdkSpelling() throws {
    XCTAssertEqual(
      try parse("participate", "--event-id", eventId, "--enin-mode", "fixedLength")
        .participate.eninMode, .fixedLength)
    XCTAssertEqual(
      try parse("participate", "--event-id", eventId, "--enin-mode", "beaconSlot")
        .participate.eninMode, .beaconSlot)
    XCTAssertThrowsError(
      try parse("participate", "--event-id", eventId, "--enin-mode", "fixed")
    ) {
      XCTAssertEqual($0 as? LabArgumentError, .badValue("--enin-mode", "fixed"))
    }
  }

  /// `--allow-noncanonical-code` must not be reachable where there is no code
  /// to acknowledge.
  func testTheAcknowledgementFlagIsParticipateOnly() {
    XCTAssertThrowsError(try parse("observe", "--allow-noncanonical-code")) {
      XCTAssertEqual($0 as? LabArgumentError, .flagNotValidHere("--allow-noncanonical-code", .observe))
    }
  }

  /// An argument error is logged before parsing succeeds, so the mode on
  /// that line comes from this hint. Getting it wrong means an operator
  /// filtering their own run by mode never sees why it failed.
  func testSubcommandHintReadsTheFirstWord() {
    XCTAssertEqual(LabOptions.subcommandHint(["venue"]), .venue)
    XCTAssertEqual(LabOptions.subcommandHint(["participate", "--event-code"]), .participate)
    XCTAssertNil(LabOptions.subcommandHint(["--timeout", "5"]))
    XCTAssertNil(LabOptions.subcommandHint([]))
  }

  func testLogLevelHintSurvivesAnUnparseableCommandLine() {
    XCTAssertEqual(LabOptions.logLevelHint(["venue", "-vv", "--bogus"]), .trace)
    XCTAssertEqual(LabOptions.logLevelHint(["venue", "--log-level", "error"]), .error)
    XCTAssertEqual(LabOptions.logLevelHint(["venue", "--log-level"]), .info)
    XCTAssertEqual(LabOptions.logLevelHint([]), .info)
  }

  func testLogPathHintSurvivesAnUnparseableCommandLine() {
    XCTAssertEqual(LabOptions.logPathHint(["venue", "--log", "/tmp/a.jsonl"]), "/tmp/a.jsonl")
    XCTAssertNil(LabOptions.logPathHint(["venue", "--log"]))
    XCTAssertNil(LabOptions.logPathHint(["venue"]))
  }

  func testUsageNamesEverySubcommand() {
    for subcommand in LabSubcommand.allCases {
      XCTAssertTrue(
        LabOptions.usage.contains(subcommand.rawValue), "usage omits \(subcommand.rawValue)")
    }
  }
}
