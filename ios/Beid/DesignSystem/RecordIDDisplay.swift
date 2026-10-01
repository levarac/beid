// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import Foundation

/// The visual shorthand used by both record screens. Accessibility and any
/// future copy action use the full UUID instead.
enum RecordIDDisplay {
  static func abbreviated(_ id: UUID) -> String {
    let full = id.uuidString.lowercased()
    return "\(full.prefix(4))…\(full.suffix(4))"
  }
}
