# Shared record event grouping

Migration ledger:

| family | class | current_ios | current_android | ruling_or_invariant | owner | shared_symbol | licensing_test | platform_callers | status |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| collection event grouping | A / SWAP | `EventGrouping.swift` | `HomeRoute`, event-filtered `RecordsRoute` | preserve the existing iOS grouping and Home ordering | collection presentation | `org.levarac.parallax.collection.groupRecordsByEvent`, `homeRecordGroups` | `EventGroupingTest`, `CollectionHomeTest` | Android `homeProofRecordGroups` | Android wired; iOS migration pending |

The oracle is `ios/Beid/Models/EventGrouping.swift` at base `64debe97`,
especially `groups(from:)` and `homeGroups(from:activeEventCode:)`, with the
corresponding `EventGroupingTests.swift` vectors. Group identity uses the
existing shared event-code normalizer, never a display name or inferred
identity. Missing or unnormalizable codes stay in separate record groups.
Ordinary grouping preserves input order. Home first sorts recording dates
descending, preserving input position on ties, and excludes the active
event's entire group. Native adapters provide recording instants as epoch
seconds without discarding the subsecond precision of iOS `Date`.

Android Home now calls `homeRecordGroups` through a metadata adapter over the
existing `ProofRecordStore.recordsFlow`. It supplies the record UUID, stored
event code, and `Instant` epoch seconds plus its fractional nanoseconds; input
order is the store's order. The active code comes from the identified scan
session (`EventFound`, `Recording`, or `SignalLost`); an unidentified sensing
phase has no code and excludes nothing. Names and Event IDs never group records.
The event-specific secondary list re-resolves its anchor UUID from current
store state through the same shared rules, with no active exclusion. Account
retains the complete records list. No store format or outer lock changes.

iOS remains intentionally unchanged: its existing tests import the iOS application
and require a Simulator to execute. iOS stays on its own implementation
for now because the adapter cannot be verified with the existing tests
without a Simulator. Shared vectors establish the API's behavior; Android
Compose tests cover its production navigation caller. They establish no Swift
runtime authority. The iOS adapter, ownership gates, and full iOS regression
suite remain a follow-up migration step.
