# Checkpoints — format, and the worked example that produced it

This directory holds one checkpoint record per feature, named for the feature
(`event-join-card.md`, and so on). The format and the pilot's standing are
defined in `AGENTS.md` under "Cross-platform checkpoint". **The pilot is not in
force and a checkpoint is not a merge gate.**

This file is not itself a checkpoint. It is the worked example the format was
derived from, kept because the format's least obvious rule — trace backward
from the bound output, and ask where each input is *cleared* as well as
written — only makes sense alongside the case that produced it.

---

## Worked example — event-join card: "can I join this event?"

**Status: retrospective read-only trial. Not a merge gate, not a dispatched
review.** The divergence recorded below was found on 2026-09-12 by reading both
platforms after a shared-level equivalence proof twice concluded there was none.
This record was written afterwards. It demonstrates that the field shape can
express the defect; it does **not** claim the procedure found it, and no PR was
gated on it.

Deliberately *not* run as an author-independent dispatched review: doing that as
a standing pre-merge operation would substantively satisfy re-enable condition 1
of `AGENTS.md` "Review gate — SUSPENDED as of 2026-08-19", which is the owner's
call to make first. See the pilot section in `AGENTS.md` for the choice awaiting
the owner.

Recorded by `subpm-beid515`. Repository state: `origin/main` `bb8b663`.

## Scope

Both platforms ship this path, so the Both-OS feature rule's exception branch
does not apply. That rule (`AGENTS.md`, "Both-OS feature rule") already governs
what a PR description must say about scope; this record does not restate it.

The decision below is a shared decision — `nearbyCandidateJoinEligibility`,
`shared/src/commonMain/kotlin/org/levarac/parallax/discovery/RegistryVerifiedJoinContext.kt:243`
— consumed by native presentation on both platforms, which the Ownership
boundary assigns to native ("UI and navigation").

## Decision route

### decision: may this event card be selected, and what does it show?

**observable**: whether the card is tappable, and the event identity and
validity window printed on it. If the platforms disagree, the same user beside
the same beacon sees an actionable card on one phone and a dead card on the
other.

**canonical shared source**: `nearbyCandidateJoinEligibility(candidates,
eventCodeHashHex, nowEpochSeconds)` —
`RegistryVerifiedJoinContext.kt:243-284`. `RegistryVerifiedJoinContext
.fromNearbyCandidate` (`:179-200`) is not a second decision: it delegates to
that predicate at `:187-190` and returns null unless the answer is `ELIGIBLE`.
Its three `?: return null` lines (`:192`, `:196`, `:197`) are Kotlin
type-system formalities for non-null constructor parameters and are unreachable
once the predicate passed, because the predicate rejects those same three nil
cases first at `:266-273`, ahead of `return ELIGIBLE` at `:283`.

**inputs that determine the observable — iOS** (`ios/Beid/Views/SensingView.swift:67-82`)

| observable part | source |
| --- | --- |
| tappable | `verifiedJoin != nil` — shared |
| `eventIdHex` | `verifiedJoin?.eventIdHex` — shared |
| validity window | `candidate.definitionValidFromEpochSeconds` / `...ValidUntil...` — shared candidate |

One source of truth: the shared answer.

**inputs that determine the observable — Android**
(`android/app/src/main/kotlin/org/levarac/beid/sensing/NearbyEventDiscoverySession.kt:385-397`,
`android/app/src/main/kotlin/org/levarac/beid/ui/screens/EventJoinScreen.kt:356`)

| observable part | source |
| --- | --- |
| `joinable` | `nearbyCandidateJoinEligibility(...) == ELIGIBLE` — shared |
| `eventIdHex` | `verifiedMetadataByHash[...]?.takeIf { joinable }?.eventIdHex` — **native map** |
| validity window | same native map entry |
| tappable | `EventJoinScreen.kt:356` — `card.eventIdHex != null`, i.e. transitively the native map |

`verifiedMetadataByHash` is a native mutable map declared at
`NearbyEventDiscoverySession.kt:124`, with its own independent lifecycle:
written `:442`, removed `:444`, cleared `:250`, expiry-pruned `:358`,
liveness-pruned `:363`.

**unmatched conditions**: **yes — one, on Android.** The card's identity,
window and enablement pass through `verifiedMetadataByHash` in addition to the
shared verdict. iOS has no counterpart. Android therefore requires
shared-`ELIGIBLE` **and** a present native map entry; iOS requires
shared-`ELIGIBLE` alone. Whenever the native map and the shared snapshot
disagree — the map pruned at `:358`/`:363` while the shared decision still
answers `ELIGIBLE` — Android shows a disabled card where iOS shows an enabled
one.

