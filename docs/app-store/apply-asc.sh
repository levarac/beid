#!/usr/bin/env bash
# Writes the drafted App Store listing to App Store Connect, one field per command.
#
# Every text value is read from the JSON files next to this script, so the PR that
# changes a text is the only place that text lives. Nothing here submits for review,
# attaches a build, or touches pricing and availability.
#
#   docs/app-store/apply-asc.sh --dry-run   # print each command and the value length
#   docs/app-store/apply-asc.sh             # write, then re-run validate
#
# Copyright is deliberately absent: its holder name is a legal declaration that the
# owner has not confirmed yet. Review details are absent because the contact name,
# email and phone are not ours to invent.
set -euo pipefail

PROFILE=KENICHINAOE
APP_ID=6789376188
VERSION_ID=60fb87fc-084a-4fb7-b0e1-f7217902c212
LOCALE=en-US

here="$(cd "$(dirname "$0")" && pwd)"
app_info="$here/app-info/$LOCALE.json"
version="$here/version/1.0/$LOCALE.json"

dry_run=0
if [ "${1:-}" = "--dry-run" ]; then
  dry_run=1
fi

field() {
  # A missing or empty field is an error, not a silent no-op write.
  local value
  value="$(jq -er --arg k "$2" '.[$k] | select(type == "string" and length > 0)' "$1")" || {
    echo "missing or empty field '$2' in $1" >&2
    exit 1
  }
  printf '%s' "$value"
}

step=0
run() {
  step=$((step + 1))
  local label="$1"
  shift
  if [ "$dry_run" -eq 1 ]; then
    echo "[$step] $label"
    return
  fi
  echo "[$step] $label" >&2
  asc --profile "$PROFILE" "$@" --output json > /dev/null
}

subtitle="$(field "$app_info" subtitle)"
description="$(field "$version" description)"
keywords="$(field "$version" keywords)"
promotional_text="$(field "$version" promotionalText)"
whats_new="$(field "$version" whatsNew)"

run "subtitle (${#subtitle} chars)" \
  localizations update --type app-info --app "$APP_ID" --locale "$LOCALE" \
  --subtitle "$subtitle"

run "description (${#description} chars)" \
  localizations update --version "$VERSION_ID" --locale "$LOCALE" \
  --description "$description"

run "keywords (${#keywords} chars)" \
  localizations update --version "$VERSION_ID" --locale "$LOCALE" \
  --keywords "$keywords"

run "promotional text (${#promotional_text} chars)" \
  localizations update --version "$VERSION_ID" --locale "$LOCALE" \
  --promotional-text "$promotional_text"

run "what's new (${#whats_new} chars)" \
  localizations update --version "$VERSION_ID" --locale "$LOCALE" \
  --whats-new "$whats_new"

# One declaration, so one write. Every answer is explicit rather than --all-none,
# so each value can be traced to its row in age-rating.md.
run "age rating (24 answers)" \
  age-rating edit --app "$APP_ID" \
  --advertising false \
  --age-assurance false \
  --alcohol-tobacco-drug-use NONE \
  --contests NONE \
  --gambling false \
  --gambling-simulated NONE \
  --guns-or-other-weapons NONE \
  --health-or-wellness-topics false \
  --horror-fear NONE \
  --loot-box false \
  --mature-suggestive NONE \
  --medical-treatment NONE \
  --messaging-and-chat false \
  --parental-controls false \
  --profanity-humor NONE \
  --sexual-content-graphic-nudity NONE \
  --sexual-content-nudity NONE \
  --social-media false \
  --social-media-age-restricted false \
  --unrestricted-web-access false \
  --user-generated-content false \
  --violence-cartoon NONE \
  --violence-realistic NONE \
  --violence-realistic-graphic NONE

if [ "$dry_run" -eq 1 ]; then
  exit 0
fi

asc --profile "$PROFILE" validate --app "$APP_ID" --version-id "$VERSION_ID" \
  --platform IOS --output json |
  jq -c '{errors: .summary.errors, blocking: .summary.blocking, warnings: .summary.warnings}'
