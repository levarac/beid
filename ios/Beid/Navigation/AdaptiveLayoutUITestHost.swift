// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

#if DEBUG
import notify
import SwiftUI
import UIKit

/// Opt-in instrumentation, never installed in Release or ordinary Debug runs.
/// Commands alter UIKit traits/geometry only; they cannot start, stop, finalize
/// or replace a session. Darwin notifications also work while an alert is modal.
enum AdaptiveLayoutUITestFixture {
  static func isEnabled(arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
    arguments.contains("-beid-ui-test") && arguments.contains("-beid-adaptive-continuity")
  }

  /// The ordinary demo has no Barnard timestamp. This opt-in stimulus has
  /// an actual emission time so the real elapsed-time presentation can run.
  static func observationTimestamp(
    arguments: [String] = ProcessInfo.processInfo.arguments, now: () -> Date = Date.init
  ) -> Date? {
    isEnabled(arguments: arguments) ? now() : nil
  }

  /// Extend the normal demo interpreter with paced observations, rather than
  /// changing its phase or incrementing a fake display count from a resize hook.
  static func extending(_ scenario: DemoScenario) -> DemoScenario {
    guard isEnabled() else { return scenario }
    let observations: [DemoScenario.Step] = (1...900).flatMap { _ in
      [
        .pause,
        .observeOneDemoDevice(displayId: "adaptive-observer", rpid: "adaptive-observer", enin: 4),
        .applyPhaseDecision,
      ]
    }
    return DemoScenario(identifier: scenario.identifier, event: scenario.event, steps: scenario.steps + observations)
  }
}

struct AdaptiveContinuityMetrics {
  let owner = UUID().uuidString
  var starts = 0
  var stops = 0
  var finalizations = 0
  var savedRecord = ""
}

struct AdaptiveLayoutUITestHost: UIViewRepresentable {
  let sensing: SensingCoordinator
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass

  func makeCoordinator() -> Controller { Controller(sensing: sensing) }

  func makeUIView(context: Context) -> WindowReader {
    WindowReader { [weak controller = context.coordinator] window in
      controller?.install(in: window)
    }
  }

  func updateUIView(_ uiView: WindowReader, context: Context) {
    // Observe the current owner even if a future root refactor replaces it.
    context.coordinator.sensing = sensing
    // Read the environment actually delivered to SwiftUI, not the requested
    // override. The test waits for this receipt after each command.
    context.coordinator.sizeClass = horizontalSizeClass == .regular ? "regular" : "compact"
  }

  static func dismantleUIView(_ uiView: WindowReader, coordinator: Controller) {
    coordinator.remove()
  }

  final class WindowReader: UIView {
    let onWindow: (UIWindow) -> Void

    init(onWindow: @escaping (UIWindow) -> Void) {
      self.onWindow = onWindow
      super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { return nil }

    override func didMoveToWindow() {
      super.didMoveToWindow()
      if let window { onWindow(window) }
    }
  }

  @MainActor
  final class Controller {
    var sizeClass = "" {
      didSet { window?.accessibilityIdentifier = "beid.layout.\(sizeClass)" }
    }
    var sensing: SensingCoordinator
    private weak var window: UIWindow?
    private var originalFrame = CGRect.zero
    private var receiptWindow: UIWindow?
    private let receipt = UILabel()
    private var timer: Timer?
    private var tokens: [Int32] = []
    private var command = "initial"

    init(sensing: SensingCoordinator) { self.sensing = sensing }

    func install(in window: UIWindow) {
      guard self.window == nil, let scene = window.windowScene else { return }
      self.window = window
      window.accessibilityIdentifier = "beid.layout.\(sizeClass)"
      originalFrame = window.frame
      guard AdaptiveLayoutUITestFixture.isEnabled() else { return }
      // A tiny non-key, noninteractive diagnostics window keeps the receipt
      // readable while UIKit makes a sheet or Stop alert accessibility-modal.
      // It neither changes the app's safe area nor consumes layout space.
      let overlay = UIWindow(windowScene: scene)
      overlay.frame = CGRect(x: originalFrame.minX + 20, y: originalFrame.minY + 60, width: 1, height: 1)
      overlay.windowLevel = .alert + 1
      overlay.isUserInteractionEnabled = false
      let controller = UIViewController()
      overlay.rootViewController = controller
      receipt.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
      receipt.text = "Layout continuity receipt"
      receipt.textColor = .clear
      receipt.isAccessibilityElement = true
      receipt.accessibilityIdentifier = "adaptive.receipt"
      controller.view.addSubview(receipt)
      overlay.isHidden = false
      receiptWindow = overlay
      for name in ["compact", "regular", "narrow", "full", "restore"] {
        var token: Int32 = 0
        let status = notify_register_dispatch("org.levarac.beid.ui-test.adaptive.\(name)", &token, .main) { [weak self] _ in
          MainActor.assumeIsolated { self?.apply(name) }
        }
        if status == 0 { tokens.append(token) }
      }
      timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
        MainActor.assumeIsolated { self?.publish() }
      }
      publish()
    }

    private func apply(_ name: String) {
      guard let window else { return }
      switch name {
      case "compact": window.traitOverrides.horizontalSizeClass = .compact
      case "regular": window.traitOverrides.horizontalSizeClass = .regular
      case "narrow":
        // This is real UIWindow geometry, deliberately NOT a claim that the
        // system resized UIWindowScene or entered iPad Split View.
        window.frame = CGRect(origin: originalFrame.origin,
                              size: CGSize(width: min(375, originalFrame.width - 32), height: originalFrame.height))
      case "full": window.frame = originalFrame
      case "restore":
        window.traitOverrides.remove(UITraitHorizontalSizeClass.self)
        window.frame = originalFrame
      default: return
      }
      command = name
      window.setNeedsLayout()
      window.layoutIfNeeded()
      publish()
    }

    private func publish() {
      guard let window else { return }
      var values = sensing.adaptiveContinuityReceipt
      values["command"] = command
      values["sizeClass"] = sizeClass
      values["width"] = window.bounds.width
      values["height"] = window.bounds.height
      values["rootWidth"] = window.rootViewController?.view.bounds.width ?? 0
      values["sceneWidth"] = sceneBounds.width
      values["sceneHeight"] = sceneBounds.height
      if let data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]) {
        receipt.accessibilityValue = String(decoding: data, as: UTF8.self)
      }
    }

    private var sceneBounds: CGRect {
      guard let scene = window?.windowScene else { return .zero }
      if #available(iOS 26, *) { return scene.effectiveGeometry.coordinateSpace.bounds }
      return scene.coordinateSpace.bounds
    }

    func remove() {
      timer?.invalidate()
      timer = nil
      if !tokens.isEmpty { apply("restore") }
      tokens.forEach { _ = notify_cancel($0) }
      tokens = []
      receiptWindow?.isHidden = true
      receiptWindow = nil
      window = nil
    }
  }
}
#endif
