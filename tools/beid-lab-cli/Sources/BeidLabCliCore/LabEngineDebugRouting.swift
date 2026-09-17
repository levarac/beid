// Use of this source code is governed by a BSD-style license.

/// Where one Barnard debug callback belongs in the log: which stage, at which
/// level, with which verdict.
///
/// ## Why this is a value in the core library rather than a `switch` at the
/// call site
///
/// It used to be that `switch`, and it shipped broken. The mapping computed a
/// promoted level, gated on it, and then passed a hardcoded `.debug` to
/// `emit`, which dropped every promoted line at the default level. The whole
/// point of the promotion — that a run which resolved nothing says so at the
/// level an operator actually runs — was defeated by one token, and **no test
/// could go red**, because the mapping lived in the executable target and no
/// test target can reach it.
///
/// So the decision moved here and the effect stayed there. This type names a
/// stage, a level and a result together; the call site cannot pick a different
/// level from the one the gate used, because there is only one value and it
/// carries both. Reintroducing that bug now requires ignoring a field rather
/// than forgetting one.
///
/// It takes a `String` and an optional `Bool` rather than a `BarnardDebugEvent`
/// on purpose: that keeps `BeidLabCliCore` free of the SDK, so the suite that
/// pins this runs on a host with no Bluetooth and no Barnard checkout.
public struct LabEngineDebugRouting: Equatable, Sendable {
  public let stage: LabStage
  public let level: LabLogLevel
  public let result: LabResult

  public init(stage: LabStage, level: LabLogLevel, result: LabResult) {
    self.stage = stage
    self.level = level
    self.result = result
  }

  /// Routes a Barnard debug event by name.
  ///
  /// Most names are diagnostic noise and land on `engine_debug` at `debug`.
  /// Two families are the run's finding rather than noise, and are promoted:
  /// given their own stage so they are greppable, and raised to `info` so a
  /// default-level log shows them.
  ///
  /// - Parameters:
  ///   - name: the engine's own debug event name, verbatim.
  ///   - matches: the `matches` field when the event carries one. Only the
  ///     B004 family does, and it is what turns that line into a verdict.
  public static func routing(forDebugEventNamed name: String, matches: Bool?)
    -> LabEngineDebugRouting
  {
    switch name {
    // The event-code-hash gate. Whether it matched decides whether a peer
    // resolves at all, which makes it the most consequential line in a
    // `participate` run.
    case "gatt_read_event_code_hash", "gatt_respond_event_code_hash":
      return LabEngineDebugRouting(
        stage: .gattB004, level: .info,
        result: matches.map { $0 ? .match : .mismatch } ?? .ok)
    case "gatt_b004_mismatch":
      return LabEngineDebugRouting(
        stage: .gattB004, level: .info, result: matches == true ? .match : .mismatch)

    // The GATT exchange that did not finish. Run 2 on 2026-09-17 was 18 of
    // these out of 18 attempts, and reconstructing that needed a `-v` capture
    // nobody had asked for in advance.
    case "gatt_exchange_timeout":
      // Carries the engine's own `seconds`, which is the only way its connect
      // timeout becomes observable: the constant itself is private.
      return LabEngineDebugRouting(stage: .gattResolution, level: .info, result: .timeout)
    case "gatt_resolution_failed", "gatt_read_failed":
      return LabEngineDebugRouting(stage: .gattResolution, level: .info, result: .rejected)
    // A backoff is the consequence of a failure already reported, so it is not
    // promoted: at `info` it would double every failure.
    case "gatt_resolution_backoff":
      return LabEngineDebugRouting(stage: .gattResolution, level: .debug, result: .ok)

    case "connect_attempt", "connected", "connect_queue_full":
      return LabEngineDebugRouting(stage: .gattConnect, level: .debug, result: .ok)

    default:
      return LabEngineDebugRouting(stage: .engineDebug, level: .debug, result: .ok)
    }
  }

  /// The names this routing promotes above `debug`. Exposed so a test can
  /// assert the promoted set rather than restate it, and so the set cannot be
  /// widened without something noticing.
  public static let promotedEventNames: Set<String> = [
    "gatt_read_event_code_hash", "gatt_respond_event_code_hash", "gatt_b004_mismatch",
    "gatt_exchange_timeout", "gatt_resolution_failed", "gatt_read_failed",
  ]
}
