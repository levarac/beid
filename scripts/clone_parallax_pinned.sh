#!/usr/bin/env bash
# Clone levarac/parallax at the commit this repository pins, so the vendored-resource
# byte comparison in ParallaxEventDefinitionSourceChecksumTest has something to compare
# against on every CI run instead of only when a developer remembers to point
# PARALLAX_REPO somewhere (beid#415).
#
# The pinned commit is read out of the Kotlin test that owns it rather than restated
# here. A second copy of the ref in YAML would be a second source of truth, and the
# whole point of the pin is that there is exactly one.
#
# Prints the checkout path on stdout, and exports PARALLAX_REPO through GITHUB_ENV when
# running under GitHub Actions so later steps inherit it.
#
# With no PARALLAX_READ_TOKEN this exits 0 WITHOUT setting PARALLAX_REPO, and says so
# loudly. Setting PARALLAX_REPO to a path that is not there would be a misconfiguration
# and the test fails loudly on it by design (beid#403 / PR #412); an unset variable is
# the only thing that legitimately skips. Do not "helpfully" export an empty value.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REF_SOURCE="$REPO_ROOT/shared/src/androidHostTest/kotlin/org/levarac/parallax/registry/ParallaxEventDefinitionSourceChecksumTest.kt"
PARALLAX_REMOTE="https://github.com/levarac/parallax.git"

usage() {
    cat >&2 <<'USAGE'
usage: clone_parallax_pinned.sh [--print-ref] [--print-source] [--source PATH]

  --print-ref     print the pinned Parallax commit and exit; clone nothing
  --print-source  print the path this script reads the pinned commit from, and exit
  --source PATH   read the pinned commit from PATH instead of the default test source
                  (for tests; the workflow always uses the default)
USAGE
}

# Fail closed. A ref we cannot read unambiguously must stop the run, not fall back to a
# branch tip: comparing against a moving target is the failure this pin exists to avoid.
expected_ref() {
    local source="$1" matches count
    if [ ! -f "$source" ]; then
        printf 'clone_parallax_pinned: no such ref source: %s\n' "$source" >&2
        return 1
    fi
    matches="$(grep -Eo 'EXPECTED_PARALLAX_REF[[:space:]]*=[[:space:]]*"[0-9a-f]{40}"' "$source" \
        | grep -Eo '[0-9a-f]{40}' || true)"
    count="$(printf '%s\n' "$matches" | grep -c . || true)"
    if [ "$count" -ne 1 ]; then
        printf 'clone_parallax_pinned: expected exactly one EXPECTED_PARALLAX_REF 40-hex commit in %s, found %s\n' \
            "$source" "$count" >&2
        return 1
    fi
    printf '%s\n' "$matches"
}

print_ref_only=0
print_source_only=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --print-ref) print_ref_only=1; shift ;;
        # Exists so the single-source check can locate the canonical file without
        # naming it. A checker that hardcoded the path would itself become the
        # second source of truth it is meant to forbid (beid#478).
        --print-source) print_source_only=1; shift ;;
        --source) REF_SOURCE="${2:?--source needs a path}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) printf 'clone_parallax_pinned: unknown argument: %s\n' "$1" >&2; usage; exit 2 ;;
    esac
done

if [ "$print_source_only" -eq 1 ]; then
    printf '%s\n' "$REF_SOURCE"
    exit 0
fi

ref="$(expected_ref "$REF_SOURCE")"

if [ "$print_ref_only" -eq 1 ]; then
    printf '%s\n' "$ref"
    exit 0
fi

if [ -z "${PARALLAX_READ_TOKEN:-}" ]; then
    reason="PARALLAX_READ_TOKEN is not set, so levarac/parallax was not cloned. The vendored-resource byte comparison against Parallax ${ref} did NOT run on this job; vendored drift is unchecked here. This is not a green result for that guard."
    printf '::warning title=Parallax comparison skipped::%s\n' "$reason"
    printf '%s\n' \
        '====================================================================' \
        '  PARALLAX COMPARISON SKIPPED - vendored drift is NOT checked here' \
        '====================================================================' \
        "$reason" >&2
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
        printf '### Parallax comparison skipped\n\n%s\n' "$reason" >> "$GITHUB_STEP_SUMMARY"
    fi
    exit 0
fi

dest="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/parallax-pinned"
rm -rf "$dest"
mkdir -p "$dest"

git -C "$dest" init -q
# Credentials go in the remote URL because Actions masks the secret wherever it appears
# in a log; the URL is replaced with the clean one immediately after fetching so nothing
# downstream can read it back out of .git/config.
git -C "$dest" remote add origin "https://x-access-token:${PARALLAX_READ_TOKEN}@github.com/levarac/parallax.git"
git -C "$dest" fetch -q --depth 1 origin "$ref"
git -C "$dest" checkout -q --detach FETCH_HEAD
git -C "$dest" remote set-url origin "$PARALLAX_REMOTE"

# Detached at the pinned commit, not at a tracking branch tip. The test asserts this too,
# but a clone that landed somewhere else should say so here rather than surface as a
# confusing comparison failure later.
actual="$(git -C "$dest" rev-parse --verify HEAD)"
if [ "$actual" != "$ref" ]; then
    printf 'clone_parallax_pinned: expected HEAD at %s, got %s in %s\n' "$ref" "$actual" "$dest" >&2
    exit 1
fi
branch="$(git -C "$dest" rev-parse --abbrev-ref HEAD)"
if [ "$branch" != "HEAD" ]; then
    printf 'clone_parallax_pinned: expected a detached HEAD, got branch %s in %s\n' "$branch" "$dest" >&2
    exit 1
fi

printf 'Parallax pinned checkout ready: %s at %s (detached)\n' "$dest" "$ref" >&2
if [ -n "${GITHUB_ENV:-}" ]; then
    printf 'PARALLAX_REPO=%s\n' "$dest" >> "$GITHUB_ENV"
fi
printf '%s\n' "$dest"
