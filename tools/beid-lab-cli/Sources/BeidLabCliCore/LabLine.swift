// Use of this source code is governed by a BSD-style license.

import Foundation

/// Which of the three radio behaviours a run is performing. Carried on every
/// line so logs from several hosts can be concatenated and still read.
public enum LabSubcommand: String, CaseIterable, Sendable {
  case observe
  case venue
  case participate
}

/// The stage vocabulary. These strings are the tool's wire contract with
/// whatever reads the log afterwards, so they are spelled out here and
/// asserted in the tests: renaming a Swift case must not silently rename a
/// stage a saved script greps for.
public enum LabStage: String, Sendable {
  /// The options this run was actually given, echoed once.
  case runStart = "run_start"
  case permissions = "permissions"
  case scanStart = "scan_start"
  /// Deliberately not `advertise_start`. `BarnardEngine` reports
  /// `isAdvertising = true` the moment advertising is requested and has no
  /// OS-confirmed success event (`docs/venue-serving-contract.md`), so this
  /// line records a request. Only a receiver proves the air.
  case advertiseRequested = "advertise_requested"
  case advertiseStop = "advertise_stop"
  /// One raw advertisement, `observe` only.
  case discovery = "discovery"
  case peerFirstSeen = "peer_first_seen"
  case peerLost = "peer_lost"
  /// The event-code-hash read and its verdict — the gate that decides whether
  /// a peer resolves at all.
  case gattB004 = "gatt_b004"
  case detection = "detection"
  case envelopeV2 = "envelope_v2"
  case state = "state"
  case relay = "relay"
  /// A Barnard event with no milestone of its own, at `debug`.
  case engineEvent = "engine_event"
  /// A Barnard debug callback, at `debug`.
  case engineDebug = "engine_debug"
  case constraint = "constraint"
  /// Something went wrong: an engine error, a rejected container, a denied
  /// radio.
  case failure = "failure"
  /// The last line of every run.
  case result = "result"
}

/// The `result` field: a short token, not a sentence, so a log can be
/// filtered on it.
public enum LabResult: String, Sendable {
  case ok
  case match
  case mismatch
  case timeout
  case rejected
  case unavailable
  case interrupted
}

/// A JSON value restricted to what this tool emits.
///
/// The restriction is the point. A `[String: Any]` payload accepts whatever
/// an SDK callback happens to contain, which is exactly how an unredacted
/// identifier reaches a log; every value here was named by a call site.
public enum LabValue: Encodable, Equatable, Sendable {
  case string(String)
  case int(Int)
  case double(Double)
  case bool(Bool)
  case array([LabValue])
  case null

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .string(let value): try container.encode(value)
    case .int(let value): try container.encode(value)
    case .double(let value): try container.encode(value)
    case .bool(let value): try container.encode(value)
    case .array(let values): try container.encode(values)
    case .null: try container.encodeNil()
    }
  }
}

/// One line of the log.
///
/// Every line carries the same seven keys whether or not it has anything to
/// put in them, because a reader filtering a mixed log with `jq` should not
/// have to know which stages happen to populate which field.
public struct LabLine: Encodable, Sendable {
  /// The verdict line is written at `error` so that it survives every
  /// setting of `--log-level`. A log with no verdict in it would be the one
  /// filtering mistake that cannot be recovered after the run.
  public static let resultLineLevel: LabLogLevel = .error

  public let timestamp: Date
  public let level: LabLogLevel
  public let mode: LabSubcommand
  public let stage: LabStage
  /// The first 8 hex characters of the run's event id, or nil when the run
  /// has no event identity — which is every `observe` run that was not given
  /// a `--event-id` label.
  public let eventId: String?
  public let result: LabResult
  public let data: [String: LabValue]

  public init(
    timestamp: Date,
    level: LabLogLevel,
    mode: LabSubcommand,
    stage: LabStage,
    eventId: String?,
    result: LabResult,
    data: [String: LabValue]
  ) {
    self.timestamp = timestamp
    self.level = level
    self.mode = mode
    self.stage = stage
    self.eventId = eventId
    self.result = result
    self.data = data
  }

  private enum CodingKeys: String, CodingKey {
    case timestamp = "ts"
    case level
    case mode
    case stage
    case eventId = "event"
    case result
    case data
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(Self.timestampFormatter.string(from: timestamp), forKey: .timestamp)
    try container.encode(level.rawValue, forKey: .level)
    try container.encode(mode.rawValue, forKey: .mode)
    try container.encode(stage.rawValue, forKey: .stage)
    // Encoded explicitly rather than as `Optional`, which would omit the key.
    if let eventId {
      try container.encode(eventId, forKey: .eventId)
    } else {
      try container.encodeNil(forKey: .eventId)
    }
    try container.encode(result.rawValue, forKey: .result)
    try container.encode(data, forKey: .data)
  }

  public func encoded() throws -> String {
    let encoder = JSONEncoder()
    // Sorted keys so two lines of the same stage are diffable, and unescaped
    // slashes so a path echoed in `run_start` is readable.
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(self)
    return String(decoding: data, as: UTF8.self)
  }

  /// UTC, milliseconds, `Z` suffix. Fixed locale and calendar: a lab host
  /// configured for a non-Gregorian calendar would otherwise write
  /// timestamps nothing can parse.
  private static let timestampFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
    return formatter
  }()
}
