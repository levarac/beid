// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import Foundation

/// Display-side event grouping shared by `CollectionHomeView` and
/// `ItemDetailView` (beid#217). `Proof` itself stays session-granular — this
/// only groups an existing `[Proof]` for presentation; see
/// `docs/specs/collection-event-aggregation.md` §3.
enum EventGrouping {
  /// Groups `proofs` by `eventCode`, preserving `proofs`' existing
  /// newest-first order both within each group and across groups. A
  /// `nil`-`eventCode` proof is always its own singleton group — it is
  /// never merged with another `nil`-`eventCode` proof or with any real
  /// `eventCode` group (§3's hard constraint: a missing `eventCode`
  /// predates beid#137 and carries no identity two `nil` proofs could share
  /// safely). Every returned sub-array is non-empty by construction.
  static func groups(from proofs: [Proof]) -> [[Proof]] {
    var order: [String] = []
    var groups: [String: [Proof]] = [:]
    for proof in proofs {
      let key = proof.eventCode ?? "singleton-\(proof.id.uuidString)"
      if groups[key] == nil {
        order.append(key)
        groups[key] = []
      }
      groups[key]!.append(proof)
    }
    return order.map { groups[$0]! }
  }

  /// The single group containing `proof`, scoped without a full grouping
  /// pass over `proofs` (§2). `nil`-`eventCode` proofs short-circuit to a
  /// singleton `[proof]`, matching `groups(from:)`'s singleton rule above.
  /// Always non-empty (`proof` itself is always a member of its own
  /// result).
  static func sessions(for proof: Proof, in proofs: [Proof]) -> [Proof] {
    guard let eventCode = proof.eventCode else { return [proof] }
    return proofs.filter { $0.eventCode == eventCode }
  }

  /// One representative `Proof` per distinct non-nil `eventCode` in
  /// `proofs`, newest-first (beid#230). The representative is each group's
  /// newest proof — `groups(from:)` already keeps every sub-array
  /// newest-first, so `.first` is that proof. A `nil`-`eventCode` proof is
  /// never a candidate: `groups(from:)`'s singleton rule already keeps it
  /// out of any real `eventCode` group, and this filters the singleton
  /// itself out too, so it never appears here at all — omission, not a
  /// false entry (issue #230's explicit acceptance criterion). This is the
  /// "events you've previously joined and recorded a Proof for" list; it
  /// intentionally excludes a code that was typed and abandoned before a
  /// `Proof` was ever recorded, since `Proof.eventCode` is the only
  /// participation record this app keeps.
  static func pastEvents(from proofs: [Proof]) -> [Proof] {
    groups(from: proofs).compactMap { group in
      guard let representative = group.first, representative.eventCode != nil else { return nil }
      return representative
    }
  }
}
