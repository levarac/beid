# Issue #144 — end-to-end mutual-attestation acceptance contract

Status: **Accepted contract; implementation incomplete**  
Date fixed: 2026-08-31  
Scope: beid app, Barnard SDK, report server, and independent verifier

## 1. Purpose and authority

Participation is not established by an organizer action, a local UI state, one
radio sighting, one device's report, or a server receipt. It is established only
when the following six stages compose successfully:

1. devices A and B independently observe one another;
2. each device signs its own observation with its event-scoped signing key;
3. a verifier validates both signatures and the applicable event time window;
4. the verifier matches the two records into one mutual observation and removes
   duplicates;
5. the app, report server, and any independent verifier derive the same result
   from the same accepted input; and
6. no organizer can issue, substitute, or override that result directly.

All six conditions are conjunctive. Failure or absence at any stage means that a
verified participation result has **not** been established. An implementation
may expose a more limited fact—such as “device sensed,” “locally recorded,” or
“server accepted”—but must not label it as mutually verified participation.
This preserves the three-tier distinction already fixed in
[`visibility-aggregation-ui.md`](../specs/visibility-aggregation-ui.md): an app
action, a participation record, and a third-party-verified proof are different
claims.

This document consolidates the acceptance rule. It does **not** define a new
report, bundle, receipt, COSE/CBOR profile, digest preimage, publication format,
or report-server API.

### Source hierarchy and limits of this consolidation

The sources available in or directly referenced by this checkout are:

- the whitepaper's participation and identity model, especially §§3.2 and 3.4;
  the whitepaper itself is not checked into this repository, so the repository's
  traceable restatement is
  [`scan-protocol-model.md`](../specs/scan-protocol-model.md) §§2–6 and its
  explicit whitepaper references;
