// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import BeidSharedKit
import Foundation

/// Why acquisition never produced bytes to hand to the verifier.
///
/// Deliberately NOT part of `VenueImportFailure`. Failing to fetch is not a
/// verdict about a bundle: nothing was verified, so nothing may be reported
/// as rejected. Keeping the two apart is what stops a network error from
/// being displayed as "this bundle is invalid".
enum VenueAcquisitionFailure: String, CaseIterable, Hashable, Error {
  case unsupportedScheme
  case redirectRefused
  case oversize
  case unreadable
  case transportFailure
  case eventIdentityMismatch
  /// The request ran out its own clock. Separate from `transportFailure`
  /// because the operator's next move differs: a transport failure says the
  /// address or the network is wrong, a timeout says to try again, and at a
  /// venue on a crowded network that is the likely one.
  case timedOut
}

/// Bounded acquisition of the two public artifacts, from a file or over HTTPS.
///
/// Acquisition enforces a size ceiling so an unbounded read can never reach
/// the verifier, and refuses every redirect.
protocol VenueArtifactAcquiring: AnyObject {
  func acquire(bundleSource: URL, handoffSource: URL) async throws -> VenuePublicArtifact
  /// The bundle alone, for a handoff that did not arrive over the network.
  ///
  /// A handoff carried in a link's fragment never reaches a server, which is the
  /// property that lets a consumer treat it as coming from whoever handed the link
  /// over. Fetching it would throw that away, so the link path has bytes already and
  /// needs only the bundle those bytes name.
  func acquireBundle(bundleSource: URL) async throws -> Data
}

enum VenueArtifactBounds {
  /// The shared ceilings themselves, read through Swift Export rather than
  /// restated here, so the limit has exactly one definition.
  ///
  /// This is a transport ceiling, not a second opinion about validity: the
  /// shared decoder still enforces these same bounds, and refusing early only
  /// avoids reading an unbounded body into memory to be rejected afterwards.
  ///
  /// `parallax` sits outside the shared module's own root, so it is not
  /// flattened into `BeidSharedKit.<package>` and takes the fully-qualified
  /// exported path. Kotlin `Int` exports as `Swift.Int32`.
  static var maxBundleBytes: Int {
    Int(ExportedKotlinPackages.org.levarac.parallax.venue.MAX_VENUE_BUNDLE_BYTES)
  }

  static var maxHandoffBytes: Int {
    Int(ExportedKotlinPackages.org.levarac.parallax.venue.MAX_VENUE_HANDOFF_BYTES)
  }
}

/// Refuses every HTTP redirect rather than following it.
///
/// A redirect would mean the bytes came from a URL the operator did not name,
/// and the digest binding is checked after acquisition, not during it. There
/// is no same-origin allowance: an operator publishing a venue bundle can
/// publish a stable URL, so the simpler rule is the safer one.
private final class VenueRedirectRefusingDelegate: NSObject, URLSessionTaskDelegate {
  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}

final class VenueArtifactAcquisition: VenueArtifactAcquiring {
  private let session: URLSession
  private let redirectDelegate = VenueRedirectRefusingDelegate()

  /// A request that never answers and a request that fails are the same to an
  /// operator watching "Getting the pack." forever, except that the second one
  /// ends. `URLSession.shared` carries the system default of 60 seconds per
  /// request and 7 days per resource, and a venue device on a crowded network is
  /// exactly where the difference is felt, so this lane sets its own bounds
  /// rather than inheriting them.
  static let requestTimeoutSeconds: TimeInterval = 30

  private static func defaultSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = requestTimeoutSeconds
    configuration.timeoutIntervalForResource = requestTimeoutSeconds * 2
    // These bytes are verified by digest, never by cache freshness, and a stale
    // cached bundle would be re-verified anyway. Not caching keeps the acquired
    // bytes and the fetched bytes the same thing.
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    return URLSession(configuration: configuration)
  }

  init(session: URLSession? = nil) {
    self.session = session ?? Self.defaultSession()
  }

  func acquire(bundleSource: URL, handoffSource: URL) async throws -> VenuePublicArtifact {
    let bundleBytes = try await acquireBundle(bundleSource: bundleSource)
    let handoffBytes = try await read(handoffSource, cap: VenueArtifactBounds.maxHandoffBytes)
    return VenuePublicArtifact(bundleBytes: bundleBytes, handoffBytes: handoffBytes)
  }

  func acquireBundle(bundleSource: URL) async throws -> Data {
    try await read(bundleSource, cap: VenueArtifactBounds.maxBundleBytes)
  }

  private func read(_ source: URL, cap: Int) async throws -> Data {
    if source.isFileURL {
      return try readFile(source, cap: cap)
    }
    guard source.scheme?.lowercased() == "https" else {
      throw VenueAcquisitionFailure.unsupportedScheme
    }
    return try await readHTTPS(source, cap: cap)
  }

  /// Reads at most `cap + 1` bytes so oversize is detected without ever
  /// holding the whole oversized file.
  private func readFile(_ source: URL, cap: Int) throws -> Data {
    let scoped = source.startAccessingSecurityScopedResource()
    defer { if scoped { source.stopAccessingSecurityScopedResource() } }

    guard let handle = try? FileHandle(forReadingFrom: source) else {
      throw VenueAcquisitionFailure.unreadable
    }
    defer { try? handle.close() }

    guard let data = try? handle.read(upToCount: cap + 1) else {
      throw VenueAcquisitionFailure.unreadable
    }
    guard data.count <= cap else { throw VenueAcquisitionFailure.oversize }
    return data
  }

  /// Streams and aborts as soon as the cap is exceeded, so an oversize or
  /// endless body is never accumulated. A declared Content-Length over the
  /// cap is refused before any body is read.
  private func readHTTPS(_ source: URL, cap: Int) async throws -> Data {
    let (stream, response): (URLSession.AsyncBytes, URLResponse)
    do {
      (stream, response) = try await session.bytes(from: source, delegate: redirectDelegate)
    } catch {
      throw Self.failure(for: error)
    }

    guard let http = response as? HTTPURLResponse else {
      throw VenueAcquisitionFailure.transportFailure
    }
    // The refusing delegate returns the 3xx itself rather than following it.
    if (300...399).contains(http.statusCode) {
      throw VenueAcquisitionFailure.redirectRefused
    }
    guard (200...299).contains(http.statusCode) else {
      throw VenueAcquisitionFailure.transportFailure
    }
    if http.expectedContentLength > Int64(cap) {
      throw VenueAcquisitionFailure.oversize
    }

    var data = Data()
    data.reserveCapacity(min(cap, 64 * 1024))
    do {
      for try await byte in stream {
        data.append(byte)
        if data.count > cap { throw VenueAcquisitionFailure.oversize }
      }
    } catch let failure as VenueAcquisitionFailure {
      throw failure
    } catch {
      throw Self.failure(for: error)
    }
    return data
  }

  /// Timeouts are told apart from every other transport error, and nothing else
  /// is: this maps one URLError code and leaves the rest as they were.
  private static func failure(for error: Error) -> VenueAcquisitionFailure {
    (error as? URLError)?.code == .timedOut ? .timedOut : .transportFailure
  }
}
