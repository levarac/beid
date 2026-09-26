// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import SwiftUI
import UIKit

/// A frozen snapshot created by the Account button, never a live data source.
final class SupportShareItem: NSObject, UIActivityItemSource, Identifiable {
  let text: String

  init(text: String) { self.text = text }

  func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
    text
  }

  func activityViewController(
    _ activityViewController: UIActivityViewController,
    itemForActivityType activityType: UIActivity.ActivityType?
  ) -> Any? {
    text
  }
}

struct SupportShareSheet: UIViewControllerRepresentable {
  let item: SupportShareItem

  func makeUIViewController(context: Context) -> UIActivityViewController {
    UIActivityViewController(activityItems: [item], applicationActivities: nil)
  }

  func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
