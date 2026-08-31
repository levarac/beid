# Issue #145 — privacy constraints for the public observation schema

**Status:** schema audit and decision input; not a protocol decision

**Audited checkout:** 2026-08-31
**Scope:** data that could be published for third-party verification, not the
operator's private ingestion API

## 1. Result in one sentence

The repository has a canonical, signed per-window `ObservationV1` submission
format, but it has **no public blob/publication schema or publication code**.
Publishing those submitted COSE bytes unchanged would disclose an event's
window-by-window directed contact graph. It would therefore fail the
"no attendee roster/contact graph" promise even though the current shape has
no name or email field and keeps the owner key and wallet out of the
Observation.

This document does not choose how much evidence to reveal. Sections 6 and 8
make that choice explicit for the maintainer.

## 2. Sources and limits of this audit

The current executable data path is:

1. iOS snapshots the reporting RPID, the complete set of observed RPIDs, ENIN,
   event ID, event-definition digest, event signing public key, and optional
   participant commitment at window close.
2. Shared code canonicalizes those inputs into `ObservationV1`, embeds a
   `MutualSensingPayloadV1`, and signs the whole observation as COSE_Sign1.
3. iOS stores and sends the exact signed COSE bytes by HTTPS to the submission
   endpoint from the verified Event Definition. Submission is opt-in/inactive
   by default. Android has no corresponding production submission caller.
4. The operator returns an `AcceptanceReceipt`; neither that receipt nor the
   submitted Observation is published by this repository.

There is no DTO for a public dataset, no blob manifest, no redaction or
aggregation transform, no public-download endpoint, and no implementation of
facilitator publication. Issues #108 and #144 remain the place where that
missing operator/facilitator surface is expected to be specified. Accordingly,
this audit treats the exact submitted COSE bytes as the **maximum candidate
publication shape**, not as an already-approved public schema.

The whitepaper itself and `levarac/texts` are not checked into this repository.
The comparison below is therefore against the whitepaper invariants quoted by
current source/spec comments: the owner public key and wallet address are
cross-event identifiers forbidden from advertisements, GATT data, public
anchors, and witness blobs; the event commitment is the event-scoped opaque
form intended for peer sightings; self-proofs and wallet bindings are
holder-held and selectively disclosed. The canonical upstream owner-key issue
(`levarac/barnard#92`) says the same thing explicitly. If the current
whitepaper or texts draft has changed those rules, the facilitator schema
review must refresh this section before adoption.

## 3. Privacy invariants a public schema must enforce

A public schema and its producer MUST satisfy all of the following, including
against combinations of fields and multiple published records:

1. **No PII input:** reject names, email addresses, wallet addresses, free-form
   user text, device/account identifiers, and other direct identifiers. Do not
   merely omit named fields after accepting arbitrary maps or strings.
2. **No cross-event stable identifier:** do not publish an owner public key,
   wallet address/signature, owner-key self-proof, device secret derivative,
   or any deterministic unsalted derivative common to two events. Event
   signing keys and commitments are acceptable only if event scoping and
   domain separation are normatively enforced and event identifiers cannot be
   silently reused as a global person identifier.
3. **No unnecessary roster/contact graph:** the public result may reveal the
   aggregate facts the maintainer approves, but must not expose stable vertices
   and pairwise/window membership sufficient to enumerate attendees or infer
   edges. "RPIDs rotate" is not enough when the same publication also provides
   ENIN, both sides' RPIDs, and signed per-observer lists.
4. **No enrichment attachment:** holder-held wallet binding or self-proof data
   must not be joinable into the public blob as an optional convenience field.
   Optional publication still creates the cross-event link for everyone who
   uses it.
5. **Closed shape and bounded metadata:** unknown fields are rejected. Blob
   paths, object keys, uploader IDs, HTTP logs, receipt lookup keys, and
   timestamps need the same review as payload fields; a safe CBOR body does
   not neutralize identifying transport metadata.

## 4. Field-by-field audit of the maximum candidate shape

The numbers below are the current canonical CBOR integer labels. "Publish?"
means whether the field is defensible in a future public representation; it
does **not** authorize publishing the current record.

