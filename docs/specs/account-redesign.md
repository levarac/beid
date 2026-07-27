# Spec — 09 Account Sheet redesign (Beid iOS)

Status: APPROVED 2026-07-27 by user (recommended options). Cleared for implementation.
Owner: PM a-20260725-036.
Scope strategy: model-independent visual reskin (parallel to the Scan model work).
Resolved open items (§5): (1) "How sensing works" row = DEFER (omit this slice).
(2) Chrome = keep the "Done" button; simplify/drop the large nav title. (3) Keep the
current single-wallet behavior; defer multi-address/per-event to the Scan model work.
Survey: `docs/redesign-account-survey.md`. Figma: `xf2uFHceIYg0h0gJndUkmI` node `104:463`.

## 1. Scope

**IN**: visual reskin of `ios/Beid/Views/AccountSheetView.swift` to Figma `104:463`,
keeping current behavior (single wallet connect/disconnect, Bluetooth status). Adopt
Figma's leading-icon menu-row layout for all three groups. Fix the one token
violation (raw `.orange`/`.green`) with a proper token.

**OUT (defer)** — per the Scan model work, keep the CURRENT single-wallet behavior;
do NOT implement the per-event / multi-address / wallet-switcher model here. Session
teardown stays out of scope (as today). See §5 open item.

## 2. Source-of-truth precedence

Decision record > Figma > current code. `DESIGN.md` is the design/token contract. Note:
`AccountSheetView`'s plain `List`/`Section` rows are the contract-mandated choice
(DESIGN.md §8/§2.10 — standard containers get Liquid Glass for free; do NOT wrap in
`beidSurface` = glass-on-glass). Keep `List`-based rows.

## 3. Screen spec (`AccountSheetView.swift`, node 104:463)

Presentation unchanged: `.sheet` + `.presentationDetents([.medium])` + drag indicator
(already matches Figma). Three groups as leading-icon rows:

### 3.1 Wallet group
- Connected: leading icon + truncated address (`DS.Font.ledgerMono`,
  `prefix(6)…suffix(4)` — unchanged) + subtitle **"Connected via {connector}"**
  (connector name from `recordWalletConnection(connector:)`; fallback "WalletConnect")
  + trailing **copy-address** icon button (recommended reading of Figma's trailing
  38×38 icon; `.accessibilityLabel("Copy address")`).
- Disconnected (Figma doesn't draw this): keep the current "Connect Wallet" affordance
  (`connectWalletFromAccountSheet()`), styled to match the row layout.

### 3.2 Menu group (one card, hairline-divided rows)
- **Bluetooth row**: leading icon + "Bluetooth" + trailing status badge (dot + label).
  Label **"Active"** when on; **"Off"** when off (keeps current on/off semantics).
  Dot/label color via a NEW neutral status token (see §4) — replaces raw `.orange`/`.green`.
- **"How sensing works" row** (net-new; not in the app today): **OPEN — see §5.1.**
  Default recommendation: **defer** (omit this row from this slice) until its
  destination + copy are decided.

### 3.3 Disconnect group
- Leading-icon menu row **"Disconnect Wallet"** (destructive intent via
  `DS.Color.statusCaution` or the existing destructive treatment; disabled when
  `walletAddress == nil`), calling `disconnectWallet()`. Render as a leading-icon row
  matching the other groups (not SwiftUI's centered destructive button), per Figma.

### 3.4 Chrome
- Keep the **"Done"** toolbar button for an explicit, accessible dismiss (Figma draws
  grabber-only, but drag-only dismiss is less accessible). Recommend dropping the large
  nav title to match Figma's cleaner sheet, keeping the inline "Account" title or none.
  **OPEN — see §5.2.**

## 4. New token (design-system)

- Add a neutral on/off status color pair for the Bluetooth badge — e.g.
  `DS.Color.statusOn` / `DS.Color.statusOff` (adaptive light/dark colorsets), because
  no existing token fits (`signalWarning` = recovery-only, `statusCaution` =
  signature-failure-only). Add via `Tokens.swift` + `Colors.xcassets` + `DESIGN.md §17`
  in the same PR. This closes the `.orange`/`.green` Non-Negotiable-#1 violation.

## 5. Resolved decisions (approved 2026-07-27)

1. **"How sensing works" row** — DEFER: omit from this slice (keep it a pure reskin).
   Revisit later with a real destination + copy.
2. **Chrome** — keep the "Done" toolbar button (accessible dismiss); drop the large
   nav title to match Figma's cleaner sheet (inline "Account" or none).
3. **Single-wallet deferral** — YES: Account keeps the current single-wallet
   connect/disconnect behavior; multi-address/per-event/switcher deferred to the Scan
   model work.

## 6. Acceptance criteria
- clean build = BUILD SUCCEEDED.
- `scripts/lint.sh` = 0 violations; the raw `.orange`/`.green` is gone (token-backed).
- Visual matches Figma `104:463` (values via `get_design_context` → `DS.*` tokens).
- New status token documented in `DESIGN.md §17` (+ any component note in §10).
- `#Preview` for `AccountSheetView` (light + dark; connected state — and disconnected
  state if a preview is cheap).
- Behavior unchanged (connect/disconnect/Bluetooth status); no multi-wallet model.
- New/changed copy localized (ja/zh-Hans/es/fr `needs_review`) per `AGENTS.md`.
- UI tests still pass (`-testLanguage en -testRegion US`); update if any assertion
  touches the Account sheet chrome.
- PR-sized; no `.xcodeproj` hand-edits.

## 7. Branch note
- Base on `main` after PRs #67/#68 merge; else a fresh branch from `origin/main`
  (independent). Decide at implementation time.
