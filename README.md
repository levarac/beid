# beid

Web3-native reference implementation of the Levarac protocol — turn BLE mutual
observations at real-world events into verifiable, portable attendance proofs.

This repository was restarted from an empty history on 2026-07-09 for the
native rebuild (team ruling, MTG 2026-07-09). The previous Flutter
implementation is preserved in full on the [`archive/flutter`](../../tree/archive/flutter) branch.

## Layout (planned)

- `ios/` — native iOS app (SwiftUI, consumes the [barnard](https://github.com/levarac/barnard) SwiftPM package)
- `android/` — native Android app (Kotlin, consumes the barnard Gradle library)
- `backend/` — event/anchoring backend (batched on-chain commitment writes)
- `docs/` — design notes and operational flow
