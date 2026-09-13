import XCTest
import BeidSharedKit
@testable import Beid

/// Deterministic tests for the production verifier's continuation boundary.
/// The generated RegistryResolution type has no public Swift constructor, so
/// the nil completion path is used to exercise callback/cancellation ordering;
/// the operation itself is the production owner used by resolveRegistry.
@MainActor
final class VenueRegistryResolutionOperationTests: XCTestCase {
  typealias Operation = ProductionVenueBundleVerifier.RegistryResolutionOperation

  private final class SpyRequest: VenueRegistryRequestCancellable {
    var cancelCount = 0
    func cancel() { cancelCount += 1 }
  }

  func testCancellationBeforeContinuationBindingResumesExactlyOnce() async {
    let operation = Operation()
    operation.cancel()
    let result = await withCheckedContinuation {
      (continuation: CheckedContinuation<
        ExportedKotlinPackages.org.levarac.parallax.registry.RegistryResolution?, Never
      >) in
      operation.setContinuation(continuation)
    }
    XCTAssertNil(result)
    operation.cancel()
    operation.finish(nil)
  }

  func testCancellationCancelsHandleReturnedAfterCancellationExactlyOnce() async {
    let operation = Operation()
    let request = SpyRequest()
    operation.cancel()
    operation.setRequest(request)
    XCTAssertEqual(request.cancelCount, 1)
    operation.setRequest(request)
    XCTAssertEqual(request.cancelCount, 2, "a newly supplied handle is cancelled immediately")
  }

  func testCancellationAfterContinuationBindingResumesAndLateCallbacksAreIgnored() async {
    let operation = Operation()
    let task = Task {
      await withCheckedContinuation {
        (continuation: CheckedContinuation<
          ExportedKotlinPackages.org.levarac.parallax.registry.RegistryResolution?, Never
        >) in
        operation.setContinuation(continuation)
      }
    }
    while !operation.hasContinuation { await Task.yield() }
    operation.cancel()
    let result = await task.value
    XCTAssertNil(result)
    operation.finish(nil)
    operation.cancel()
  }

  func testNormalCallbackReleasesHandleWithoutCancellingIt() async {
    let operation = Operation()
    let request = SpyRequest()
    let task = Task {
      await withCheckedContinuation {
        (continuation: CheckedContinuation<
          ExportedKotlinPackages.org.levarac.parallax.registry.RegistryResolution?, Never
        >) in
        operation.setContinuation(continuation)
        operation.setRequest(request)
        operation.finish(nil)
      }
    }
    let result = await task.value
    XCTAssertNil(result)
    XCTAssertEqual(request.cancelCount, 0)
    operation.cancel()
  }

  func testCallbackBeforeRequestHandleReturnStillCompletesOnce() async {
    let operation = Operation()
    let task = Task {
      await withCheckedContinuation {
        (continuation: CheckedContinuation<
          ExportedKotlinPackages.org.levarac.parallax.registry.RegistryResolution?, Never
        >) in
        operation.setContinuation(continuation)
        // A synchronous SDK callback can happen before resolve() returns its
        // request handle. This is the same completion gate used in production.
        operation.finish(nil)
      }
    }
    let result = await task.value
    XCTAssertNil(result)
    operation.cancel()
    operation.finish(nil)
  }
}
