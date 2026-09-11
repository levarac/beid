# Checkpoint — event-join card: single source of truth for the Android projection

**Status: prospective use of the checkpoint pilot format (beid#516's second
done-when). Not a merge gate, not a dispatched review.** Written before
implementing the fix below, per the beid#454 maker brief. The retrospective
trial that first found this divergence lives at
`docs/checkpoints/event-join-card.md` on `docs/issue-516-checkpoint-pilot`
(PR #522) — not merged, not depended on here, and not in force.

Repository state: `origin/main` `bb8b663`.

## Scope

Android-only change to a both-OS decision; iOS untouched because it already
reads the canonical source at `SensingView.swift:77-82`.

## Decision route

### decision: may this event card be selected, and what does it show?

**observable**: whether the card is tappable, and the event identity and
validity window printed on it. If the platforms disagree, the same user beside
the same beacon sees an actionable card on one phone and a dead card on the
other.

**canonical shared source**: `nearbyCandidateJoinEligibility(candidates,
eventCodeHashHex, nowEpochSeconds)` —
`shared/src/commonMain/kotlin/org/levarac/parallax/discovery/RegistryVerifiedJoinContext.kt:243-284`.

**before this PR — Android**
(`android/app/src/main/kotlin/org/levarac/beid/sensing/NearbyEventDiscoverySession.kt:385-397`):

| observable part | source |
| --- | --- |
| `joinable` | `nearbyCandidateJoinEligibility(...) == ELIGIBLE` — shared |
| `eventIdHex` | `verifiedMetadataByHash[...]?.takeIf { joinable }?.eventIdHex` — native map |
| validity window | same native map entry |

`verifiedMetadataByHash` (declared `:124`) has its own lifecycle independent
of the shared candidate: written on registry-resolution completion, pruned to
live hashes and by TTL in `publishAndSchedule`. iOS has no counterpart map —
`SensingView.swift:67-82` reads `eventIdHex` from the shared join context and
the validity window from the shared candidate directly.

**after this PR — Android**: `eventIdHex` and the validity window are read
from the shared candidate (`candidate.resolvedEventIdHex`,
`candidate.definitionValidFromEpochSeconds` /
`candidate.definitionValidUntilEpochSeconds`), gated by the same `joinable`
boolean — the shape iOS already uses. `verifiedMetadataByHash` remains, but
narrowed to a cache for the expiry-scheduling scan in `publishAndSchedule`;
it no longer gates or supplies the card's fields.

**unmatched conditions after this PR**: none by construction — both platforms
read the same three fields from the same shared candidate under the same
`joinable` gate.

**traced path this PR closes** (traced, not reproduced on device — see
beid#454 and the retrospective record above for the full derivation): a
candidate evicted from `store.sources` at the 256-live-source cap
(`NearbyEventDiscovery.kt`'s `MAX_LIVE_SOURCE_COUNT`) and re-observed before
its retained registry record's own TTL rebuilds to shared-`ELIGIBLE` from
retained evidence. Pre-fix, `verifiedMetadataByHash` had already been pruned
for that hash when the candidate briefly left the live snapshot, and nothing
repopulates it on re-observation — `updateVerifiedCard`'s one call site is the
registry-resolution completion callback, which does not re-run for a hash
already resolved. Android's card would show no `eventIdHex` where iOS's
would.

**the durable artifact**:
`android/app/src/test/kotlin/org/levarac/beid/sensing/NearbyEventCardSingleSourceOfTruthTest.kt`,
run by `.github/workflows/pr-ci.yml:38` (`:app:testDebugUnitTest`) — no new CI
surface. It drives the 256-source eviction and re-observation above and
asserts the card's `eventIdHex` equals the candidate's `resolvedEventIdHex`
whenever the shared predicate answers `ELIGIBLE`. It fails against the
pre-fix code and passes against this PR's fix.

## Out of scope, filed separately

`verifiedDefinitionByHash` (`NearbyEventDiscoverySession.kt:140`) has the
identical eviction gap for the relay verifier; not fixed here — see beid#454's
"second finding" note. beid#455 (same-named test seam, different referent per
OS) and beid#422 (shared scenario fixture) are open issues of a related class;
not fixed here.
