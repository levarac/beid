// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import Foundation

/// Failure modes for `AppCoordinator.joinEvent(code:)`, the manual
/// event-code entry path (`EventCodeEntryView`) that lets a user reach the
/// sensing screen without connecting a wallet.
enum EventCodeJoinError: Equatable {
  /// The entered code was empty (or all whitespace) after trimming.
  case emptyCode
  /// `BarnardEngine.joinEvent(_:)` did not take effect for the entered code.
  case joinFailed
}