**severity, stated precisely**: the *structural* divergence is confirmed by
construction, read on both platforms at `bb8b663`. A reachable path is **traced
through the code below but has not been reproduced on device.** Do not cite
this record as a reproduced defect.

**traced path to a live disagreement** (each step read at `bb8b663`):

1. `NearbyEventDiscovery.kt:619-624` — when `store.sources` is at
   `MAX_LIVE_SOURCE_COUNT` (256, `:8`), adding a new source evicts the oldest.
   The eviction removes from `store.sources` **only**.
2. `store.registry` and `store.receiverStates` are pruned to live hashes solely
   in `expireAt` (`:883-892`), which runs on TTL expiry. So an evicted hash
   keeps its registry record. Android drops its own map entry at
   `NearbyEventDiscoverySession.kt:363`.
3. On re-observation before the next TTL sweep, a fresh source is added
   (`:615-634`) and the retained registry record is left alone — only
   `LOOKUP_UNAVAILABLE` is reset (`:636-638`). The rebuilt candidate carries the
   retained status, event id, digest, block hash and window, so
   `nearbyCandidateJoinEligibility` answers `ELIGIBLE` again.
4. `beginNearbyEventRegistryResolutionFromHex` returns null because
   `record.status != UNRESOLVED` (`:676`). `updateVerifiedCard` has exactly one
   caller — `NearbyEventDiscoverySession.kt:332`, inside that resolution
   callback — so the native map is never rebuilt. Android's card stays disabled
   while iOS's is enabled.

**precondition**: at least 256 live (hash, peripheral) sources. Not reached at
the #469 rehearsal scale of 20-30 devices; plausible at venue scale, where
Android MAC rotation inflates distinct peripheral identifiers. This precondition
is the reason the divergence has not been observed, not a reason it cannot occur.

**same shape, one line away**: `verifiedDefinitionByHash`
(`NearbyEventDiscoverySession.kt:140`, pruned `:365`, rebuilt only `:307`) has
the identical eviction gap for the relay verifier. The iOS side of that pair has
not been checked.

**secondary, lower severity (inferred)**: the two platforms obtain
`nowEpochSeconds` independently — iOS `floor(Date().timeIntervalSince1970)` at
`SensingView.swift:167-170`; Android injects `System::currentTimeMillis` at
`EventJoinCoordinator.kt:134,154` and divides at
`NearbyEventDiscoverySession.kt:355-357` — so the two can straddle a boundary
second at the edge of a validity window (`RegistryVerifiedJoinContext.kt:280-283`).

**result**: `owner ruling required`. Which platform is correct is a product
decision, not a reviewer's call. The two candidate rulings:

1. the shared verdict is the whole answer, and Android should read identity and
   window from the shared candidate as iOS does — `verifiedMetadataByHash`
   becomes a cache, never a gate;
2. the native map encodes a real additional requirement, in which case it
   belongs in the shared decision so both platforms enforce it.

Ruling 1 is the one the Ownership boundary already implies: the three values are
available on the shared candidate (`NearbyEventDiscovery.kt:113`, `:938-939`) and
iOS reads them there (`SensingView.swift:77-82`). Recorded as a recommendation,
not a decision.

This is the same question `beid#454` asks, reached by a different route than
that issue describes.

**the durable artifact, and the reason this record is not the point.** The fix
should carry a parity test in `:app:testDebugUnitTest` — already run by
`.github/workflows/pr-ci.yml:38`, so no new CI surface — asserting that whenever
the shared predicate answers `ELIGIBLE` for a candidate, the projected card's
`eventIdHex` equals that candidate's `resolvedEventIdHex`. That test is a
machine artifact: unlike this file, it does not depend on anyone reading it.
A prose checkpoint can go unread exactly as a documented reviewer went
undispatched; a failing test cannot.

## What this record demonstrates for `beid#515`

The `Decision route` field is the one that catches this. A shared-test column
provably would not have: two independent shared-level equivalence proofs were
produced on 2026-09-12 — by an enumeration agent and by the sub-PM — and both
concluded "no divergence," because both traced *forward* from the shared call
and stopped when the shared functions proved equivalent. The divergence is
downstream of that, in native consumption.

`AGENTS.md:137` already states the hazard: "Shared tests alone also do not
prove that either app calls the shared implementation." Two reviewers walked
into it anyway, within an hour, on the very issue about catching this class.
That is why this field traces **backward from the observable** and demands
*every* input, rather than forward from the shared entry point: forward-tracing
terminates as soon as the shared call is named, which is exactly the answer
that was true and missed everything.
