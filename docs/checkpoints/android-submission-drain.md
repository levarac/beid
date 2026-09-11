# Checkpoint — Android submission drain (thegreeting/beid#525)

**Status: prospective, written before implementation, per the pilot in `docs/checkpoints/README.md`. Not a merge gate.**

Recorded by the maker agent for #525. Repository state: `origin/main` at worktree
creation, `bb8b663`.

## Scope

Android-only. This PR adds a drain to Android's existing writer
(`WindowObservationAccumulator` → `UnsentWindowLedgerStore`); iOS's own drain
(`ReportSubmissionRuntime`) is untouched, per the issue and the Both-OS feature
rule's exception: the Android production flow this drain completes did not
exist on the other side to begin with (iOS uses a separate, non-shared store).

## Decision route

### decision: which operator configuration may a submission POST under?

**observable**: whether an artifact is POSTed at all, and if so, to which
endpoint with which receipt key. There is no Android UI reflecting this yet
(no counterpart to iOS's beid#292 Daily Summary rows exists on Android), so
this is not a bound UI output the decision-route table's original purpose
targets — recorded anyway because it is the one place this PR's own design
introduces a native decision that native state, not the shared reducer, makes.

**canonical shared source**: `createSubmissionOperatorConfigurationFromEventDefinition(context)`
(`SubmissionModels.kt:189`) — pure, deterministic given a verified
`EventDefinitionContext`. The shared reducer (`UnsentWindowLedger.kt`) has no
opinion on configuration; it only decides which windows are eligible to become
a submission.

**inputs that determine the observable — Android** (this PR):

| observable part | source |
| --- | --- |
| whether a config exists at all | `RegistryVerifiedJoinContext.definition` at join time, threaded through a new `WindowObservationContext.submissionConfiguration` field, persisted at window-open — **native**, not shared |
| endpoint / receipt key / operator id | same verified definition, converted once at join time |

**unmatched conditions**: **yes — one, confirmed by reading the code, not
inferred.** `RegistryVerifiedJoinContext.fromNearbyCandidate` (used by
`EventJoinCoordinator.joinNearbyEvent`, the nearby-card-tap join path)
deliberately returns `definition = null` — its own doc comment says the
promotion already performed the read and re-fetching would ask the network
again for an answer the device has. But the retained answer
(`NearbyEventDiscoverySession.verifiedDefinitionByHash`) is a
`BarnardEventDefinitionV1` (Barnard's spec-134 agreement shape), not an
`EventDefinitionContext`, and does not carry a submission endpoint or receipt
key. So **windows opened while joined via a nearby-card tap have no
resolvable submission configuration and are held** (this PR's part 2 behavior,
tested by #525 acceptance criterion 4) — not as a bug this PR introduces, but
as an existing gap in what the join path retains, newly made visible because
this is the first consumer that needs the full definition after join.

**severity**: real, not hypothetical — traced through the code
(`RegistryVerifiedJoinContext.kt`, `NearbyEventDiscoverySession.kt:307`,
`EventJoinCoordinator.kt:492-530`), not reproduced on device. Card-tap join is
the venue-scale path; manual event-code entry (which does carry a definition,
via `verifyDefinitionThenJoin`) is unaffected.

**result**: `owner ruling required`. Two ways to close it, neither taken in
this PR because both are bigger than #525's four parts:

1. Give the nearby-join path its own independent registry lookup for a full
   `EventDefinitionContext`, mirroring how iOS's `ReportSubmissionRuntime`
   resolves fresh from `eventIdHex` at capture time regardless of how the
   event was joined — the behavioral pattern the maker brief pointed at.
2. Retain the full `EventDefinitionContext` (not just the Barnard-shaped
   projection) on the nearby-discovery path so `fromNearbyCandidate` can carry
   it forward.

Flagged in the PR description and in the maker's report; not decided here.
