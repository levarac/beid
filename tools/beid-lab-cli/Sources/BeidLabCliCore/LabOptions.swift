// Use of this source code is governed by a BSD-style license.

import Foundation

/// Which half of the radio a `participate` run uses.
public enum LabRole: String, CaseIterable, Sendable {
  case advertise
  case scan
  case auto
}

/// Mirrors `BarnardEninMode` verbatim, spelling included. A friendlier
/// spelling here would be a second vocabulary for the same SDK value, and the
/// operator reading an engine log would have to translate.
public enum LabEninMode: String, CaseIterable, Sendable {
  case fixedLength
  case beaconSlot
}

/// Where the signed B005 v2 container comes from.
///
/// Both cases are local. The CLI has no network by instruction (Ken,
/// 2026-09-17): issue #588's "URL or file" wording is superseded, and the
/// operator copies the container to the host instead.
public enum LabContainerSource: Equatable, Sendable {
  case file(String)
  case hex(String)
}

public enum LabArgumentError: Error, Equatable, CustomStringConvertible {
  case helpRequested
  case missingSubcommand
  case unknownSubcommand(String)
  case unknownFlag(String)
  case flagNotValidHere(String, LabSubcommand)
  case missingValue(String)
  case badValue(String, String)
  case missingContainerSource
  case conflictingContainerSources
  case networkSourceRefused(String)
  case missingEventCode

  public var description: String {
    switch self {
    case .helpRequested:
      return "help requested"
    case .missingSubcommand:
      return "no subcommand; expected one of \(LabSubcommand.allCases.map(\.rawValue).joined(separator: ", "))"
    case .unknownSubcommand(let raw):
      return "unknown subcommand \(raw); the subcommand comes first, before any flag"
    case .unknownFlag(let flag):
      return "unknown flag \(flag)"
    case .flagNotValidHere(let flag, let subcommand):
      return "\(flag) is not a \(subcommand.rawValue) option"
    case .missingValue(let flag):
      return "\(flag) needs a value"
    case .badValue(let flag, let raw):
      return "\(flag) does not accept \(raw.isEmpty ? "an empty value" : raw)"
    case .missingContainerSource:
      return "venue needs --container <path> or --container-hex <hex>"
    case .conflictingContainerSources:
      return "--container and --container-hex are alternatives; pass one"
    case .networkSourceRefused(let flag):
      return
        "\(flag) takes a local path: this tool performs no network access, so copy the file to this host first"
    case .missingEventCode:
      return
        "participate needs --event-code. --event-id is a log label only: Barnard joins by code, and B004 is that code's hash, so an event id cannot be joined with"
    }
  }
}

/// `observe`-only settings.
public struct LabObserveOptions: Equatable, Sendable {
  public var lostAfterSeconds: TimeInterval = 10
  public var repeatEverySeconds: TimeInterval = 5
}

/// `venue`-only settings.
public struct LabVenueOptions: Equatable, Sendable {
  public var container: LabContainerSource?
}

/// `participate`-only settings.
public struct LabParticipateOptions: Equatable, Sendable {
  public var eventCode: String = ""
  public var role: LabRole = .auto
  /// Zero is a hold: stay on the radio for the whole timeout and report what
  /// was seen. That is the default because the usual reason to run this is to
  /// be an extra participant for the phones, not to pass a rendezvous.
  public var expectPeers: Int = 0
  public var relayEnabled: Bool = false
  /// Nil leaves the engine's own default in place, which is also what the
  /// beid apps use: neither iOS nor Android calls `configure` with ENIN
  /// parameters. Setting one here is for an event whose definition differs.
  public var eninSeconds: Int?
  public var eninMode: LabEninMode?
}

/// The whole parsed command line.
public struct LabOptions: Equatable, Sendable {
  public var subcommand: LabSubcommand
  public var logLevel: LabLogLevel = .info
  public var timeoutSeconds: TimeInterval = 120
  public var logPath: String?
  /// The run's label, already reduced to the 8 hex characters every line
  /// carries.
  public var eventIdPrefix: String?
  public var observe = LabObserveOptions()
  public var venue = LabVenueOptions()
  public var participate = LabParticipateOptions()

