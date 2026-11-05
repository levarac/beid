# Android venue link input and pack controls

Refs #603, the Android follow-up to #597. Based on the unmerged shared schedule
verification branch at `38312047` (PR #772).

iOS is intentionally untouched: its link input already shipped in PR #599.
The references are `VenueSignedServingViewModel.supply(link:)` for shared
fragment decoding, the named event before acquisition, and HTTPS-only fetching;
`VenueSignedServingView.statusSection` for pack identity and outcomes; and its
start/refresh control for rechecking a pack before requesting the radio.

## Behavior

- Keep one link field. Paste and scanner results enter `VenueController.useLink`.
- Reuse `SharedVenuePackImporter`, the shared link decoder and identity/schedule
  verification. Native acquisition continues to refuse redirects, non-HTTPS URLs
  and oversized responses. No second decoder or verifier is introduced.
- Show the event claimed by the link before fetching, separately from the pack
  checked by import. Only a verified permit supplies the displayed event name.
- Show the current pack, validity and radio request first. Input/import errors
  do not stop or relabel an active radio request. A newly checked replacement
  stays pending until the explicit Start/Refresh action.
- Start/Refresh runs the same importer again and waits for Bluetooth permission.
  Stop, a superseding input and disposal invalidate delayed completions.
- Keep copy in Android resources and map internal block codes to everyday text.
  A successful SDK call is described as a request, without claiming on-air proof.

## QR decision remains open

The declared and resolved Android runtime dependencies contain no camera or QR
scanner. Neither AGENTS.md nor android/README.md names one; #603 asks for a
platform API and forbids adding a third-party dependency. This change adds none.
`VenueQrLinkScanner` returns the original link or an unavailable/cancelled result.
The default `UnavailableVenueQrLinkScanner` requests no permission. The visible
Scan button explains that this build needs a pasted link. Compose tests inject a
scanner double and prove its payload goes through the same shared decode and
acquisition path, without starting the radio.

This is partial coverage of #603. Selecting/integrating an allowed QR provider
remains a decision; camera permission prompts and device/BLE checks are outside
this change. Existing in-memory pack storage, runtime lease expiry/slice switching
and OS radio lifecycle behavior remain outside this input/screen change.

## Evidence

The tests-only commit records failing screen and control expectations. JVM tests
also preserve the existing shared decode, missing address, HTTPS restriction,
digest mismatch and complete import schedule contracts using signed fixtures.
`VenueScreenScreenshotTest` draws a Robolectric ComposeView onto a Canvas.
PNG output is opt-in via the test JVM property `beid.venue.screenshotDir` and is
never committed. These rendered fixtures prove screen layout, not camera or BLE.
