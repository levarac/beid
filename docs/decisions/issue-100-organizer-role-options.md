# Issue #100 — organizer-role authorization options

**Status:** decision proposal, not an implementation specification
**Scope:** the one organizer-role question still open in [issue #100](https://github.com/thegreeting/beid/issues/100)

**Correction (2026-08-31, Fable-audited against primary sources):** the original
Option 3 below targeted the wrong on-chain primitive and priced it as a
from-scratch design. `registrar`/`operator` are chain-write roles only (append
event-definition anchors / commitment anchors — see
`parallax/protocol/spec/v0.1/ethereum.md`). The actual designed "who speaks for
this event" primitive is the **authority key set** (`EventKeySetV1`), a
threshold-1 set of secp256k1 keys whose digest is baked into the eventId at
registration (`parallax/protocol/spec/v0.1/event-definition.md`). Most of the
plumbing to read and verify it already exists in beid (fetch, on-chain digest
check, CBOR decode, secp256k1 verify, and the device already holds a
compatible owner key). A demo-appropriate version of this gate — a local check
that the venue device's own key is in the event's key set — is on the order of
days, not a separate production feature. The corrected Option 3 below reflects
this; **the demo recommendation is unchanged (Option 1 for 9/1)**, only the
production-path cost and primitive are corrected.

## What is already settled

The issue's original questions should not be reopened here:

- **Sender-side UI:** shipped as issue #138 in PR #187 (`VenueDeviceOrganizerView`).
- **Hint trust display:** shipped with #138/PR #187; the organizer screen says that beid does not verify the broadcast, and the receiving design treats B005 as an unauthenticated hint.
- **Code distribution:** effectively resolved by the decision to adopt B005 discovery; this document does not propose a second distribution mechanism.
- **Receiver-side implementation order:** belongs to issue #141, not issue #100.

The remaining issue #100 decision is narrower: **who may turn on organizer/venue-device broadcasting for an event?**

## Current facts and threat boundary

The shipped iOS route is Account → Venue Device. The view passes only
`SensingCoordinator.joinedEventCode` into `toggleOn`; the view model checks that
an event was joined, that the label is valid, and that the validity dates are
ordered. It performs no authentication, role, permission, administrator,
registrar, or ownership check. The Barnard adapter then sets
`organizerDesignated: true` itself. Consequently, any device that knows and has
joined an event code can use beid's UI to claim organizer mode for that event.
The assignment history is local and unsigned, so it is not authorization
evidence.

This gate could reduce misuse through the official beid UI, but it cannot make
B005 trustworthy on the air. B005 hints remain unauthenticated, and a determined
nearby attacker can use another client or the Barnard SDK to broadcast a false
hint. Receiver-side trust treatment must therefore remain in place under every
option below.

The repository does contain a read path for EventRegistry facts. A resolved
registration exposes `registrarHex` and `operatorHex`, plus the event's key-set
and definition anchors. However, the apps currently provide a **reader**, not an
event-creation/registration transaction flow, and the organizer screen has no
wallet-address challenge or proof that the current device controls either
registry address. “Check EventRegistry” is therefore not a small conditional;
it requires an identity-proof and provisioning design as well.

## Option 1 — keep organizer mode open/self-service

Any device that has joined an event may enable venue-device mode, as today. Make
this an explicit policy rather than implying that the missing check is security.
Keep the existing warning and low-visibility placement.

- **Who can grief:** any attendee who learns the event code can use the official
  app to rebroadcast the event with a misleading label. Anyone able to run a
  custom Barnard client could do this regardless of the app gate.
- **Legitimate-organizer friction:** none beyond joining the event and entering
  the label and validity period. A replacement venue phone can be activated
  immediately without accounts, wallets, or coordination.
- **Cost before the demo:** no product-code work. The only immediate work is to
  record that open access is intentional and ensure demo operators understand
  that it is not proof of authority.
- **Tradeoff:** best demo reliability and lowest schedule risk, but beid itself
  offers the easiest path for casual (not merely determined) impersonation. The
  warning describes the trust limit but does not prevent disruption.

## Option 2 — gate with a manually shared organizer secret

Give each event an organizer PIN or high-entropy secret through a channel
separate from the attendee event code. A venue device must enter it before the
broadcast toggle is enabled.

A short PIN is only a deterrent unless attempts are rate-limited; a scannable or
pasteable high-entropy secret is materially stronger but adds provisioning and
recovery work. Storing a verifier rather than the plaintext secret avoids one
local disclosure path, but a real design still has to define who creates it,
where the verifier is authoritative, how replacement devices receive it, and
how rotation/revocation works.

- **Who can grief:** an attendee with only the event code cannot use the beid UI
  to claim organizer mode. Anyone who obtains or is forwarded the organizer
  secret can; a custom Barnard broadcaster remains possible.
- **Legitimate-organizer friction:** every venue phone needs a second credential.
  Forgotten, mistyped, expired, or unavailable secrets can block setup at the
  venue. Sharing the same secret makes replacement easy but weakens attribution
  and revocation.
- **Cost before the demo:** medium and easy to underestimate. A demo-only local
  hardcoded PIN would not authorize an event and must not be presented as this
  option. A credible version needs provisioning, secure storage, validation,
  failure UX, tests, and an operator runbook, on both platforms once an Android
  organizer surface exists.
- **Tradeoff:** blocks casual misuse without requiring a wallet, but creates a
  new credential lifecycle that is not backed by EventRegistry and may become
  throwaway work.

## Option 3 — require proof of EventRegistry authority key-set membership (corrected)

Permit organizer mode only after the device proves its own key is a member of
the event's **authority key set** (`EventKeySetV1`), the primitive
`EventRegistry` actually designed for this ("who speaks for this event"),
digest-committed into the eventId at registration and already fetched,
digest-verified, and CBOR-decoded by existing shared code
(`EventDefinitionFetcher.kt`, `EventDefinitionCborCodec.kt`). This replaces the
original draft's target of the `registrar`/`operator` addresses, which are
chain-write roles for definition/commitment anchors, not an event-speaking
role — the wrong primitive.

Two shapes, different cost:

- **(a) Local membership gate (demo-appropriate).** The device's own owner
  public key (already generated on-device, `OwnerKeyProvider.swift`) must
  appear in the resolved event's `authorityKeys` list. No network round trip,
  no signed challenge, no expiry/revocation. Needs: expose the decoded key list
  (or a membership predicate) alongside the resolved definition — additive to
  code that already runs; make the venue-toggle check async against that
  resolution (the toggle is currently synchronous,
  `VenueDeviceOrganizerViewModel.swift`); UI to show/copy the device's owner
  public key for provisioning; and registering the demo event with the venue
  device's key included in its key set (parallax-side, not app code — a
  Sepolia-registered event already exists as a template,
  `SepoliaEventRegistryIntegrationTest.kt`). **Order of days, not a separate
  production feature.** Explicitly excluded from this shape: signed challenge,
  replay/expiry, revocation, a delegation artifact, Android surface.
  **Caveat:** an authority key can rotate the event's receipt key and
  submission endpoint — putting a venue device's key in the set makes that
  device a full event authority, not a scoped delegate. Fine for a demo run by
  a single trusted operator; wrong as the general pattern.