### 4.1 COSE_Sign1 wrapper

| Field | Current value/purpose | Publish? | Privacy justification or risk |
| --- | --- | --- | --- |
| CBOR tag | `18` (COSE_Sign1) | Safe | Protocol framing only; no participant identity. |
| Protected header `1` | algorithm `-47` (ES256K) | Safe | Algorithm identifier only. |
| Protected header `3` | `application/vnd.levarac.observation+cbor` | Safe | Content-type/profile marker only. |
| Protected header `4` (`kid`) | SHA-256 domain digest of the event signing public key | **Risk; redundant link handle** | It is event-scoped only if the signing key is genuinely per event. It repeats a stable within-event vertex and makes grouping trivial. Retaining the public key for signature verification already supplies that grouping; publishing both adds no privacy. |
| Unprotected headers | empty map | Safe only while empty | The closed-schema rule must reject additions; arbitrary headers would be an identifier injection point. |
| Payload | exact `ObservationV1` CBOR | See below | Contains the principal privacy risks. |
| Signature | 64-byte compact ES256K signature | Conditionally safe | Needed to authenticate the payload, but is linkable through its verification key and cannot make an unsafe payload safe. Deterministic signatures may also duplicate-identify identical signed inputs. |

### 4.2 `ObservationV1`

| CBOR | Field | Current value/purpose | Publish? | Privacy justification or risk |
| --- | --- | --- | --- | --- |
| 1 | `version` | `1` | Safe | Schema dispatch only. |
| 2 | `id` | random 16-byte window UUID | **Risk unless replaced or scoped** | Not PII by construction, but it is a durable per-window tracking/lookup handle and may be joinable with operator logs or receipts. A public manifest can use a content digest or publication-local index instead. Never accept an app/user-supplied stable ID without validation. |
| 3 | `profile` | `levarac.mutual-sensing/v1` | Safe | Fixed protocol constant. |
| 4 | `context` | 32-byte event ID | Conditionally safe | Required to prevent mixing events during re-aggregation. It identifies an event, not a person, but a public event ID can expose attendance context and enables all records for that event to be grouped. A public dataset could instead be partitioned by a publication-scoped event digest if the mapping itself is not required. |
| 5 | `observer` | 33-byte per-event signing public key | **High risk within event; forbidden if not provably per-event** | Needed for raw signature verification, but is a stable vertex for every window signed by one participant. It enables a roster of pseudonymous observers and, with `observedRpids`, graph reconstruction. It does not cross events only while `KDF(DeviceSecret, EventCode)` and unique event codes/scopes are enforced. |
| 6 | `observedAt` | floor of window-finalization Unix seconds | **Risk** | Exact time enables external correlation (venue cameras, posts, transport logs) and orders a person's windows. ENIN already gives a time bucket. Use a coarser event-relative bucket, epoch, or omit it unless the approved recomputation requires second-level time. |
| 7 | `subject` | reporter's 17-byte RPID | **High risk** | Together with ENIN it identifies the observer's radio pseudonym for the window. Other observations list RPIDs, so this field turns raw sightings into joinable directed edges and can reveal mutual pairs. It is not cross-event stable, but is a graph vertex within its rotation window. |
| 8 | `payload` | encoded mutual-sensing payload | See below | It contains raw encounter evidence. |

### 4.3 `MutualSensingPayloadV1`

