# Lint fixtures (DESIGN.md §16)

Executable proof that the custom rules in `.swiftlint.yml` behave as
documented, against the pinned SwiftLint version (0.65.0).

- `LintFixtures_pass.swift` — sanctioned `DS.*` usage plus known
  false-positive near-misses. Expected: **0 violations**.
- `LintFixtures_fail.swift.txt` — one violation per `// FAIL <rule>`
  comment. Stored as `.swift.txt` so neither the compiler nor a normal
  lint run sees it. Expected: **every FAIL line flagged**.

Both files live outside the app's compile scope (`ios/Beid`); the per-rule
`included:` paths in `.swiftlint.yml` only match `ios/Beid/**`, so the
proof run copies them there temporarily.

## Proof run

From the repo root:

```sh
cp lint-fixtures/LintFixtures_pass.swift ios/Beid/LintFixtures_pass.swift
cp lint-fixtures/LintFixtures_fail.swift.txt ios/Beid/LintFixtures_fail.swift
scripts/lint.sh
rm ios/Beid/LintFixtures_pass.swift ios/Beid/LintFixtures_fail.swift
```

(`scripts/lint.sh` materializes the per-checkout baseline from
`lint/baseline.template.json` before linting — see DESIGN.md §16.)

Expected output: violations only in `LintFixtures_fail.swift`, one per
`// FAIL` comment (count them: `grep -c '// FAIL' lint-fixtures/LintFixtures_fail.swift.txt`),
and none in `LintFixtures_pass.swift` or any other file (scaffold debt is
absorbed by the baseline materialized from `lint/baseline.template.json`).

Run this after editing any custom-rule regex or bumping the pinned
SwiftLint version.