- **(b) Remote proof (production).** A wallet- or key-signed challenge proving
  control of a specific authority key, without needing that key resident on
  the device. This is closer to the original draft's cost estimate (signed
  format, replay/expiry, wallet UX) and is contingent on a signature-to-pubkey
  recovery path that was not confirmed to exist yet (Barnard's signing surface
  exposes `verify`, not confirmed `recover`).

- **Who can grief:** an ordinary attendee cannot claim organizer mode through
  beid. A holder of an authority key (or, for shape (b), a valid delegated
  proof) can. Custom clients can still emit unauthenticated B005 regardless, so
  receivers still must not treat a hint as registry-authenticated.
- **Legitimate-organizer friction:** shape (a) needs the venue device's key
  included at event registration time (a provisioning step, not a day-of
  ceremony); shape (b) needs a signing flow per activation.
- **Cost before the demo:** shape (a) is realistically scoped to days once
  prioritized — most of the read/verify path already exists — but was not
  built by 9/1, so it does not change tomorrow's recommendation. Shape (b)
  remains high-cost and is the production target.
- **Tradeoff:** shape (a) is a cheap, real authorization check tied to a
  primitive the protocol already designed for this, at the cost of over-broad
  authority per device unless a scoped venue-role artifact is added later
  (`ethereum.md` notes roles belong in signed off-chain artifacts — that
  artifact does not exist yet and is the actual remaining production design
  work, not the key-set check itself).

## Recommendation

**For the imminent demo, choose Option 1 explicitly and time-box it.** It is the
only option with essentially zero implementation and operational risk before the
demo. The threat model must be stated accurately: this accepts casual griefing
through beid's own UI and does not make the broadcast authoritative. It must not
be described as “authorized because the device joined”; possession of the
attendee event code is not organizer proof.

**For production authorization, target Option 3 shape (a) as a near-term
follow-up, not a distant one.** EventRegistry already designed the authority
key set for exactly this role, and most of the read/verify path is already
built — a scoped venue-role delegation artifact (shape (b) or better) remains
the real longer-term work. It should be scoped in a follow-up issue and must
not block receiver-side #141 work. Option 2 is justified only if a gate is
needed before the key-set check lands and the team is willing to own secret
distribution and recovery.

### Ken's decision

Evidence can establish the implementation cost and who each option excludes;
it cannot select the acceptable business risk. Ken must explicitly decide:

1. whether the demo may ship with open organizer mode and the known casual-
   impersonation risk;
2. whether open mode is demo-only (with a removal/authorization follow-up) or an
   intentional product policy; and
3. whether the near-term follow-up should be Option 3 shape (a) (local
   authority-key-set membership check, days of work, over-broad per-device
   authority) and, if so, who owns provisioning the venue device's key into
   the event's key set at registration time.

Until that call is recorded, the accurate current-state label is **open
self-service organizer mode**, not “organizer-authorized mode.”