| CBOR | Field | Current value/purpose | Publish? | Privacy justification or risk |
| --- | --- | --- | --- | --- |
| 1 | `eventDefinitionDigest` | 32-byte digest of the verified Event Definition | Safe/needed | Lets a verifier pin the rules and operator configuration used. It identifies an event definition, not a participant. It may duplicate `context`, but does not add a person-level join key. |
| 2 | `enin` | exposure-notification interval number | **Risk but potentially necessary** | A bucket is needed to test contemporaneity and RPID semantics. It also narrows presence time and makes RPIDs joinable in a window. Coarsening/epoch proofs reduce temporal leakage but reduce the public's ability to replay per-window rules. |
| 3 | `observedRpids` | sorted complete list of 17-byte peer RPIDs | **Critical: do not publish raw if promise 3 is retained** | This is an adjacency list. With each record's `subject`, `observer`, and ENIN, anyone can enumerate pseudonymous attendees per window, infer directed edges, select mutual edges, and reconstruct much of the event contact graph. Rotation limits duration; it does not prevent reconstruction inside a window or linkage via overlapping lists and observer keys. |
| 4 | `rpidClaim` | optional opaque, variable-length artifact; production currently sends `null` | **Unspecified/high risk** | Shape and privacy semantics are not validated beyond being bytes. An opaque extension can carry PII or stable identifiers. It must remain forbidden/null in a public profile until a closed sub-schema, size bound, domain separation, and privacy proof exist. |
| 5 | `participantCommitment` | optional 32-byte `H(event signing key ‖ owner key ‖ salt)` | Conditionally safe, with unresolved requirements | Intended to hide the owner key and wallet and be event-scoped. Safety depends on a specified, unpredictable/event-separated salt and a finalized byte layout. The current `EventCommitment` explicitly says salt derivation/length and wire layout are not finalized. Reuse or low entropy can make commitments linkable or dictionary-testable. Publication should reject it until those details and per-event unlinkability tests are normative. Even safe commitments remain stable within an event and can contribute to a pseudonymous roster. |

### 4.4 Submission and receipt fields that are not Observation fields

The durable client record also holds `eventCode`, operator endpoint and key,
operator ID, validity interval, observation digest, and exact signed bytes.
The acceptance receipt contains operator ID, observation digest, context,
`acceptedAt`, `mergeBy`, and policy digest under an operator signature.

These fields prove ingestion and policy timing, but they are not an approved
public manifest. In particular:

- `eventCode` may be human-entered or reused and must not become a person key;
  publish the canonical event context/digest only if needed.
- `observationDigest` is safe as content integrity but is also a durable join
  key back to operator access logs and the receipt lookup URL.
- exact `acceptedAt` and `mergeBy` expose submission timing; coarse policy
  epochs or a signed batch root may suffice.
- endpoint/operator ID/public receipt key identify infrastructure, not a
  participant, and can be public if public verification needs them.
- request IP address, authorization data, User-Agent, object name, and storage
  metadata are outside the current DTOs but can identify a participant. A
  facilitator privacy spec must give them retention and publication rules.

## 5. Wallet and owner-key linkage audit

### 5.1 What current code gets right

The event signing key is derived per event and signs the Observation. The
long-lived owner key is independently derived and is not an Observation field.
A wallet endorses that owner key, rather than replacing the event signing key.
The event commitment hashes the event signing key, owner key, and salt; no
wallet address is placed into it.

`SelfProofRecord` and `BindingRecord` are separate on-device, holder-held
artifacts. They are not embedded in `Proof`, `WindowReport`, `ObservationV1`,
or the report-submission record. Current production submission passes
`rpidClaim = null` and only the opaque participant commitment. Therefore,
**wallet connection after an event does not currently mutate or enrich the
already-signed Observation and does not create a cross-event public link**.

### 5.2 The boundary that must not be crossed

The owner key is deliberately long-lived and the wallet address is globally
recognizable. A self-proof contains the owner public key and a per-event
signing public key. A wallet binding contains the wallet address, owner public
key, wallet signature, nonce, and timestamp. Publishing either artifact—or a
stable digest/ID derived from either—alongside public Observations would link
one or more event signing keys to the same owner/wallet and directly violate
the no-cross-event-identifier promise.

Consequently the public schema must have no fields for self-proof, wallet
binding, owner public key, wallet address/signature, `proofId`, or binding
record ID. A verifier who receives those artifacts by holder-directed,
point-to-point selective disclosure may learn the chosen cross-event link;
the public dataset must not learn or persist it. Operator storage should also
keep that presentation path separate from observation ingestion so an
"optional verification" join cannot later become public by accident.

Residual risk remains in the participant commitment until its salt and event
scope are finalized. A commitment repeated across events, or a commitment
whose opening is later published globally, becomes a cross-event link even
without a literal owner-key field.

## 6. The three UX promises

### Promise A — no names or email addresses in records

**Current raw Observation:** no field is intended for name or email. Fixed
numeric CBOR keys and fixed-size cryptographic fields mostly enforce this.

