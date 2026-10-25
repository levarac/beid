# Shared record event grouping

Migration ledger:

| family | class | current_ios | current_android | ruling_or_invariant | owner | shared_symbol | licensing_test | platform_callers | status |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| collection event grouping | A / SWAP | `EventGrouping.swift` | no event grouping caller | preserve the existing iOS grouping and Home ordering | collection presentation | `org.levarac.parallax.collection.groupRecordsByEvent`, `homeRecordGroups` | `EventGroupingTest` | none yet | shared API prepared; native migration pending |

The oracle is `ios/Beid/Models/EventGrouping.swift` at base `64debe97`,
especially `groups(from:)` and `homeGroups(from:activeEventCode:)`, with the
corresponding `EventGroupingTests.swift` vectors. Group identity uses the
existing shared event-code normalizer, never a display name or inferred
identity. Missing or unnormalizable codes stay in separate record groups.
Ordinary grouping preserves input order. Home first sorts recording dates
descending, preserving input position on ties, and excludes the active
event's entire group. Native adapters provide recording instants as epoch
seconds without discarding the subsecond precision of iOS `Date`.

Android's collection Home and event-grouped past-events callers do not yet
exist; their UI and navigation are separate work. No Android UI is added.
iOS remains unchanged here: its existing tests import the iOS application
and require a Simulator to execute. iOS stays on its own implementation
for now because the adapter cannot be verified with the existing tests
without a Simulator. Shared vectors establish the prepared API's
behavior, not native production wiring or Swift runtime authority. The
native adapter, ownership gates, and full iOS regression suite remain a
follow-up migration step.
