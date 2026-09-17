// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import SwiftUI
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
  /// Whether offering the button is honest on this device, right now.
  static var isAvailable: Bool {
    DataScannerViewController.isSupported && DataScannerViewController.isAvailable
  }
}

struct VenueLinkScannerView: UIViewControllerRepresentable {
  /// Called with the first recognised payload. The view dismisses itself first so
  /// a second frame cannot deliver a different link into a screen already acting on
  /// the first one.
  let onScan: (String) -> Void
  let onCancel: () -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(onScan: onScan)
  }

  func makeUIViewController(context: Context) -> DataScannerViewController {
    let controller = DataScannerViewController(
      recognizedDataTypes: [.barcode(symbologies: [.qr])],
      qualityLevel: .balanced,
      recognizesMultipleItems: false,
      isHighFrameRateTrackingEnabled: false,
      isHighlightingEnabled: true
    )
    controller.delegate = context.coordinator
    return controller
  }

  func updateUIViewController(_ controller: DataScannerViewController, context: Context) {
    guard !controller.isScanning else { return }
    try? controller.startScanning()
  }

  static func dismantleUIViewController(_ controller: DataScannerViewController, coordinator: Coordinator) {
    controller.stopScanning()
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
