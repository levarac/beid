# Spec — Onboarding redesign slice (Beid iOS)

Status: APPROVED 2026-07-26 by user. Cleared for implementation.
Owner: PM a-20260725-036. Implementer: SubPM a-20260726-001 → Worker.
Welcome CTA label confirmed: "Get Started".

## 1. Scope

Redesign the three onboarding screens to match the Figma "Beid - Native" board,
reconciled with the 2026-07-26 decision record. In scope:

- `01 Welcome` — `ios/Beid/Views/WelcomeView.swift` (Figma node `104:3`)
- `02 Bluetooth Guide` — `ios/Beid/Views/BluetoothPermissionView.swift` (Figma node `104:39`)
- `03 Bluetooth Off` — `ios/Beid/Views/BluetoothOffView.swift` (Figma node `104:112`)

Plus two new shared components and the wiring change to make the entry flow
**event-first**.

Out of scope (later slices, separate specs): event detection / event-code step,
wallet connect + binding signature, device signing keys, window-based reporting,
timeline visualizer, per-event wallet management, data ownership/iCloud sync.

## 2. Source-of-truth precedence

**Decision record > Figma > current code.** Where Figma conflicts with the
2026-07-26 decisions, follow the decisions. App display name is **"Beid"** —
never reintroduce "SenseProof" (the earlier name shown in the mock).

## 3. Flow (event-first, per 2026-07-26 decision)

```
Launch → 01 Welcome → [CTA] → 02 Bluetooth Guide → requestBluetoothPermission
        → evaluateBluetoothState()
              powered off → 03 Bluetooth Off → "I've turned it on" → evaluate again
              else        → home (Collection)
```

- Welcome does **NOT** connect a wallet. Wallet connect + binding happens later,
  after event confirmation (later slice).
- Set the onboarding entry to the event-first path (no upfront wallet). Concretely:
  Welcome's CTA proceeds to Bluetooth permission (the current `guestFirst` path:
  Welcome → Bluetooth), not the `walletFirst` branch. Resolve
  `OnboardingMode.current` to the event-first path.
- The event-code-entry alternative belongs to the later event-detection step, not
  to Welcome. No change to `EventCodeEntryView` in this slice.

## 4. Screen specs

### 4.1 — 01 Welcome (`WelcomeView.swift`, node 104:3)
- Layout per Figma: hero `welcome-mark` illustration, title, subtitle, single
  primary CTA. Keep existing copy where it already matches ("Prove you were there.
  Automatically.").
- **CTA (decision override):** primary button proceeds to Bluetooth permission
  (event-first) — it is **not** "Connect Wallet". Label (confirmed): **"Get Started"**
  → calls the event-first entry (→ `.bluetoothPermission`).
- **Do not** render the Figma "By connecting, you agree to the Terms & Privacy
  Policy" footer here — Welcome no longer connects; that footer moves to the later
  wallet-connect+binding step.
- Match Figma layout (hero + single CTA). If Figma omits the current 3-row metrics
  panel, remove it.
- Token compliance: replace raw colors / oversized SF Symbol with `DS.*` tokens and
  the `welcome-mark` asset.

### 4.2 — 02 Bluetooth Guide (`BluetoothPermissionView.swift`, node 104:39)
- Title "Enable Bluetooth". Subtitle rewritten to Beid wording (no "SenseProof").
- Three benefit rows, each with a **title + body sentence** (per Figma):
  "Events find you" / "Nearby events appear automatically — no codes, no search.";
  "Private by design" / "Only anonymous proofs are exchanged, never your identity.";
  "Zero effort" / "Sensing runs quietly in the background. Nothing to tap."
- CTA label **"Allow Bluetooth"**; footnote "You can change this anytime in Settings."
- **New component required:** two-line bullet row (title + body). Current
  `BeidBulletRow` has a title slot only (single call site here). Add a `BeidBulletRow`
  overload or a sibling type in `ios/Beid/DesignSystem.swift`.
- Wiring unchanged: CTA → `coordinator.requestBluetoothPermission()` →
  `BluetoothMonitor.start()` → grace delay → `evaluateBluetoothState()`.

### 4.3 — 03 Bluetooth Off (`BluetoothOffView.swift`, node 104:112)
- Title **"Bluetooth is off"** (sentence case, per DESIGN.md §15). Subtitle rewritten
  to Beid wording.
- **Numbered 3-step list** — "1 Open Settings / 2 Tap Bluetooth / 3 Switch it on".
- CTA "Open Settings" + secondary "I've turned it on".
- **New component required:** numbered step-list (nothing comparable exists today).
  Add to `ios/Beid/DesignSystem.swift`.
- Wiring unchanged: "Open Settings" → `sensingCoordinator.reset()` + open Settings URL;
  "I've turned it on" → `evaluateBluetoothState()`.
- Verification: `#Preview`/snapshot only — the iOS Simulator always reports BLE as
  powered on, so this screen can't be exercised live there.

## 5. New shared components (both token-compliant)

1. **Two-line bullet row** (title + body) — `DesignSystem.swift`, documented in
   `DESIGN.md §10`.
2. **Numbered step list** — `DesignSystem.swift`, documented in `DESIGN.md §10`.

Both: `DS.*` tokens only (no literals), light/dark via xcassets, Dynamic Type.

## 6. Copy & localization

- Rewrite copy per Figma but with "Beid". Use `String(localized:)` keys per
  `AGENTS.md`; build once so Xcode syncs new keys into `Localizable.xcstrings`, then
  fill `ja` / `zh-Hans` / `es` / `fr` as `needs_review`.

## 7. Acceptance criteria

- `xcodebuild -project ios/Beid.xcodeproj -scheme Beid -destination 'platform=iOS Simulator,name=iPhone 17 Pro' clean build` = **BUILD SUCCEEDED**.
- `scripts/lint.sh` passes (zero violations beyond baseline); the three screens no
  longer carry raw-color / raw-font / oversized-symbol / `.tint(.blue)` violations
  (decision: this slice also closes the migration debt on the touched screens).
- Visual matches Figma frames `104:3`, `104:39`, `104:112`. Exact colors/fonts/spacing
  pulled via `get_design_context` and mapped to `DS.*`; any genuinely new semantic
  token added via `Tokens.swift` + `Colors.xcassets` + `DESIGN.md §17` in the same PR.
- Flow: Welcome → Bluetooth (no wallet connect on Welcome); event-first respected.
- `DESIGN.md §10` updated for the two new components.
- `#Preview` for all three screens; screen 03 verified via Preview/snapshot.
- No unrelated changes; PR-sized; no `.xcodeproj` hand-edits (edit `project.yml` +
  `xcodegen generate` if project structure changes — not expected for this slice).

## 8. Open confirmations (minor)

- Welcome CTA label — RESOLVED: "Get Started" (confirmed by user 2026-07-26).