- Barnard's
  [`specs/092-owner-key/spec.md`](https://github.com/levarac/barnard/blob/8dce71e545177db94f79ff6c5898986a423f4b7d/specs/092-owner-key/spec.md),
  which separates the long-lived owner key from the per-event signing key and
  specifies the owner-key self-proof and verification rules;
- beid issue #106 and its merged KMP foundation contract,
  [`kmp-shared-foundation.md`](../kmp-shared-foundation.md), which assigns
  deterministic cross-platform decisions to `shared/`, while keeping Barnard
  cryptography and native effects outside it;
- issue #60's report-ledger requirements, summarized in
  [`kmp-shared-foundation-issue-drafts.md`](../kmp-shared-foundation-issue-drafts.md)
  under “既存 Issue #60 の改訂案”; and
- issue #108's protocol-model acceptance constraint: beid consumes the
  facilitator specification and its conformance vectors and must not create a
  second canonical report/bundle/receipt authority.

Issue #144 and its 2026-08-20 comment, together with the corresponding issue #60
decision, establish a critical present-tense fact: **the facilitator
specification does not yet exist in this repository and its owner is
undetermined**. References in existing documents to “the facilitator spec” are
therefore dependency declarations, not evidence that a specification exists.

## 2. Terms

- **Observation record**: one device's signed claim about the rotating peer
  identifiers it observed in an event window. It is directional: A observing B
  is not evidence that B observed A.
- **Event-scoped signing key**: Barnard's per-event secp256k1 key derived from
  `DeviceSecret` and the event code. It is distinct from the owner key and from
  an optional wallet key.
- **Mutual observation**: one derived fact formed only from two independently
  signed, valid, reciprocal records for the same event and compatible time
  window: A reports B and B reports A.
- **Accepted input**: records that have passed the governing schema, signature,
  event, time-window, and publication/input-availability rules. The exact wire
  representation of that input remains blocked on issue #108.
- **Participation result**: the deterministic result obtained from the
  de-duplicated set of mutual observations under the event's published policy.
- **Organizer**: the party operating or facilitating the event. An organizer
  may publish event configuration and operate infrastructure, but is not an
  issuer of participation facts.

The owner named below owns the decision at that stage. Other components may
perform effects or consume the decision without becoming a second authority.

## 3. The six-stage contract

### Stage 1 — A and B independently observe each other

**Owner: SDK** (BLE observation and rotating-identifier production); the **app**
owns session/lifecycle effects and durable capture.

**Contract.** During the same event and compatible observation window, A must
receive B's rotating identifier and B must separately receive A's rotating
identifier. Neither callback implies the other. Each device retains its own
observed identifier set until it can produce its directional record. A venue
broadcast or organizer device may help an app discover or enter an event, but a
broadcast-only device supplies no reciprocal participant record.

**Already specified or implemented.** Barnard owns BLE and RPID behavior; its
core SDK specification defines rotating, window-correlatable identifiers while
rejecting stable identity derivation. In beid,
[`scan-protocol-model.md`](../specs/scan-protocol-model.md) §3 specifies one
RPID-observation report per ENIN window. The iOS production path accumulates the
actual peer RPID set in `SensingCoordinator` and passes it through
`ReportSubmissionRuntime` as `ReportSubmissionCapture.peerRpids`. Shared
`prepareMutualSensingObservation` rejects count-only legacy input and malformed
or duplicate observed RPIDs. Issue #114's accepted timing rule is recorded in
[`eventfound-window-signing.md`](../specs/eventfound-window-signing.md): only
recording-phase windows may become signed artifacts.

**Gap.** Android does not yet have the equivalent production reporting path.
More importantly, the repository has no end-to-end two-device evidence test in
which both directional records become verifier input. A new implementation
issue is required for the missing Android capture/submission caller and a
cross-device acceptance fixture. Local device counts and the shared aggregation
API's caller-supplied `mutual` flag do not close this gap.

### Stage 2 — both devices sign with the event-scoped key

**Owner: SDK.** The app invokes the operation and persists/transports the result;
it does not define a second key derivation or signature scheme.

**Contract.** A signs A's directional record using A's event-scoped signing key,
and B independently signs B's directional record using B's event-scoped signing
key. A wallet signature, owner-key signature, organizer signature, server
signature, unsigned peer count, or the other participant's signature cannot
substitute for either record signature. Private key material remains on its
originating device.

**Already specified or implemented.** Barnard
[`specs/092-owner-key/spec.md`](https://github.com/levarac/barnard/blob/8dce71e545177db94f79ff6c5898986a423f4b7d/specs/092-owner-key/spec.md)
§§“Terminology,” “Key hierarchy,” and “Barnard-native signature rules” separates
`KDF(DeviceSecret, EventCode)` event signing keys from owner keys and fixes the
native secp256k1 signature profile. The owner-key self-proof binds an event
signing public key and ENIN range to the owner key; it does not replace the
event-key signature on an observation. KMP-002 in
[`kmp-shared-foundation.md`](../kmp-shared-foundation.md) keeps Barnard key and
signature semantics in the native SDK. Today the shared
`PreparedObservationV1.sign(SignerPort)` boundary supplies a digest to a native
signer, and iOS `ReportSubmissionRuntime` prepares and signs such observations
through its Barnard-backed sensing cryptography facade.

**Gap.** The production path is not wired on both OSes, and no published
verifier currently proves that two independently produced device signatures
validate as one reciprocal pair. Android wiring and end-to-end signature vectors
need implementation issues. These issues must reuse Barnard conformance behavior
rather than reimplementing Barnard semantics in beid shared code.

### Stage 3 — verify signatures and the time window

**Owner: verifier.** The report server may reject invalid input early, but that
is defense in depth and does not replace independent verification.

**Contract.** For each candidate record, the verifier must, at minimum:

1. bind the record to the intended event and applicable event definition;
2. resolve the asserted observation key and its event/identity evidence under
   the governing Barnard and event-definition rules;
3. validate the observation signature against the exact signed content;
4. reject an invalid, malformed, wrong-event, or substituted key/signature;
5. confirm the observation window is inside the event's permitted time range;
   and
6. distinguish device-reported time from externally supported timing evidence.

A server acceptance receipt proves only the server's acceptance statement. It
is not by itself a peer observation, a second participant signature, or a
participation result.

**Already specified or implemented.** The whitepaper-derived
[`scan-protocol-model.md`](../specs/scan-protocol-model.md) §6 says timestamp
truth cannot rest on a self-reported timestamp alone; it rests on peer-signed
sightings plus later batch anchoring. Barnard's owner-key spec supplies
verification rules for self-proofs and key binding. Shared observation code
contains signature primitives and byte-exact test vectors, while shared
submission code verifies an operator's acceptance-receipt signature and checks
receipt timing against event-definition validity.

**Gap.** There is no complete public verifier that parses two published
participant records, validates their event-key/owner-key chain and observation
time policy, and emits a typed verdict. Receipt verification is narrower and
must not be presented as this stage. The permissible event-window rule and its
relationship to externally anchored publication are also not fixed by an
existing facilitator specification. A verifier implementation/spec issue is
required, and any wire-level part is blocked on #108.

### Stage 4 — match and de-duplicate one mutual observation

**Owner: report-server** for producing the published matched set; the
**verifier** must be able to recompute and check it rather than trust it.

**Contract.** Only after Stage 3 succeeds for both directional records may the
records be matched. A match requires the same event, compatible windows, and
reciprocal identity/RPID evidence: A's record contains B's applicable rotating
identifier and B's record contains A's. The pair yields exactly one mutual
observation. Replays, repeated submissions, duplicate identifiers within a
record, and the same directional pair encountered in a different order must not
increase the result. One directional record alone yields no mutual observation.

This document deliberately does not select a database natural key, byte-level
pair identifier, ordering rule, or bundle encoding; those belong to the missing
facilitator specification.

**Already specified or implemented.** The binding decision is explicit in
[`visibility-aggregation-ui.md`](../specs/visibility-aggregation-ui.md) §3.3:
mutuality cannot be inferred on one device and must come from a verifier
matching two signed records. The same boundary is stated in
[`eventfound-window-signing.md`](../specs/eventfound-window-signing.md) §8: a
broadcast-only venue device cannot create a false mutual observation because it
has no signed reciprocal report. Shared observation preparation rejects
duplicate RPIDs within one input record. The current aggregation reducer can
de-duplicate already-classified peer observations for display, but its `mutual`
value is an input; it does not perform reciprocal cryptographic matching.

**Gap.** No report-server specification or implementation in this repository
performs reciprocal matching and cross-submission de-duplication, and no
independent verifier recomputes it. This is the central unimplemented Stage 4
gap identified by #144. It requires a new implementation issue, dependent on
#108 wherever a natural key, receipt, bundle, or canonical encoding is needed.

### Stage 5 — every implementation derives the same result

**Owner: verifier** for the pure derivation and public conformance verdict.
The app and report server are consumers/implementations of the same rule, not
independent policy owners.

**Contract at the logical/interface level.** Given the same accepted set of
verified directional observations, the same event policy, and the same
de-duplication inputs, the device, report server, and any third-party verifier
must produce the same participation result. The derivation must be
deterministic, side-effect-free at its decision boundary, independent of input
arrival order, and covered by shared positive/negative conformance vectors.
Unknown, missing, invalid, or conflicting inputs must have explicit outcomes;
implementations may not silently repair them differently.

**BLOCKED ON ISSUE #108.** The canonical report/bundle/receipt wire format,
canonical serialization, report root, natural-key conflict behavior, and
publication conformance vectors require the facilitator specification. As of
the 2026-08-20 decision recorded on #144 and #60, that specification does not
exist here and its owner is undetermined. Therefore this contract fixes only
what must be equal, not the bytes or serialization by which equality is
established. Existing beid observation/submission code and provisional
`WindowReport` layouts are implementation evidence, **not** authority to fill
that absence. They must not be promoted into a second canonical format.

**Already specified or implemented.** Issue #106's merged
[`kmp-shared-foundation.md`](../kmp-shared-foundation.md) assigns deterministic
cross-platform models, validation, reducers, aggregation, and portable formats
to shared code, and expressly says facilitator-owned report encoding is not
owned by beid. Shared aggregation already demonstrates order-independent
roll-up and distinct-peer behavior once mutuality is supplied. Issue #60's
ledger work supplies crash recovery and duplicate-submission state, but not the
canonical mutual-result derivation or publication contract.

**Gap.** There is no facilitator specification, no authoritative published
input bundle, no mutual matcher, no result derivation shared by all three
actors, and no cross-implementation conformance suite. Do not open an
implementation issue that guesses the wire contract. First unblock #108 by
identifying the facilitator-spec owner and publishing its normative schema and
vectors; then create the derivation/verifier implementation issue against that
authority.

### Stage 6 — organizer cannot issue or override a result

**Owner: verifier.** It enforces the rule by accepting only reproducible
participant evidence and the published event policy.

**Contract.** The organizer may publish an event definition, operate a venue
broadcaster, run or select infrastructure, and publish data. None of those
powers is a direct participation-issuance API. A result is valid only if Stages
1–5 reproduce it. An organizer assertion, UI control, database flag, allowlist,
manual receipt, synthetic peer record, or replacement output cannot create a
missing device observation or participant signature and cannot override a
verifier's derived result.

Infrastructure signatures authenticate infrastructure statements only. For
example, an organizer/operator receipt can attest that particular bytes were
accepted at a time; it cannot attest that A and B observed each other. If the
organizer withholds required published data, an outsider's result is
“unverifiable/incomplete,” not organizer-selected “valid.”

**Already specified or implemented.** The repository's event-found ruling says
an organizer-mode venue device only broadcasts and signs no participant report,
so it cannot satisfy reciprocal matching. The whitepaper-derived trust model
separates physical-presence evidence from wallet or organizer assertions.
Event-definition and receipt keys in current shared code authenticate registry
and operator statements as separate roles; no existing code path is documented
as a legitimate organizer participation issuer.

**Gap.** Because no report server, public bundle contract, or complete verifier
exists, the repository does not yet prove the absence of an administrative
issue/override endpoint or prove that omitted data is detectable. The eventual
facilitator/report-server specification must state this negative capability,
and its implementation needs adversarial acceptance tests. Wire-level tests
remain blocked on #108; a server/verifier implementation issue is required
after that dependency is owned.

## 4. Acceptance matrix

| Stage | Decision owner | Present evidence | Acceptance status |
| --- | --- | --- | --- |
| 1. Independent sensing | SDK | Barnard BLE/RPID behavior; iOS RPID-set capture | **Partial** — Android and two-device fixture missing |
| 2. Independent event-key signatures | SDK | Barnard key roles/signatures; shared signer port; iOS caller | **Partial** — both-OS and paired verification missing |
| 3. Signature/time verification | verifier | Barnard verification pieces; receipt verification; time-model rule | **Gap** — complete verifier absent; wire aspects blocked on #108 |
| 4. Reciprocal match/de-dup | report-server | logical rule and local non-authoritative de-dup pieces | **Gap** — matcher/server absent; format-dependent parts blocked on #108 |
| 5. Identical derivation | verifier | KMP ownership rule and aggregation reducers | **BLOCKED** — facilitator spec/owner and conformance vectors absent (#108) |
| 6. No organizer issuance/override | verifier | role separation and broadcast-only venue rule | **Gap** — must be enforced in future server/verifier spec and tests |

The product may claim the full end-to-end promise only when every row is green
against the same published fixture. A green app test, SDK test, server test, or
receipt test in isolation is insufficient.

## 5. Third-party verification, step by step

This is the outsider acceptance walkthrough. It is intentionally executable at
the rule level today but cannot become a byte-exact recipe until #108 publishes
the facilitator format and conformance material.

1. **Obtain only published inputs.** Download the event definition/policy, the
   published participant observation records, and whatever inclusion or timing
   evidence the future facilitator specification requires. Do not request a
   private organizer verdict or trust a screenshot from either device.
2. **Verify provenance and event scope.** Validate the event definition and
   select only records bound to its event identifier and validity interval.
   Authenticate infrastructure statements under their own keys without
   treating them as participant observations.
3. **Validate every candidate record.** Decode it under the facilitator's
   eventual normative profile, preserve the exact signed content, validate its
   event-scoped public key and required Barnard self-proof/key-role evidence,
   and verify the device signature. Reject malformed, substituted, unsigned,
   wrong-event, or out-of-window records.
4. **Check time honestly.** Apply the published event-window policy and the
   required external inclusion/timing evidence. Never treat a device's own
   timestamp or a server's mere acceptance as sufficient proof of co-presence.
5. **Find reciprocal pairs.** For each valid A→B record, look for a valid B→A
   record in the same event and a compatible window. Confirm each record names
   the rotating identifier that the other device used for that window. Without
   both directions, record no mutual observation.
6. **De-duplicate.** Collapse replays, repeated submissions, duplicate RPID
   claims, and the A/B versus B/A ordering of the same pair so the reciprocal
   evidence contributes exactly once under the published natural-key rule.
7. **Derive the result.** Run the facilitator-spec conformance algorithm over
   the de-duplicated mutual set and event policy. The algorithm must not consult
   an organizer-maintained “approved participant” flag or accept an override.
8. **Compare outputs.** Compare the locally derived result and intermediate
   digests/identifiers with the published server result and, where available,
   the device result. Exact agreement is required. A disagreement is a failed
   acceptance test, not a choice of which authority to trust.
9. **Report one of three honest outcomes.** Return **verified** only when all
   required evidence and derivation checks pass; **invalid** when evidence or a
   signature/rule fails; or **unverifiable/incomplete** when required published
   data or the still-missing #108 contract is unavailable. Never convert the
   third outcome into organizer-issued success.

A technical outsider can therefore reproduce participation from public data
alone only after #108 supplies the missing normative wire contract and vectors
and Stages 3–6 are implemented. Until then, the gap is part of the result and
must be stated, not designed around locally.