**Not yet proven for publication:** `rpidClaim` is arbitrary bytes, public blob
extensions do not exist, and transport/object metadata is unspecified. Thus a
future publisher could accept encoded PII without violating the current Kotlin
types.

**Closure requirement:** a closed public schema; `rpidClaim` absent/null until
specified; no arbitrary strings/maps; size/shape validation; explicit rejection
of wallet and account data; metadata minimization and retention rules. Event
metadata (for example display name or venue) is not attendee PII by definition,
but it increases sensitivity of the attendance facts and should be explicitly
classified.

### Promise B — do not reuse the same identifier across events

**Current raw Observation:** conditionally holds. RPIDs and the event signing
public key are designed to be event-derived; owner key and wallet are absent.

**Residual risks:** event-code reuse makes the deterministic event signing key
repeat; an incorrectly scoped participant commitment can repeat; publishing a
self-proof, wallet binding, owner-key derivative, or wallet address creates an
immediate cross-event join; exact timing and external operator logs can create
probabilistic linkage even without a stable protocol identifier.

**Closure requirement:** canonical event-instance scoping (not merely a
reusable display/join code), test vectors proving different event instances
derive unlinkable signing keys/RPIDs/commitments, specified random/event-bound
commitment salt, and a schema-level negative invariant excluding owner/wallet
shapes and their stable derivatives. Re-publication of the same event may keep
its identifiers for reproducibility, but must not silently be treated as a new
event.

### Promise C — do not build an attendee roster or contact graph

**Current raw Observation:** fails if published. A reconstruction procedure is
straightforward:

1. group records by `context` and `enin`;
2. use each stable `observer` key as a pseudonymous participant vertex;
3. map that record's `subject` RPID to the observer for the window;
4. for every `observedRpids` member, add a directed sighting edge from the
   observer/subject to that RPID;
5. join another record whose `subject` equals that RPID to name its
   pseudonymous observer vertex; and
6. retain reciprocal edges for mutual encounters, then link windows through
   the stable observer key and overlapping adjacency sets.

Even unmatched RPIDs reveal a per-window attendee/device roster and degree
information. Signatures make the graph more trustworthy; they do not blind it.

**Minimum closure requirement:** do not publish per-observer raw RPID lists and
reporter RPIDs in directly joinable form. The exact amount of additional
blinding/aggregation is the maintainer decision below.

## 7. Disclosure designs and the verifiability tradeoff

These are neutral design points, not a recommendation.

| Public disclosure level | What the public can recompute | Privacy consequence |
| --- | --- | --- |
| **Raw signed Observations** (current maximum candidate) | Canonical encoding, every participant signature, temporal validity, every sighting, mutual-edge selection, deduplication, and all event totals from first principles | Maximum auditability; also reconstructs a pseudonymous roster and contact graph. Incompatible with promise C. |
| **Event-scoped pseudonyms + blinded/hashed RPIDs** | If deterministic in the event/window, the public can still match equal values and recompute mutual edges and totals | Hashing is not aggregation. It preserves the graph topology and is vulnerable to small-domain/equality analysis; it closes neither roster nor graph reconstruction. |
| **Per-window aggregate records** (counts/histograms, no observer/subject/list), signed by an operator or threshold of facilitators | Recompute event totals and policy application from published window aggregates; cannot independently replay which pair contributed or detect all duplicate/Sybil inputs | Removes explicit edges, but small windows and exact timestamps can reveal attendance/degree. Suppression thresholds, coarse time buckets, and possibly noise are needed; these make exact totals unavailable or delay publication. |
| **Event aggregate + commitments/Merkle root to private raw evidence** | Verify the published total is bound to a committed private dataset; challenge/audit access can check selected leaves | Public cannot independently recompute the total without all openings. Selective openings may leak edges; trust moves to facilitator/auditor or a dispute protocol. |
| **Zero-knowledge validity/aggregation proof** | Verify stated rules and totals without seeing vertices/edges, if the circuit covers signature validity, event/window membership, deduplication, and aggregation | Best separation in principle, but adds circuit/setup/prover complexity, makes rule changes costly, and still reveals chosen aggregate outputs. Not implemented or specified here. |
| **Differentially private/noisy aggregates** | Recompute that the published dataset was processed under a declared mechanism only with verifiable randomness/proofs; cannot recover an exact ground-truth total | Stronger protection for small groups and differencing attacks, but conflicts most directly with exact re-aggregation and requires a privacy budget across repeated releases. |

