// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import BeidSharedKit
import Combine
import Foundation

/// Observes UI projections only. The shared recorder owns the output format
/// and retention. The subscriptions last for the root coordinator's lifetime.
@MainActor
final class SupportDiagnostics {
  let recorder = BeidSharedKit.support.SupportBundleRecorder()
  private var subscriptions = Set<AnyCancellable>()

  init(
    phases: AnyPublisher<ScanPhase, Never>,
    refusalReasons: AnyPublisher<String?, Never>,
    ownerKeyFailures: AnyPublisher<OwnerKeyOperationFailure?, Never>,
    clock: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) }
  ) {
    phases.sink { [weak self] phase in
      self?.recorder.record(
        state: Self.state(for: phase),
        failure: Self.failure(for: phase),
        timestampMs: clock()
      )
    }.store(in: &subscriptions)
    ownerKeyFailures.compactMap { $0 }.sink { [weak self] failure in
      switch failure {
      case .unavailable:
        self?.recorder.record(
          state: .OWNER_KEY_UNAVAILABLE,
          failure: .OWNER_KEY_UNAVAILABLE,
          timestampMs: clock()
        )
      }
    }.store(in: &subscriptions)
    refusalReasons.compactMap { $0 }.sink { [weak self] key in
      self?.recorder.record(
        state: .JOIN_FAILED,
        failure: BeidSharedKit.support.supportFailureForReasonKey(key: key),
        timestampMs: clock()
      )
    }.store(in: &subscriptions)
  }

  func exportJson(bundle: Bundle = .main) -> String {
    recorder.exportJson(
      platform: .IOS,
      appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
      build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
      gitHeight: bundle.object(forInfoDictionaryKey: "BeidGitHeight") as? String ?? ""
    )
  }

  private static func state(for phase: ScanPhase) -> BeidSharedKit.support.SupportState {
    switch phase {
    case .idle: return .IDLE
    case .sensing: return .SENSING
    case .eventFound: return .EVENT_FOUND
    case .recording: return .RECORDING
    case .signalLost: return .SIGNAL_LOST
    }
  }

  private static func failure(for phase: ScanPhase) -> BeidSharedKit.support.SupportFailure {
    if case .signalLost = phase { return .SIGNAL_LOST }
    return .NONE
  }
}