  /// The engine clamps `eninSeconds` into this range silently
  /// (`BarnardEngine.configure`). Refusing out-of-range input is how an
  /// operator who asks for 5 finds out they would have got 12, rather than
  /// reading a comparable-looking log derived from a different window.
  static let eninSecondsRange = 12...3600

  public static let usage = """
    usage: beid-lab-cli <observe|venue|participate> [options]

      observe       record advertisements on the air without connecting to anything
      venue         serve a signed event-info container and advertise
      participate   join an event code, scan and advertise, report peers

    common options
      --log-level error|info|debug|trace  how much reaches the log (default: info)
      -v                                  same as --log-level debug
      -vv                                 same as --log-level trace
      --timeout <seconds>                 run duration (default: 120)
      --log <path>                        also write every line to this file
      --event-id <hex>                    run label; its first 8 hex go in every line
      -h, --help                          this text

    observe options
      --lost-after <seconds>              quiet time before peer_lost (default: 10)
      --repeat-every <seconds>            gap between repeat peer_seen lines, 0 for
                                          every sighting (default: 5)

    venue options
      --container <path>                  file holding the signed hop-zero B005 v2 container
      --container-hex <hex>               the same bytes as hex

    participate options
      --event-code <code>                 event to join (required)
      --role advertise|scan|auto          radio role (default: auto)
      --expect-peers <n>                  peers required to pass; 0 holds for the whole
                                          timeout (default: 0)
      --relay on|off                      spec 134 participant relay (default: off)
      --enin-seconds <n>                  ENIN length, 12-3600 (default: the engine's)
      --enin-mode fixedLength|beaconSlot  ENIN mode (default: the engine's)
    """

