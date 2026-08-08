#!/bin/bash
# CloudKit schema: see the drift, then promote Development -> Production.
#
# WHY THIS EXISTS. Adding a SwiftData entity creates a new CloudKit record type,
# and `NSPersistentCloudKitContainer` can only auto-create those in **Development**
# — Production is read-only from the client, and Production is what App Store and
# TestFlight builds talk to. So a build can pass every local gate, validate its
# schema locally, stay on the CloudKit rung, and still fail to export the new type
# server-side. Nothing throws. The feature just quietly does not sync.
#
# That is exactly what happened with `CD_ListeningConsent` (M15 §11B-i): the plan
# said "adding an entity is additive, so an existing store migrates lightly", which
# is true of SwiftData's *local* migration and silent about the server. M9 did the
# promotion by hand for `CD_Capsule` and wrote it down; nothing carried that forward,
# because nothing in the release flow could see the difference.
#
# Usage:
#   scripts/cloudkit-schema.sh status     # what is in each environment, and the drift
#   scripts/cloudkit-schema.sh promote    # import Development's schema into Production
#
# Requires a CloudKit **management token**:
#   CloudKit Console -> Settings -> Tokens -> CloudKit Management Tokens -> New Token
#   xcrun cktool save-token <token> --type management
set -euo pipefail

TEAM_ID="${CK_TEAM_ID:-M3B2SV6M8B}"
CONTAINER="${CK_CONTAINER:-iCloud.com.soundpost.Soundpost}"
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

die() { printf '\033[31m✗ %s\033[0m\n' "$1" >&2; exit 1; }
note() { printf '  %s\n' "$1"; }
ok() { printf '\033[32m✓ %s\033[0m\n' "$1"; }

# The record types the app's schema implies: every @Model in the production Schema([...]),
# prefixed CD_ the way NSPersistentCloudKitContainer names them. Derived from source
# rather than hard-coded, so adding an entity cannot silently escape this check.
expected_types() {
  sed -n 's/.*let schema = Schema(\[\(.*\)\]).*/\1/p' \
    "$PROJECT_DIR/Soundpost/Services/SoundpostModelContainer.swift" \
    | tr ',' '\n' | sed 's/\.self//g; s/[[:space:]]//g' | grep -v '^$' | sed 's/^/CD_/'
}

fetch() { # fetch <environment> <outfile>
  xcrun cktool export-schema \
    --team-id "$TEAM_ID" --container-id "$CONTAINER" --environment "$1" \
    > "$2" 2>"$WORK/err.$1" || {
      if grep -q 'authorization-failed' "$WORK/err.$1"; then
        die "cktool is not authorized. Create a CloudKit **management** token in the CloudKit Console (Settings -> Tokens), then: xcrun cktool save-token <token> --type management"
      fi
      sed 's/^/    /' "$WORK/err.$1" >&2
      die "could not export the $1 schema"
    }
}

types_in() { grep -oE '^RECORD TYPE [A-Za-z0-9_]+' "$1" | awk '{print $3}' | sort -u; }

cmd_status() {
  echo "Container: $CONTAINER   Team: $TEAM_ID"
  fetch development "$WORK/dev.ckdb"
  fetch production  "$WORK/prod.ckdb"

  echo; echo "Record types the app's schema implies:"
  expected_types | sed 's/^/  /'

  echo; echo "In Development:"; types_in "$WORK/dev.ckdb" | sed 's/^/  /'
  echo; echo "In Production:";  types_in "$WORK/prod.ckdb" | sed 's/^/  /'

  local missing_dev=0 missing_prod=0
  while read -r t; do
    [ -z "$t" ] && continue
    types_in "$WORK/dev.ckdb"  | grep -qx "$t" || { echo; note "MISSING in Development: $t"; missing_dev=1; }
    types_in "$WORK/prod.ckdb" | grep -qx "$t" || { note "MISSING in Production:  $t"; missing_prod=1; }
  done < <(expected_types)

  echo
  if [ "$missing_dev" = 1 ]; then
    die "A record type does not exist in Development yet. It is created the first time the app WRITES one of those objects while signed into iCloud on a signed build — run the app on a device, touch the feature once, then re-run this. cktool cannot conjure it, and hand-authoring the schema risks a field mismatch that Production can never take back."
  fi
  if [ "$missing_prod" = 1 ]; then
    printf '\033[33m! Production is behind Development — run: %s promote\033[0m\n' "$0"
    exit 2
  fi
  ok "Production has every record type the app's schema implies."
}

cmd_promote() {
  fetch development "$WORK/dev.ckdb"
  fetch production  "$WORK/prod.ckdb"

  while read -r t; do
    [ -z "$t" ] && continue
    types_in "$WORK/dev.ckdb" | grep -qx "$t" \
      || die "$t is not in Development yet — nothing to promote. Run the app on an iCloud-signed-in device and exercise the feature first."
  done < <(expected_types)

  echo "Development -> Production would add:"
  local added
  added="$(comm -23 <(types_in "$WORK/dev.ckdb") <(types_in "$WORK/prod.ckdb") || true)"
  if [ -z "$added" ]; then ok "Nothing to do — Production already matches."; exit 0; fi
  echo "$added" | sed 's/^/  + /'

  echo
  echo "This is IRREVERSIBLE. Record types and fields cannot be removed from"
  echo "Production once deployed, only added to."
  if [ "${CK_CONFIRM:-}" != "yes" ]; then
    die "Refusing to deploy without confirmation. Re-run with: CK_CONFIRM=yes $0 promote"
  fi

  xcrun cktool import-schema \
    --team-id "$TEAM_ID" --container-id "$CONTAINER" \
    --environment production --validate --file "$WORK/dev.ckdb" \
    || die "import into Production failed"

  fetch production "$WORK/prod-after.ckdb"
  while read -r t; do
    [ -z "$t" ] && continue
    types_in "$WORK/prod-after.ckdb" | grep -qx "$t" || die "$t still missing from Production after import"
  done < <(expected_types)
  ok "Production now has every record type the app's schema implies."
}

case "${1:-status}" in
  status)  cmd_status ;;
  promote) cmd_promote ;;
  *) die "usage: $0 [status|promote]" ;;
esac
