// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import BeidSharedKit
import Foundation

/// Supplies one trusted HTTP `Date` header, or nil when none could be read.
protocol TrustedDateSource: Sendable {
  func fetchDateHeader() async -> String?
}

/// `HEAD` to the operator origin; any HTTP status is fine, only `Date` is read.
///
/// The origin is TLS-authenticated, which is the whole reason it is trusted
/// (beid#464, `docs/decisions/issue-464-clock-skew-preflight.md`), so a
/// missing or non-HTTPS origin is an unmeasurable clock, never a fallback.
struct OperatorDateHeaderSource: TrustedDateSource {
  let origin: URL?

  /// `https://host[:port]/` of an operator URL template, or nil.
  static func origin(fromTemplate template: String?) -> URL? {
    guard let template, !template.isEmpty else { return nil }
    let escaped = template
      .replacingOccurrences(of: "{", with: "%7B")
      .replacingOccurrences(of: "}", with: "%7D")
    guard let components = URLComponents(string: escaped),
      components.scheme == "https",
      let host = components.host, !host.isEmpty
    else { return nil }
    var origin = URLComponents()
    origin.scheme = "https"
    origin.host = host
    origin.port = components.port
    origin.path = "/"
    return origin.url
  }

  func fetchDateHeader() async -> String? {
    guard let origin else { return nil }
    var request = URLRequest(url: origin, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 4)
    request.httpMethod = "HEAD"
    request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
    let session = URLSession(configuration: .ephemeral)
    defer { session.finishTasksAndInvalidate() }
    guard let result = try? await session.data(for: request) else { return nil }
    return (result.1 as? HTTPURLResponse)?.value(forHTTPHeaderField: "Date")
  }
}

/// Thin native adapter over the shared `ClockPreflight` (beid#464): it reads
/// the clocks, performs the request, and hands the readings to shared, which
/// owns the interval, the cache and the verdict.
///
/// `stateKey` is nil until the first check finishes (and while a measurement
/// is in flight); after that it is one of shared's frozen keys
/// (`clockPreflightStateKey`), so a failed fetch surfaces as
/// `"undeterminable"` rather than as nothing.
@MainActor
final class ClockPreflightController: ObservableObject {
  /// The `eninSeconds` beid's Barnard engine runs at. beid never configures
  /// the engine's ENIN length (see `EventJoinControlling.joinAndStart`), so it
  /// runs at the SDK default, and Barnard 0.9.2 does not expose the value it
  /// holds. Named once so the preflight is judged against the deployment
  /// value; change it together with any Barnard ENIN configuration.
  nonisolated static let barnardEngineEninSeconds: Int32 = 300

  @Published private(set) var stateKey: String?

  private let preflight = BeidSharedKit.clock.ClockPreflight()
  private let source: any TrustedDateSource
  private let wallMillis: () -> Int64
  private let monotonicMillis: () -> Int64
  private let eninSeconds: Int32
  private var inFlight = false

  init(
    source: any TrustedDateSource,
    wallMillis: @escaping () -> Int64 = { Int64((Date().timeIntervalSince1970 * 1_000).rounded(.down)) },
    // CLOCK_MONOTONIC_RAW keeps counting while the device sleeps, which shared
    // requires; `ProcessInfo.systemUptime` does not.
    monotonicMillis: @escaping () -> Int64 = { Int64(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) / 1_000_000) },
    eninSeconds: Int32 = ClockPreflightController.barnardEngineEninSeconds
  ) {
    self.source = source
    self.wallMillis = wallMillis
    self.monotonicMillis = monotonicMillis
    self.eninSeconds = eninSeconds
  }

  /// Measures when shared says the cache cannot answer (or `force` is set),
  /// then publishes the state. A check requested while one is running is
  /// dropped; the running one publishes.
  func check(force: Bool = false) async {
    guard !inFlight else { return }
    inFlight = true
    defer { inFlight = false }
    if force || preflight.needsMeasurement(nowMonotonicMillis: monotonicMillis(), eninSeconds: eninSeconds) {
      stateKey = nil
      let requestWall = wallMillis()
      let requestMonotonic = monotonicMillis()
      let header = await source.fetchDateHeader()
      preflight.recordMeasurement(
        requestWallMillis: requestWall,
        requestMonotonicMillis: requestMonotonic,
        responseMonotonicMillis: monotonicMillis(),
        dateHeader: header
      )
    }
    stateKey = BeidSharedKit.clock.clockPreflightStateKey(
      state: preflight.state(
        nowWallMillis: wallMillis(),
        nowMonotonicMillis: monotonicMillis(),
        eninSeconds: eninSeconds
      )
    )
  }
}
