// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import SwiftUI
import UIKit
import VisionKit

/// Reads a venue handoff link from a QR code with the platform camera (beid#597).
///
/// `DataScannerViewController` rather than a third-party scanner: the venue link
/// carrier is defined by `protocol/spec/v0.1/venue-bundle.md` as an ordinary QR
/// code, so nothing here needs a decoder the system does not already have.
///
/// Availability is checked, never assumed. `isSupported` is false on a device
/// without the Neural Engine and on the Simulator, and `isAvailable` is false when
/// camera access has been refused. The paste field is therefore the path that always
/// works, and this is an accelerator for it — a venue operator who cannot scan must
/// never be stuck.
///
/// The scanner does not decide whether a payload is a venue link. It hands back the
/// string; the view model asks `shared/` what it is. Deciding here would be a second
/// opinion about a link's validity, on one platform.
@MainActor
enum VenueLinkScanner {
  /// Why the Scan button is not on screen, or nil when it is.
  ///
  /// The two conditions are kept apart because they need different answers from
  /// the operator. `isSupported` is a fact about the hardware and nothing can be
  /// done about it. `isAvailable` goes false when the device is restricted from
  /// scanning — camera access refused, or a Screen Time restriction — and that
  /// is fixable in Settings, so the screen offers the way there.
  ///
  /// UNVERIFIED and worth checking on a device: whether `isAvailable` is true
  /// while camera permission is still UNDETERMINED. If it were false, hiding the
  /// button would be a dead end, because permission is requested by
  /// `startScanning()` and nothing would ever call it. The Settings line below
  /// keeps a way out even in that case, which is why it is written as guidance
  /// rather than as a diagnosis of which condition failed.
  enum Unavailability {
    case notSupported
    case restricted
  }

  static var unavailability: Unavailability? {
    guard DataScannerViewController.isSupported else { return .notSupported }
    guard DataScannerViewController.isAvailable else { return .restricted }
    return nil
  }

  /// Whether offering the button is honest on this device, right now.
  static var isAvailable: Bool { unavailability == nil }
}

struct VenueLinkScannerView: UIViewControllerRepresentable {
  /// Called with the first recognised payload. The view dismisses itself first so
  /// a second frame cannot deliver a different link into a screen already acting on
  /// the first one.
  let onScan: (String) -> Void
  /// Called when the scanner could not start. The sheet says so rather than
  /// showing a black rectangle with a Cancel button, which is what a swallowed
  /// `startScanning()` throw looks like to the person holding the iPad.
  let onStartFailure: (String) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(onScan: onScan)
  }

  func makeUIViewController(context: Context) -> VenueLinkScannerHost {
    VenueLinkScannerHost(delegate: context.coordinator, onStartFailure: onStartFailure)
  }

  func updateUIViewController(_ host: VenueLinkScannerHost, context: Context) {}

  static func dismantleUIViewController(_ host: VenueLinkScannerHost, coordinator: Coordinator) {
    host.scanner.stopScanning()
  }

  /// Hosts the scanner and starts it from `viewDidAppear`.
  ///
  /// `startScanning()` throws if the controller is not yet in a window, and a
  /// representable's `updateUIViewController` can run before it is. Swallowing
  /// that error there leaves a camera that simply never starts — at a venue, on a
  /// device where the Simulator cannot reproduce it, because scanning is
  /// unavailable there at all. `DataScannerViewController` is not `open`, so this
  /// is a container rather than a subclass.
  @MainActor
  final class VenueLinkScannerHost: UIViewController {
    let scanner: DataScannerViewController
    private let onStartFailure: (String) -> Void

    init(delegate: DataScannerViewControllerDelegate, onStartFailure: @escaping (String) -> Void) {
      self.onStartFailure = onStartFailure
      scanner = DataScannerViewController(
        recognizedDataTypes: [.barcode(symbologies: [.qr])],
        qualityLevel: .balanced,
        recognizesMultipleItems: false,
        isHighFrameRateTrackingEnabled: false,
        isHighlightingEnabled: true
      )
      super.init(nibName: nil, bundle: nil)
      scanner.delegate = delegate
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not available from a storyboard") }

    override func viewDidLoad() {
      super.viewDidLoad()
      addChild(scanner)
      scanner.view.frame = view.bounds
      scanner.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      view.addSubview(scanner.view)
      scanner.didMove(toParent: self)
    }

    override func viewDidAppear(_ animated: Bool) {
      super.viewDidAppear(animated)
      guard !scanner.isScanning else { return }
      do {
        try scanner.startScanning()
      } catch {
        // Reported, not swallowed. The camera never appears either way; the
        // difference is whether the operator is told to fall back to pasting or
        // left looking at a black sheet deciding the device is broken.
        onStartFailure(String(describing: error))
      }
    }
  }

  @MainActor
  final class Coordinator: NSObject, DataScannerViewControllerDelegate {
    private let onScan: (String) -> Void
    /// One payload per presentation. Without this the delegate fires again while
    /// the sheet is still dismissing, and the second link supersedes the first
    /// request the operator already saw start.
    private var hasDelivered = false

    init(onScan: @escaping (String) -> Void) {
      self.onScan = onScan
    }

    func dataScanner(_ scanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
      deliver(from: addedItems, scanner: scanner)
    }

    func dataScanner(_ scanner: DataScannerViewController, didTapOn item: RecognizedItem) {
      deliver(from: [item], scanner: scanner)
    }

    private func deliver(from items: [RecognizedItem], scanner: DataScannerViewController) {
      guard !hasDelivered else { return }
      for item in items {
        guard case .barcode(let barcode) = item, let payload = barcode.payloadStringValue else { continue }
        hasDelivered = true
        scanner.stopScanning()
        onScan(payload)
        return
      }
    }
  }
}
