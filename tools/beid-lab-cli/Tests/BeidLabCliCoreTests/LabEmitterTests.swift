// Use of this source code is governed by a BSD-style license.

import XCTest

@testable import BeidLabCliCore

private final class RecordingSink: LabLineSink {
  var lines: [String] = []
  var closeCount = 0
  func write(line: String) { lines.append(line) }
  func close() { closeCount += 1 }
}

/// `LabLogLevelTests` proves the comparison; this proves the emitter actually
/// consults it, which is the half that silently regresses.
final class LabEmitterTests: XCTestCase {
  private let instant = Date(timeIntervalSince1970: 1_789_610_400.123)

  private func emitter(
    _ level: LabLogLevel, sink: RecordingSink, eventIdPrefix: String? = "1a2b3c4d"
  ) -> LabEmitter {
    LabEmitter(
      level: level, mode: .observe, eventIdPrefix: eventIdPrefix, sinks: [sink],
      now: { self.instant })
  }

  func testLinesAboveTheConfiguredLevelAreDropped() {
    let sink = RecordingSink()
    let emitter = self.emitter(.info, sink: sink)
    emitter.emit(.scanStart, at: .info)
    emitter.emit(.engineDebug, at: .debug)
    emitter.emit(.discovery, at: .trace)
    XCTAssertEqual(sink.lines.count, 1)
    XCTAssertEqual(emitter.emittedCount, 1)
    XCTAssertTrue(sink.lines[0].contains(#""stage":"scan_start""#))
  }

  func testRaisingTheLevelKeepsTheLowerOnesRatherThanReplacingThem() {
    let sink = RecordingSink()
    let emitter = self.emitter(.trace, sink: sink)
    emitter.emit(.scanStart, at: .info)
    emitter.emit(.engineDebug, at: .debug)
    emitter.emit(.discovery, at: .trace)
    XCTAssertEqual(sink.lines.count, 3)
  }

  func testWantsMatchesWhatEmitActuallyDoes() {
    let sink = RecordingSink()
    let emitter = self.emitter(.debug, sink: sink)
    for level in LabLogLevel.allCases {
      let before = sink.lines.count
      emitter.emit(.state, at: level)
      XCTAssertEqual(sink.lines.count > before, emitter.wants(level), "level=\(level.rawValue)")
    }
  }

  /// The one line that must never be filtered away.
  func testTheResultLineSurvivesTheStrictestLevel() {
    let sink = RecordingSink()
    let emitter = self.emitter(.error, sink: sink)
    emitter.emit(.scanStart, at: .info)
    emitter.emitResult(.timeout, detail: "no peers in 120s")
    XCTAssertEqual(sink.lines.count, 1)
    XCTAssertTrue(sink.lines[0].contains(#""stage":"result""#))
    XCTAssertTrue(sink.lines[0].contains(#""result":"timeout""#))
    XCTAssertTrue(sink.lines[0].contains(#""detail":"no peers in 120s""#))
  }

  /// Every exit path calls this, including the signal handler while another
  /// path is already finishing, so a second call must not append a second
  /// verdict to the same log.
  func testOnlyTheFirstResultIsWritten() {
    let sink = RecordingSink()
    let emitter = self.emitter(.info, sink: sink)
    emitter.emitResult(.ok, detail: "first")
    emitter.emitResult(.interrupted, detail: "second")
    XCTAssertEqual(sink.lines.count, 1)
    XCTAssertTrue(sink.lines[0].contains("first"))
    XCTAssertEqual(sink.closeCount, 1)
  }

  func testTheRunLabelIsStampedOnEveryLine() {
    let sink = RecordingSink()
    let emitter = self.emitter(.info, sink: sink)
    emitter.emit(.scanStart, at: .info)
    emitter.emitResult(.ok, detail: "done")
    XCTAssertEqual(sink.lines.count, 2)
    for line in sink.lines { XCTAssertTrue(line.contains(#""event":"1a2b3c4d""#)) }
  }

  func testAnUnlabelledRunStillCarriesTheKey() {
    let sink = RecordingSink()
    let emitter = self.emitter(.info, sink: sink, eventIdPrefix: nil)
    emitter.emit(.scanStart, at: .info)
    XCTAssertTrue(sink.lines[0].contains(#""event":null"#))
  }
}
