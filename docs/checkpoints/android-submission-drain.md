# Checkpoint — Android submission drain (thegreeting/beid#525)

**Status: prospective, written before implementation, using the checkpoint
format this maker's brief pointed at. Not a merge gate.**

Correction (post-rebase): this status line originally cited
`docs/checkpoints/README.md` as the format's home, on `main`. That was wrong
about where the format lives, not about whether it exists — verified against
`origin/main` directly (`git log origin/main -- docs/checkpoints/README.md`
is empty; `AGENTS.md` there has zero mentions of "checkpoint"), the format
itself (an `AGENTS.md` section plus `docs/checkpoints/README.md`) is
**proposed in PR #522, still open, not yet in force pending the owner's
approval** — it was never on `main` to begin with. `docs/checkpoints/event-join-card.md`,
added by beid#454's merge, is a real filled-in example of the format, not the
format's definition. Neither correction changes this record's own content
below, which is about a different decision (submission configuration, not
event-card projection).

Recorded by the maker agent for #525. Repository state: `origin/main` at worktree
creation, `bb8b663`; rebased onto `origin/main` (`5b523fc`, beid#454's merge)
before the update below.

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

**unmatched conditions, as first recorded**: **yes — one, confirmed by reading
the code, not inferred.** `RegistryVerifiedJoinContext.fromNearbyCandidate`
(used by `EventJoinCoordinator.joinNearbyEvent`, the nearby-card-tap join
path) deliberately returns `definition = null` — its own doc comment says the
promotion already performed the read and re-fetching would ask the network
again for an answer the device has. But the retained answer
(`NearbyEventDiscoverySession.verifiedDefinitionByHash`) is a
`BarnardEventDefinitionV1` (Barnard's spec-134 agreement shape), not an
`EventDefinitionContext`, and does not carry a submission endpoint or receipt
key. So windows opened while joined via a nearby-card tap had no resolvable
submission configuration at open time.

**severity, as first recorded**: real, not hypothetical — traced through the
code (`RegistryVerifiedJoinContext.kt`, `NearbyEventDiscoverySession.kt:307`,
`EventJoinCoordinator.kt:492-530`), not reproduced on device. Card-tap join is
the venue-scale path; manual event-code entry (which does carry a definition,
via `verifyDefinitionThenJoin`) is unaffected.

**result, as first recorded**: `owner ruling required`, with two candidate
fixes named, neither taken in the first pass — reported rather than decided,
since both looked bigger than #525's four parts.

## Update — closed in this same PR, option 1 taken

The lead and a reviewing agent independently verified option 1
(`ios/Beid/Sensing/ReportSubmissionRuntime.swift:38-58` never trusts join-time
context at all; it resolves fresh by event id at capture time, regardless of
how the event was joined) and found it was not, in fact, bigger than this
issue: `EventJoinCoordinator` already holds the exact seam needed
(`EventJoinRegistry.resolveEventDefinition`, `EventJoinRegistry.kt:55`), and
`WindowObservationSubmissionDrain` is constructed one hop away from it
(`WindowObservationRuntimeOwner.acquire`, whose only caller is
`EventJoinCoordinator`). No `shared/` change, no new external dependency.

**What changed**: `SubmissionRecord` now always carries the window's own
`eventIdHex` (from `WindowObservationContext`, not from a verified
definition), even when no configuration could be resolved at open time. When
`WindowObservationSubmissionDrain` finds a held record, it calls a new
`SubmissionConfigurationResolver` seam — shaped around the public
`SubmissionOperatorConfiguration`, not the shared module's
`internal`-constructor `EventDefinitionContext`/`EventDefinitionResolution`
(the same constraint that shaped iOS's own
`EventDefinitionContextProvider`/`VerifiedSubmissionDefinition` split) — to
resolve one fresh, by event id, before falling back to holding. A successful
resolution is persisted (`SubmissionRecordStore.recordResolvedConfiguration`)
so the lookup runs once per artifact, not on every drain trigger.

**Still true, unchanged by this update**: never submit under a guessed or
fallback configuration. If the lookup itself fails, times out, or produces no
usable definition, the artifact is held exactly as before, with the reason
surfaced.

**result, updated**: closed for the nearby-card-tap path specifically.
Nothing else in this decision route changed — the shared reducer still has no
opinion on configuration, and the "which configuration governs a submission"
decision is still entirely native.
