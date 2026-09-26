// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import BeidSharedKit
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
      let key = normalizedKey(for: proof.eventCode) ?? "singleton-\(proof.id.uuidString)"
      if groups[key] == nil {
        order.append(key)
        groups[key] = []
      }
      groups[key]!.append(proof)
    }
    return order.map { groups[$0]! }
  }

  /// Home's one-row-per-event list is ordered by the recorded date, rather
  /// than relying on file/insertion order. A Proof created when recording
  /// begins is already in the store, so the active event's entire group must
  /// leave PAST until that session ends. Older sessions of the same event
  /// cannot appear beside its active card either.
  static func homeGroups(from proofs: [Proof], activeEventCode: String?) -> [[Proof]] {
    let dated = proofs.enumerated().sorted { left, right in
      if left.element.date == right.element.date { return left.offset < right.offset }
      return left.element.date > right.element.date
    }.map(\.element)
    let activeKey = activeEventCode.flatMap { normalizedKey(for: $0) }
    return groups(from: dated).filter { group in
      guard let activeKey else { return true }
      return normalizedKey(for: group[0].eventCode) != activeKey
    }
  }

  /// The single group containing `proof`, scoped without a full grouping
  /// pass over `proofs` (§2). `nil`-`eventCode` proofs short-circuit to a
  /// singleton `[proof]`, matching `groups(from:)`'s singleton rule above.
  /// Always non-empty (`proof` itself is always a member of its own
  /// result).
  static func sessions(for proof: Proof, in proofs: [Proof]) -> [Proof] {
    guard let key = normalizedKey(for: proof.eventCode) else { return [proof] }
    return proofs.filter { normalizedKey(for: $0.eventCode) == key }
  }

  /// `sessions(for:in:)` in Event Detail's display order: recording start
  /// ascending, with the id as a tie-break so two equal dates never depend
  /// on store order (beid#701 §C).
  static func orderedSessions(for proof: Proof, in proofs: [Proof]) -> [Proof] {
    sessions(for: proof, in: proofs).sorted { left, right in
      if left.date == right.date { return left.id.uuidString < right.id.uuidString }
      return left.date < right.date
    }
  }

  /// The 1-based `Session N` number screens 08, 11 and 12 show for `proof`.
  /// Derived at display time and never stored; `nil` when `proof` is not in
  /// `proofs`.
  static func sessionOrdinal(of proof: Proof, in proofs: [Proof]) -> Int? {
    guard proofs.contains(where: { $0.id == proof.id }) else { return nil }
    return orderedSessions(for: proof, in: proofs).firstIndex { $0.id == proof.id }.map { $0 + 1 }
  }

  /// Whether two stored event codes name the same event under the grouping
  /// key. A `nil` or unnormalizable code matches nothing.
  static func sameEvent(_ left: String?, _ right: String?) -> Bool {
    guard let left = normalizedKey(for: left) else { return false }
    return left == normalizedKey(for: right)
  }

  /// The comparison/grouping key for `eventCode`, per beid#226/DECISIONS
  /// 2026-08-20 — surrounding whitespace trimmed, then case folded, via the
  /// same `shared/` decision iOS's join path
  /// (`AppCoordinator.attemptJoinEvent(code:)`) already applies, so two
  /// proofs typed/stored under different case or padding (e.g. legacy
  /// stored codes from before this fix) group together. `Proof.eventCode`
  /// itself is untouched — no migration, this only changes the comparison
  /// key. A non-nil `eventCode` that somehow normalizes to nil (should not
  /// happen for already-validated stored data) falls back to `nil` here,
  /// same as a genuinely-nil `eventCode` — callers degrade that to its own
  /// singleton rather than merging it into an unrelated bucket.
  private static func normalizedKey(for eventCode: String?) -> String? {
    guard let eventCode else { return nil }
    return BeidSharedKit.event.normalizedEventCodeOrNull(rawEventCode: eventCode)
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
