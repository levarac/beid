// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import Foundation

/// Failure modes for `AppCoordinator.joinEvent(code:)`, the manual
/// event-code entry path (`EventCodeEntryView`) that lets a user reach the
/// sensing screen without connecting a wallet.
enum EventCodeJoinError: Equatable {
  /// The entered code was empty (or all whitespace) after trimming.
  case emptyCode
  /// `BarnardEngine.joinEvent(_:)` did not take effect for the entered code.
  ///
  /// Deliberately carries no reason. Selecting a code is not joining — see
  /// `SensingCoordinator.joinEvent`, and the two tests named
  /// `testSelectingAnEventCodeIsNotAnError...` — so the registry's verdict is
  /// not known here and must not be guessed at. The refusal a participant
  /// needs to see comes from the join gate, and beid#472 surfaces it at
  /// `SensingView` where the gate actually refuses.
  case joinFailed
}
