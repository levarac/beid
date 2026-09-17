// Use of this source code is governed by a BSD-style license.

/// How much of the run reaches the log.
///
/// The four levels are a severity order, not a set of independent switches:
/// a configured level admits itself and everything above it in severity, so
/// `--log-level debug` keeps the milestone lines rather than replacing them.
/// That is what makes a single saved log filterable after the fact — the
/// reason Ken asked for the `level` field to be on every line.
public enum LabLogLevel: String, CaseIterable, Comparable, Sendable {
  /// The run's verdict and the reasons it could not proceed. The floor: a log
  /// captured at this level still tells you how the run ended.
  case error
  /// The milestone stages issue #588 specifies.
  case info
  /// Every Barnard engine event and debug callback, mapped field by field.
  case debug
  /// Adds raw bytes for non-secret fields and the engine's own reason codes.
  case trace

  /// Severity rank, ascending in verbosity. `error` is 0 so that "admits"
  /// is a `<=` on this number and needs no table.
  public var rank: Int {
    switch self {
    case .error: return 0
    case .info: return 1
    case .debug: return 2
    case .trace: return 3
    }
  }

  /// Whether a line written at `lineLevel` is printed when this level is
  /// configured.
  public func admits(_ lineLevel: LabLogLevel) -> Bool {
    lineLevel.rank <= rank
  }

  public static func < (lhs: LabLogLevel, rhs: LabLogLevel) -> Bool {
    lhs.rank < rhs.rank
  }
}
