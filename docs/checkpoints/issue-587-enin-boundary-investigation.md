# Beid #587 — participant ENIN-boundary investigation

## Reproduction pin and scope

- Requested starting ref: `7f4e34262a0877cc4812d4f7d095d6ef71d09410`.
- Actual checkout before investigation: `7f4e34262a0877cc4812d4f7d095d6ef71d09410`
  on branch `work`; `git status --short --branch` reported only `## work`.
- Participant discovery only. No deployment, live registry request, physical
  handoff, real identifier, publication, or #589 venue/lease-continuation
  experiment was performed.
- The historical 2026-09-17 trace and its correction remain historical
  evidence. In particular, the two continuously Verified 11:00/11:05
  boundaries disprove an unconditional boundary transition.

## What the current paths do

`NearbyEventDiscoveryStore` has no ENIN input. Its clocks are observation time,
the five-minute source TTL, registry-retry deadlines, and the retained
definition validity interval. A successful resolution is not invalidated by a
new envelope for the same hash; receiver state is monotonic within the live
session. A lookup failure schedules 5 s, then 30 s, then 120 s retries. Source
loss removes the candidate only when its last observation reaches the 300 s
TTL.

Both adapters consume the shared retry deadline. Android includes
`nextRegistryRetryAtEpochMillis` in the minimum wake time, refreshes at that
time, and immediately calls `resolveUnresolvedCandidates`. iOS includes the
same deadline in its single discovery wake-up, refreshes, and immediately
calls `resolveNearbyCandidates`. Both adapters anchor the reducer's pending
retry delay with a fresh injected/native clock reading after a failed lookup.
The source paths expose no deliberate ENIN delay for retries. This review did not establish what caused the missed retry in the device trace.

The added synthetic-clock characterization fixes three observations around a
nominal 300 s boundary:

1. an agreeing envelope at 300.001 s leaves the prior registered definition
   and `REGISTRY_VERIFIED` receiver tier standing;
2. a lookup failure completed just after the boundary becomes retryable at
   exactly completion-clock + 5 s, not at another ENIN boundary; and
3. silence leaves the candidate present through TTL - 1 ms and removes it at
   TTL exactly.

The cases characterize the current reducer. They were not executed in the
investigation environment. Production behavior and the supported backoff are
unchanged. Evaluate prevalidation after the trace identifies a delay attributable
to verification.

## What reaches recording while discovery is unresolved

Discovery and joined-session observation recording are separate call paths.
On Android, a radio detection is recorded only when a joined `Sensing` session
already exists; then its ENIN/RPID (including a null display ID) reaches the
aggregation runtime and window accumulator without consulting the nearby
candidate's registry status. Before a successful join, the guard rejects the
detection from recording. On iOS, joined-session device observations likewise
enter `aggregationRuntime` including observations without a display ID; nearby
registry status is not an input to that method.

Therefore an **unresolved pre-join candidate contributes no recording-layer
observation**. If nearby discovery later becomes unresolved while an already
joined session continues, ordinary joined-session B003 detections still reach
aggregation/window recording; B005 discovery envelopes themselves never
become attendance observations. This is a code-path result only—no physical
boundary handoff was executed.

## Commands, counts, exits, and evidence limit

| Command | Exit | Count/result |
| --- | ---: | --- |
| `git rev-parse HEAD` | 0 | one SHA: requested and actual checkout both `7f4e34262a0877cc4812d4f7d095d6ef71d09410` |
| `./gradlew :shared:testAndroidHostTest --tests 'org.levarac.parallax.discovery.NearbyEventRegistryRetryTest' --tests 'org.levarac.parallax.discovery.NearbyEventRegistryResolutionTest' --tests 'org.levarac.parallax.discovery.RegistryVerifiedJoinContextTest'` (from `android/`) | 1 | 0 tests executed; Gradle stopped during configuration because neither `ANDROID_HOME` nor `android/local.properties` supplied an SDK |

The failed Gradle configuration is an environment limit, not behavioral RED.
Consequently this checkout provides no executable RED/GREEN claim and no test
result count beyond zero executed. CI or a host with an Android SDK should run
the three requested suites plus
`NearbyEventBoundaryCharacterizationTest` (three cases). Native adapter and
physical handoff evidence remains pending.

## Follow-up on the original device behavior

At a known signed-window rollover, capture the venue's verified lease window
and the participant's last accepted envelope, candidate expiry, lookup
completion, retry deadline, and wake-up in the same time base. Correlate
joined-session observation counts across the transition. Use synthetic inputs
for reducer and adapter tests and keep identifiers out of shared diagnostics.
If the venue stops supplying a valid envelope, trace the renewal path in #589.
If an accepted source is lost before a due retry, reproduce that exact producer
or adapter transition before changing verification or retry policy.