Encryption or access control alone does not satisfy the promise that published
data is safe: during a promised public verification period every recipient can
copy plaintext. Deleting it later does not undo disclosure. Likewise, blind
signatures hide signer identity from an issuer but do not by themselves hide
the adjacency list from a public reader.

Whichever level is selected needs a release-composition analysis. Multiple
"safe" aggregates over overlapping windows, filters, or revisions can be
differenced to recover small groups or individual contributions. Minimum
cohort size, window width, query/release budget, revision policy, and retention
period belong in the schema contract rather than only in server operations.

## 8. Maintainer must decide

No implementation of a public blob should proceed until the maintainer records
answers to all of these:

1. **Verification target:** Must "anyone can re-aggregate" mean replaying each
   signed pairwise observation from first principles, or is independently
   summing authenticated per-window/event aggregates sufficient?
2. **Allowed public outputs:** Which exact totals, histograms, time resolution,
   and breakdown dimensions are promised? Are small-cell suppression or noisy
   results acceptable?
3. **Graph boundary:** Is any pseudonymous within-event vertex/degree/edge
   disclosure acceptable, or must the public view contain no participant-level
   rows at all? State the tolerated residual risk rather than relying on the
   word "blinded."
4. **Trust model:** If raw observations remain private, who may inspect them,
   under what challenge/audit process, and is an operator signature, multiple
   facilitator signatures, a committed dataset with openings, or a
   zero-knowledge proof required?
5. **Event identity:** What creates a unique event *instance*, and may an
   `EventCode` ever be reused? This decides whether current deterministic event
   signing keys can repeat across nominal events.
6. **Commitment profile:** Finalize participant-commitment byte layout, salt
   generation/entropy, event-domain separation, lifetime, opening rules, and
   unlinkability tests. Until then, is the field forbidden from public blobs?
7. **`rpidClaim`:** Define and audit a closed sub-schema or require `null` in
   every public record. Arbitrary bytes cannot be grandfathered into a privacy
   boundary.
8. **Time disclosure:** Choose second, ENIN, coarser epoch, event-relative
   bucket, or no public time, and document which fraud/re-aggregation checks
   are lost at the chosen granularity.
9. **Signature disclosure:** If participant public keys are removed, what
   authenticates aggregates? Decide whether participant signatures stay
   private under a batch commitment/proof or whether a facilitator attests the
   aggregate.
10. **Wallet/self-proof rule:** Confirm normatively that wallet bindings,
    self-proofs, owner public keys, wallet addresses/signatures, their stable
    derivatives, and app-local record IDs are prohibited from public blobs and
    remain holder-directed disclosures only.
11. **Release composition:** Set minimum cohort/window sizes, overlapping-query
    rules, revision behavior, public verification duration, deletion policy,
    and safeguards against differencing across successive blobs.
12. **Metadata and enforcement:** Specify uploader/network-log retention,
    object naming, unknown-field rejection, negative schema tests, and a test
    that no public shape accepts PII, a 20-byte wallet address, a 33-byte owner
    key, or a cross-event-stable derivative.
13. **Source-of-truth refresh:** Reconcile these decisions against the current
    whitepaper and `levarac/texts` blinding discussion when those sources are
    available to the facilitator-schema change; record any divergence instead
    of silently treating this repository's quotations as the complete text.

## 9. Gate for a future public-blob schema

A future schema can satisfy issue #145 only when its field table is as explicit
as section 4, includes the chosen aggregation/blinding transform, and carries
executable negative fixtures for the three promises. In particular, a test
that merely scans field names for `name`, `email`, `wallet`, or `owner` is not
enough: it must also reject opaque extension bytes and demonstrate that two
events cannot produce the same participant handle, while a graph-reconstruction
test must fail to recover participant vertices or edges beyond the residual
risk the maintainer explicitly accepted.