  public static func parse(_ arguments: [String]) throws -> LabOptions {
    // Help is answered before anything else, including the subcommand, so
    // `beid-lab-cli --help` on a host with nothing configured still explains
    // itself.
    if arguments.contains("-h") || arguments.contains("--help") {
      throw LabArgumentError.helpRequested
    }
    guard let first = arguments.first else { throw LabArgumentError.missingSubcommand }
    guard let subcommand = LabSubcommand(rawValue: first) else {
      throw LabArgumentError.unknownSubcommand(first)
    }

    var options = LabOptions(subcommand: subcommand)
    var sawContainerFile = false
    var sawContainerHex = false
    var index = 1

    func value(for flag: String) throws -> String {
      index += 1
      guard index < arguments.count else { throw LabArgumentError.missingValue(flag) }
      return arguments[index]
    }

    /// A flag that belongs to a different subcommand is a distinct error from
    /// one that belongs to none: the first is a wrong command, the second is
    /// a typo, and telling an operator which cuts a round trip.
    func require(_ flag: String, _ owner: LabSubcommand) throws {
      guard subcommand == owner else { throw LabArgumentError.flagNotValidHere(flag, subcommand) }
    }

    func positiveSeconds(_ flag: String, allowingZero: Bool = false) throws -> TimeInterval {
      let raw = try value(for: flag)
      guard let parsed = TimeInterval(raw), parsed.isFinite, allowingZero ? parsed >= 0 : parsed > 0
      else {
        throw LabArgumentError.badValue(flag, raw)
      }
      return parsed
    }

    while index < arguments.count {
      let flag = arguments[index]
      switch flag {
      // MARK: common
      case "--log-level":
        let raw = try value(for: flag)
        guard let level = LabLogLevel(rawValue: raw) else {
          throw LabArgumentError.badValue(flag, raw)
        }
        options.logLevel = level
      case "-v":
        options.logLevel = .debug
      case "-vv":
        options.logLevel = .trace
      case "--timeout":
        options.timeoutSeconds = try positiveSeconds(flag)
      case "--log":
        options.logPath = try value(for: flag)
      case "--event-id":
        let raw = try value(for: flag)
        guard let prefix = LabRedaction.eventIdPrefix(raw) else {
          throw LabArgumentError.badValue(flag, raw)
        }
        options.eventIdPrefix = prefix

      // MARK: observe
      case "--lost-after":
        try require(flag, .observe)
        options.observe.lostAfterSeconds = try positiveSeconds(flag)
      case "--repeat-every":
        try require(flag, .observe)
        options.observe.repeatEverySeconds = try positiveSeconds(flag, allowingZero: true)

      // MARK: venue
      case "--container":
        try require(flag, .venue)
        let raw = try value(for: flag)
        // Caught here rather than left to fail as a missing file, so the
        // refusal explains the rule instead of blaming the path.
        guard !raw.contains("://") else { throw LabArgumentError.networkSourceRefused(flag) }
        guard !raw.isEmpty else { throw LabArgumentError.badValue(flag, raw) }
        options.venue.container = .file(raw)
        sawContainerFile = true
      case "--container-hex":
        try require(flag, .venue)
        let raw = try value(for: flag)
        guard raw.count % 2 == 0, LabRedaction.isHex(raw) else {
          throw LabArgumentError.badValue(flag, raw)
        }
        options.venue.container = .hex(raw.lowercased())
        sawContainerHex = true

      // MARK: participate
      case "--event-code":
        try require(flag, .participate)
        let raw = try value(for: flag)
        guard !raw.isEmpty else { throw LabArgumentError.badValue(flag, raw) }
        options.participate.eventCode = raw
      case "--role":
        try require(flag, .participate)
        let raw = try value(for: flag)
        guard let role = LabRole(rawValue: raw) else { throw LabArgumentError.badValue(flag, raw) }
        options.participate.role = role
      case "--expect-peers":
        try require(flag, .participate)
        let raw = try value(for: flag)
        guard let parsed = Int(raw), parsed >= 0 else {
          throw LabArgumentError.badValue(flag, raw)
        }
        options.participate.expectPeers = parsed
      case "--relay":
        try require(flag, .participate)
        let raw = try value(for: flag)
        switch raw {
        case "on": options.participate.relayEnabled = true
        case "off": options.participate.relayEnabled = false
        default: throw LabArgumentError.badValue(flag, raw)
        }
      case "--enin-seconds":
        try require(flag, .participate)
        let raw = try value(for: flag)
        guard let parsed = Int(raw), Self.eninSecondsRange.contains(parsed) else {
          throw LabArgumentError.badValue(flag, raw)
        }
        options.participate.eninSeconds = parsed
      case "--enin-mode":
        try require(flag, .participate)
        let raw = try value(for: flag)
        guard let mode = LabEninMode(rawValue: raw) else {
          throw LabArgumentError.badValue(flag, raw)
        }
        options.participate.eninMode = mode

      default:
        throw LabArgumentError.unknownFlag(flag)
      }
      index += 1
    }

    switch subcommand {
    case .observe:
      break
    case .venue:
      if sawContainerFile && sawContainerHex { throw LabArgumentError.conflictingContainerSources }
      guard options.venue.container != nil else { throw LabArgumentError.missingContainerSource }
    case .participate:
      guard !options.participate.eventCode.isEmpty else { throw LabArgumentError.missingEventCode }
    }
    return options
  }

  /// `--log` read straight off the raw argument list.
  ///
  /// The emitter has to exist before parsing, because an argument error still
  /// has to produce a `result` line, and full parsing cannot happen first
  /// without ordering the two the other way round. A hint read is enough: a
  /// malformed `--log` simply produces no log file.
  public static func logPathHint(_ arguments: [String]) -> String? {
    guard let flagIndex = arguments.firstIndex(of: "--log"),
      arguments.index(after: flagIndex) < arguments.endIndex
    else { return nil }
    return arguments[arguments.index(after: flagIndex)]
  }

  /// The level to use before parsing succeeds, so an argument error made with
  /// `-vv` on the command line is still reported at that level.
  public static func logLevelHint(_ arguments: [String]) -> LabLogLevel {
    var level = LabLogLevel.info
    var index = 0
    while index < arguments.count {
      switch arguments[index] {
      case "-v": level = .debug
      case "-vv": level = .trace
      case "--log-level":
        if index + 1 < arguments.count, let parsed = LabLogLevel(rawValue: arguments[index + 1]) {
          level = parsed
        }
        index += 1
      default: break
      }
      index += 1
    }
    return level
  }
}
