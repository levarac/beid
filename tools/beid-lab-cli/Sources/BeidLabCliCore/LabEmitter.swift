// SPDX-License-Identifier: MIT

import Foundation

/// Where finished lines go. A protocol so the level filter can be tested
/// without a file or a terminal.
public protocol LabLineSink: AnyObject {
  func write(line: String)
  func close()
}

/// stdout, line buffered.
///
/// The buffering is load bearing over ssh: the C library buffers 4 KiB at a
/// time when stdout is a pipe or a file, so without this a remote operator
/// watching a 120-second run sees nothing until it ends.
public final class LabStandardOutputSink: LabLineSink {
  public init() { setvbuf(stdout, nil, _IOLBF, 0) }
  public func write(line: String) { print(line) }
  public func close() {}
}

/// A `--log` file, written alongside stdout rather than instead of it.
public final class LabFileSink: LabLineSink {
  private let handle: FileHandle?

  public init(path: String) {
    let manager = FileManager.default
    if !manager.fileExists(atPath: path) {
      manager.createFile(atPath: path, contents: nil)
    }
    handle = FileHandle(forWritingAtPath: path)
    try? handle?.truncate(atOffset: 0)
  }

  public func write(line: String) {
    guard let handle, let data = (line + "\n").data(using: .utf8) else { return }
    handle.write(data)
  }

  public func close() { try? handle?.close() }
}

/// Applies the level filter, stamps the shared fields, and fans out to every
/// sink.
///
/// One object owns both the filter and the stamping because they are the same
/// decision seen twice: a line's level decides whether it is printed *and*
/// how much of its own content it may carry. Splitting them is how a call
/// site ends up formatting a full RPID into a string that is then dropped —
/// or worse, kept.
public final class LabEmitter {
  public let level: LabLogLevel
  private let mode: LabSubcommand
  private var eventIdPrefix: String?
  private let sinks: [LabLineSink]
  private let now: () -> Date
  private var closed = false

  public private(set) var emittedCount = 0

  public init(
    level: LabLogLevel,
    mode: LabSubcommand,
    eventIdPrefix: String?,
    sinks: [LabLineSink],
    now: @escaping () -> Date = Date.init
  ) {
    self.level = level
    self.mode = mode
    self.eventIdPrefix = eventIdPrefix
    self.sinks = sinks
    self.now = now
  }

  /// Whether a call site should bother building a payload for `lineLevel`.
  /// Exposed so the expensive mappings — hex encoding a GATT value, walking a
  /// debug dictionary — are skipped rather than built and discarded.
  public func wants(_ lineLevel: LabLogLevel) -> Bool { level.admits(lineLevel) }

  /// Labels the rest of the run with an event id the run discovered rather
  /// than was told.
  ///
  /// `venue` learns its event id by decoding the container it was handed, so
  /// without this every line before the decode would carry `null` and every
  /// line after it would too. An explicit `--event-id` always wins: an
  /// operator who labelled the run meant that label, and a container that
  /// disagrees is a finding they need to see in the `venue_ready` line rather
  /// than have silently overwritten.
  public func adoptEventId(_ prefix: String) {
    guard eventIdPrefix == nil else { return }
    eventIdPrefix = prefix
  }

  public func emit(
    _ stage: LabStage,
    at lineLevel: LabLogLevel,
    result: LabResult = .ok,
    data: [String: LabValue] = [:]
  ) {
    guard wants(lineLevel) else { return }
    let line = LabLine(
      timestamp: now(),
      level: lineLevel,
      mode: mode,
      stage: stage,
      eventId: eventIdPrefix,
      result: result,
      data: data
    )
    guard let encoded = try? line.encoded() else { return }
    emittedCount += 1
    for sink in sinks { sink.write(line: encoded) }
  }

  /// Emits a routed engine debug event.
  ///
  /// This overload exists because the four-argument one was misused: a call
  /// site computed a promoted level, gated on it, and then passed a literal
  /// `.debug` to `emit`, so every promoted line was dropped at the default
  /// level (chk-beid-590, D1). A test could not catch it, because the call
  /// site is in the executable target and `BarnardDebugEvent` has no public
  /// initializer, so no test can synthesise one to drive it.
  ///
  /// So the fix is not a test — it is that **there is no longer a level
  /// argument to get wrong**. The routing carries stage, level and result
  /// together, and the gate and the emission read the same field.
  public func emit(_ routing: LabEngineDebugRouting, data: [String: LabValue] = [:]) {
    emit(routing.stage, at: routing.level, result: routing.result, data: data)
  }

  /// The last line of every run, on every exit path. Written at
  /// `LabLine.resultLineLevel`, so no setting of `--log-level` can remove a
  /// run's verdict from its own log.
  public func emitResult(_ result: LabResult, detail: String, data: [String: LabValue] = [:]) {
    guard !closed else { return }
    closed = true
    var payload = data
    payload["detail"] = .string(detail)
    emit(.result, at: LabLine.resultLineLevel, result: result, data: payload)
    for sink in sinks { sink.close() }
  }
}
