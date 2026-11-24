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
python3 scripts/check_lint_fixtures.py
```

The existing **SwiftLint** CI job runs this same command after application
lint, using the pinned SwiftLint binary and its Xcode toolchain. Locally,
set `DEVELOPER_DIR` as described in `ios/README.md` if necessary.

The checker copies both fixtures under `ios/Beid`, runs
`scripts/lint.sh --reporter json`, and removes its copies even on failure.
It refuses to overwrite existing files. `scripts/lint.sh` materializes the
per-checkout baseline from `lint/baseline.template.json` before linting.

**SwiftLint exit 2 is the expected success condition for the fail fixture.**
Exit 0 means the rules did not prove their expected violations and fails the
checker. Other exit codes and malformed reports also fail it. The checker
itself exits 0 only after verifying all expected violations.

Violations must come only from `LintFixtures_fail.swift`: one for each
`// FAIL <rule>` marker, with the exact line and rule, without duplicates.
The pass fixture and all application files must be clean. Matching only the
total count cannot hide a missing violation behind an unrelated false positive.

Run this after editing any custom-rule regex or bumping the pinned
SwiftLint version.
