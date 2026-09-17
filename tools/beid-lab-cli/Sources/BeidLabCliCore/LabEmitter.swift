// Use of this source code is governed by a BSD-style license.

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
  private let eventIdPrefix: String?
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
