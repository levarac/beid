// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import BeidSharedKit
import Foundation

enum UnsentWindowLedgerRuntimeError: Error {
  case missingLedger
  case invalidRecoveryInput
  case rejectedTransition(String)
  case stalePersistence(expected: Int64, actual: Int64)
}

/// Production caller for the shared ledger reducer.
///
/// Native lifecycle code supplies explicit open/close inputs. This adapter
/// performs only the shared call and write-ahead persistence handshake; it
/// does not interpret ledger states or choose report membership.
final class UnsentWindowLedgerRuntime {
  private let store: UnsentWindowLedgerStore
  private var ledger: BeidSharedKit.report.UnsentWindowLedger

  init(
    store: UnsentWindowLedgerStore,
    ledgerInstanceIdHex: String? = nil
  ) throws {
    self.store = store
    if let restored = try store.load() {
      guard restored.isSuccess, let ledger = restored.ledger else {
        throw UnsentWindowLedgerRuntimeError.missingLedger
      }
      self.ledger = ledger
      return
    }

    let instanceId = ledgerInstanceIdHex ?? UUID().uuidString
      .replacingOccurrences(of: "-", with: "")
      .lowercased()
    let created = BeidSharedKit.report.createUnsentWindowLedger(
      ledgerInstanceIdHex: instanceId
    )
    guard created.isSuccess, let ledger = created.ledger else {
      throw UnsentWindowLedgerRuntimeError.rejectedTransition(
        created.errorCode ?? "ledger_creation_failed"
      )
    }
    self.ledger = ledger
  }

  func openWindow(windowId: String) throws {
    try apply(
      BeidSharedKit.report.openUnsentWindow(
        ledger: ledger,
        windowId: windowId
      )
    )
  }

  func closeWindow(
    windowId: String,
    persistedObservationReference: String
  ) throws {
    try apply(
      BeidSharedKit.report.closeUnsentWindow(
        ledger: ledger,
        windowId: windowId,
        persistedObservationReference: persistedObservationReference
      )
    )
  }

  func reconcileAfterRelaunch(
    persistedObservations: [(windowId: String, reference: String)]
  ) throws {
    let recoveryInput = BeidSharedKit.report.createUnsentWindowObservationRecoveryInput()
    for observation in persistedObservations {
      guard BeidSharedKit.report.addPersistedUnsentWindowObservationForRecovery(
        recoveryInput: recoveryInput,
        windowId: observation.windowId,
        persistedObservationReference: observation.reference
      ) else {
        throw UnsentWindowLedgerRuntimeError.invalidRecoveryInput
      }
    }
    try apply(
      BeidSharedKit.report.reconcileUnsentWindowLedgerAfterRelaunch(
        ledger: ledger,
        recoveryInput: recoveryInput
      )
    )
  }

  private func apply(
    _ transition: BeidSharedKit.report.UnsentWindowLedgerTransition
  ) throws {
    guard transition.isSuccess else {
      throw UnsentWindowLedgerRuntimeError.rejectedTransition(
        transition.errorCode ?? "ledger_transition_failed"
      )
    }
    guard transition.changed else {
      ledger = transition.ledger
      return
    }

    let persistedRevision = try store.persist(transition)
    guard persistedRevision == transition.persistenceRevision else {
      throw UnsentWindowLedgerRuntimeError.stalePersistence(
        expected: transition.persistenceRevision,
        actual: persistedRevision
      )
    }
    let confirmed = BeidSharedKit.report.confirmUnsentWindowLedgerPersistence(
      ledger: transition.ledger,
      revision: persistedRevision
    )
    guard confirmed.isSuccess else {
      throw UnsentWindowLedgerRuntimeError.rejectedTransition(
        confirmed.errorCode ?? "ledger_persistence_confirmation_failed"
      )
    }
    ledger = confirmed.ledger
  }
}
