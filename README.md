# beid

Web3-native reference implementation of the Levarac protocol — turn BLE mutual
observations at real-world events into verifiable, portable attendance proofs.

This repository was restarted from an empty history on 2026-07-09 for the
native rebuild (team ruling, MTG 2026-07-09). The previous Flutter
implementation is preserved in full on the [`archive/flutter`](../../tree/archive/flutter) branch.

## Layout

Read [`AGENTS.md`](AGENTS.md) before changing the repository. It summarizes
the current architecture and the required development and delivery contracts;
the detailed KMP procedure lives in
[`docs/kmp-shared-foundation.md`](docs/kmp-shared-foundation.md).

- `shared/` — project-internal Kotlin Multiplatform module built from the same checkout by both native apps
- `ios/` — native iOS app (SwiftUI, consumes the [barnard](https://github.com/levarac/barnard) SwiftPM package)
- `android/` — native Android app (Kotlin/Compose, consumes the barnard Gradle library)
- `.github/` — GitHub Actions workflow definitions governed by the PR CI contract in `AGENTS.md`
- `docs/` — implementation contracts, design notes, and operational flow
- `scripts/` — repository checks and local/CI toolchain helpers
- `compile-fixtures/` — negative compile proofs for stale platform bindings
- `lint/` and `lint-fixtures/` — the portable lint baseline and its behavior fixtures
- `DESIGN.md` — cross-platform product design and copy contract
