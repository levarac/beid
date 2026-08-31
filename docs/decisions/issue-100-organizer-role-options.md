# Issue #100 — organizer-role authorization options

**Status:** decision proposal, not an implementation specification
**Scope:** the one organizer-role question still open in [issue #100](https://github.com/thegreeting/beid/issues/100)

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

## Option 3 — require proof of EventRegistry authority

Permit organizer mode only after the device proves control of the event's
on-chain `registrarHex` or `operatorHex` address. The app would resolve the
canonical event, request a domain-separated signature over an organizer
authorization challenge (including event ID, venue device key, scope, and
expiry), and verify it against the selected registry authority. For venue
operations, a delegatable, expiring authorization is preferable to requiring
the registrar's wallet at every door device.

- **Who can grief:** an ordinary attendee cannot claim organizer mode through
  beid. A registrar/operator or a holder of a valid delegated authorization can.
  Compromise or over-broad delegation remains harmful, and custom clients can
  still emit unauthenticated B005, so receivers still must not treat a hint as
  registry-authenticated.
- **Legitimate-organizer friction:** highest at initial setup: the event must be
  registered, the correct authority wallet must sign, and venue devices must be
  delegated. With reusable scoped delegations, day-of-event replacement can be
  reasonable; without them, it is operationally brittle.
- **Cost before the demo:** high and unsuitable as a last-minute gate. The
  current repository has registry reads but no event-registration transaction
  UI or organizer authorization ceremony. This option needs a signed format,
  replay/expiry rules, wallet UX, persistence, revocation semantics, native
  adapters, and both-platform tests.
- **Tradeoff:** aligns authority with the existing canonical registry and avoids
  inventing a parallel organizer database, but it is a separate security and
  provisioning feature, not a patch to `VenueDeviceOrganizerView`.

## Recommendation

**For the imminent demo, choose Option 1 explicitly and time-box it.** It is the
only option with essentially zero implementation and operational risk before the
demo. The threat model must be stated accurately: this accepts casual griefing
through beid's own UI and does not make the broadcast authoritative. It must not
be described as “authorized because the device joined”; possession of the
attendee event code is not organizer proof.

**For production authorization, target Option 3 rather than building Option 2
as a permanent parallel credential system.** EventRegistry already identifies a
registrar and operator, so a scoped, expiring delegation from one of those
authorities is the most coherent long-term basis. It should be designed in a
follow-up issue and must not block receiver-side #141 work. Option 2 is justified
only if a near-term deployment needs a deterrent before registry-based
provisioning exists and the team is willing to own secret distribution and
recovery.

### Ken's decision

Evidence can establish the implementation cost and who each option excludes;
it cannot select the acceptable business risk. Ken must explicitly decide:

1. whether the demo may ship with open organizer mode and the known casual-
   impersonation risk;
2. whether open mode is demo-only (with a removal/authorization follow-up) or an
   intentional product policy; and
3. for the registry-backed design, whether the registrar, operator, or both may
   issue venue-device delegations, and what operational recovery is required.

Until that call is recorded, the accurate current-state label is **open
self-service organizer mode**, not “organizer-authorized mode.”
