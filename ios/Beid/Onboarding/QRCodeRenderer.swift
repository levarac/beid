// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import CoreImage.CIFilterBuiltins
import SwiftUI

/// Renders a WalletConnect pairing URI as a QR code using CoreImage's
/// built-in generator — no third-party QR dependency needed.
enum QRCodeRenderer {
  static func image(for string: String) -> Image? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(string.utf8)
    filter.correctionLevel = "M"

    guard let output = filter.outputImage else { return nil }
    let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))

    let context = CIContext()
    guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
    return Image(decorative: cgImage, scale: 1, orientation: .up)
  }
}
