# Participant relay ENIN boundary

The B005 relay boundary is an unsigned 32-bit ENIN, not the full range of
Parallax Observation integers. Both native verifiers adapt SDK-verified
fields through `BeidSharedKit.event.participantRelayValidity`.

## Sources

Both hosts pin Barnard 0.9.2 (`61e2f0bacde14d78b18278bf743f587380f76cba`):
`android/app/build.gradle.kts`, `ios/project.yml`, and the committed
`ios/Beid.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.

- [Barnard spec 122, Signed envelope](https://github.com/levarac/barnard/blob/v0.9.2/specs/122-b005-v2-signed-envelope/spec.md#signed-envelope):
  “Integers are unsigned and big-endian.” Its table gives size **4** for
  `validFromEnin`, `validThroughEnin`, and `relayExpiresAtEnin` (offsets A+3,
  A+7, A+11). Thus the wire range is 0..4294967295.
- [Barnard Swift SDK](https://github.com/levarac/barnard/blob/v0.9.2/packages/swift/barnard/Sources/BarnardCore/BarnardParticipantRelay.swift):
  `registryVerified(eventId: [UInt8], validFromEnin: UInt32, validThroughEnin: UInt32, relayExpiresAtEnin: UInt32)`.
  The verified B005 envelope exposes the three fields as `Int64` before that
  relay API boundary.
- [Barnard Android SDK](https://github.com/levarac/barnard/blob/v0.9.2/packages/android/barnard/src/main/kotlin/org/levarac/barnard/BarnardParticipantRelay.kt):
  the corresponding `RegistryVerified` fields are `Long`, but admission uses
  `private val ENIN_RANGE = 0L..0xFFFF_FFFFL` and rejects any field outside it.
  Its verified B005 envelope also exposes the fields as `Long`.
- [Parallax mutual-sensing profile](https://github.com/levarac/parallax/blob/6fe165fd0146df4925fd1b59c236fe729dac7b29/protocol/spec/v0.1/mutual-sensing.md):
  `enin` is `uint`; “All `uint` values in this profile are limited to
  `0..9007199254740991`.” This is the Observation profile, not B005 field
  width. The cited revision is the source pin in
  `ParallaxEventDefinitionSourceChecksumTest`; shared Observation validation
  retains its existing wider range.

## Conversion policy

The wire format cannot encode 4294967296. Neither cited protocol specifies
whether a host adapter should reject or clamp an out-of-range SDK value.
For this defensive boundary, retain the existing iOS behavior on both hosts:

- Clamp `validFromEnin` below zero to zero; reject it above 4294967295.
- Clamp `validThroughEnin` to 0..4294967295.
- Reject `relayExpiresAtEnin` outside 0..4294967295; preserve an accepted
  signed expiry exactly, never extending its authorization.

For start 0, now 0, through 4294967296 and expiry 1, both hosts therefore
return start 0, through 4294967295 and expiry 1. Signature, registry agreement,
window ordering, and the 12-ENIN lifetime remain Barnard-owned checks.
A successfully decoded four-byte B005 field cannot itself exceed this range;
these tests exercise the host seam defensively.

## Shared ownership

| family | class | current_ios | current_android | ruling_or_invariant | owner | shared_symbol | licensing_test | platform_callers | status |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| relay numeric boundary | B / CONVERGE | UInt32 narrowing, through clamp | Long pass-through | B005 unsigned four-byte width; retain iOS fallback policy | beid host adaptation | participantRelayValidity | ParticipantRelayVerifierTest, ParticipantRelayValidityTest, ParticipantRelayTests | both ParticipantRelayVerifier adapters | wired |

This is a numeric representation check at the native boundary. It adds no
Barnard protocol decoding or semantic verification to shared code.
