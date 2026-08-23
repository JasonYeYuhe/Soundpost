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
# Auth: a saved cktool management token. One is already saved on this machine — if
# you see `authorization-failed`, suspect the TEAM ID before the token. A wrong team
# reports identically to a missing token, which cost a wrong diagnosis once already.
#   xcrun cktool save-token <token> --type management
#   (CloudKit Console -> Settings -> Tokens -> CloudKit Management Tokens)
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Read both from source. The first draft of this script hard-coded the team as
# M3B2SV6M8B, copied from an M9 checklist line that is describing the **App ID
# resource**, not the team — the real team is DEVELOPMENT_TEAM in the project, and
# the mistake only surfaces as an opaque auth failure against the wrong account.
TEAM_ID="${CK_TEAM_ID:-$(sed -n 's/.*DEVELOPMENT_TEAM = \([A-Z0-9]*\);.*/\1/p' \
  "$PROJECT_DIR/Soundpost.xcodeproj/project.pbxproj" | head -1)}"
CONTAINER="${CK_CONTAINER:-$(sed -n 's@.*<string>\(iCloud\.[^<]*\)</string>.*@\1@p' \
  "$PROJECT_DIR/Soundpost/Soundpost.entitlements" | head -1)}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

die() { printf '\033[31m✗ %s\033[0m\n' "$1" >&2; exit 1; }
note() { printf '  %s\n' "$1"; }
ok() { printf '\033[32m✓ %s\033[0m\n' "$1"; }

# The record types the app's schema implies: every @Model in the production Schema([...]),
# prefixed CD_ the way NSPersistentCloudKitContainer names them. Derived from source
# rather than hard-coded, so adding an entity cannot silently escape this check.
expected_types() {
  # Match `Schema([...])` wherever it appears, not `let schema = Schema([...])`.
  # The first version pinned the assignment form and broke the day that declaration
  # became a computed property — leaving this script extracting an EMPTY list and
  # therefore checking nothing, which is the precise failure it exists to prevent.
  sed -n 's/.*Schema(\[\([^]]*\)\]).*/\1/p' \
    "$PROJECT_DIR/Soundpost/Services/SoundpostModelContainer.swift" \
    | head -1 | tr ',' '\n' | sed 's/\.self//g; s/[[:space:]]//g' | grep -v '^$' | sed 's/^/CD_/' || true

  # Plus every record type the app builds by hand with CloudKit's own API. These
  # carry no `CD_` prefix because `NSPersistentCloudKitContainer` never sees them,
  # and deriving the expectation only from `Schema([...])` made them invisible to
  # this check — which is how `DeliveryIdentity` sat in Development but not
  # Production while this script reported everything present. Cloud-backed
  # far-future delivery was inert in every shipped build for months: no App Store
  # user could write the record, so no device token and no seal job ever reached
  # the server, and the app read the failure as "signed out" and fell back to the
  # local path without a word. A gate that only checks the types it happens to know
  # about is the same silence this project keeps re-learning.
  grep -rho 'recordType[[:space:]]*=[[:space:]]*"[^"]*"' \
    "$PROJECT_DIR/Soundpost" --include='*.swift' 2>/dev/null \
    | sed 's/.*"\(.*\)"/\1/' | sort -u || true
}

# Never let an empty expectation read as "nothing is missing".
require_expected_types() {
  if [ -z "$(expected_types)" ]; then
    die "Could not read Schema([...]) from SoundpostModelContainer.swift.
    Refusing to report on a schema this script cannot see — an empty expectation
    would pass every check while verifying nothing."
  fi
}

fetch() { # fetch <environment> <outfile>
  xcrun cktool export-schema \
    --team-id "$TEAM_ID" --container-id "$CONTAINER" --environment "$1" \
    > "$2" 2>"$WORK/err.$1" || {
      if grep -q 'authorization-failed' "$WORK/err.$1"; then
        # This message used to say "make a management token", which is the wrong
        # first guess: a saved token was already present and the real cause was a
        # WRONG TEAM ID (M3B2SV6M8B, an App ID resource, copied out of an M9
        # checklist line). Same opaque error either way, so name both causes and
        # print what we actually used.
        die "cktool refused: team=$TEAM_ID container=$CONTAINER.
    Check the team id first — it must be DEVELOPMENT_TEAM from the project, not the
    App ID resource identifier; a wrong team reports as an authorization failure.
    If the team is right, the saved token is missing or expired:
      xcrun cktool save-token <token> --type management
    (CloudKit Console -> Settings -> Tokens -> CloudKit Management Tokens)"
      fi
      sed 's/^/    /' "$WORK/err.$1" >&2
      die "could not export the $1 schema"
    }
}

# `|| true`: grep exits 1 when a schema has none of these, and under `set -e` that
# killed the script mid-report with no message — it looked like an auth problem.
types_in() { grep -oE 'RECORD TYPE [A-Za-z0-9_]+' "$1" 2>/dev/null | awk '{print $3}' | sort -u || true; }

cmd_status() {
  require_expected_types
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
  require_expected_types
  fetch development "$WORK/dev.ckdb"
  fetch production  "$WORK/prod.ckdb"

  # Which expected types Development cannot supply yet.
  local absent=""
  while read -r t; do
    [ -z "$t" ] && continue
    types_in "$WORK/dev.ckdb" | grep -qx "$t" || absent="$absent$t"$'\n'
  done < <(expected_types)

  # Refusing by default is right: promoting while an expected type is missing from
  # Development is how you come to believe a feature shipped when it cannot work.
  #
  # But refusing *unconditionally* couples unrelated repairs to whichever type is
  # furthest behind, and that had a real cost. `DeliveryIdentity` sat ready in
  # Development for months while this gate declined to act because a different,
  # newer type was absent — so cloud-backed far-future delivery stayed broken for
  # every live user, waiting on a release it has nothing to do with. Promotion is
  # additive: carrying a ready type across cannot harm a type that is not there.
  #
  # So it is still refused, and now it is refusable *knowingly*.
  if [ -n "$absent" ]; then
    printf '\033[33m! Not in Development, so NOT included in this promotion:\033[0m\n'
    printf '%s' "$absent" | sed 's/^/  - /'
    echo
    if [ "${CK_ALLOW_PARTIAL:-}" != "yes" ]; then
      die "Refusing a partial promotion by default.
    To promote only what Development already has, re-run with CK_ALLOW_PARTIAL=yes.
    To include the types above, run the app on an iCloud-signed-in device or
    simulator with -initializeCloudKitSchema, then re-run \`$0 status\`."
    fi
    printf '\033[33m  CK_ALLOW_PARTIAL=yes — proceeding without them.\033[0m\n\n'
  fi

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

  # Verify what this run was actually able to promote — the types Development held.
  # Checking the full expectation here would report a *successful* partial promotion
  # as a failure, which is the worst way to be wrong: it reads as "the import broke"
  # when the import worked and the remaining type was never in scope.
  fetch production "$WORK/prod-after.ckdb"
  while read -r t; do
    [ -z "$t" ] && continue
    types_in "$WORK/dev.ckdb" | grep -qx "$t" || continue
    types_in "$WORK/prod-after.ckdb" | grep -qx "$t" || die "$t still missing from Production after import"
  done < <(expected_types)

  if [ -n "$absent" ]; then
    ok "Production now has everything Development could supply."
    printf '\033[33m! Still missing (never in Development):\033[0m\n'
    printf '%s' "$absent" | sed 's/^/  - /'
    printf '\033[33m  The features that need them still do not work. Re-run status after seeding.\033[0m\n'
  else
    ok "Production now has every record type the app's schema implies."
  fi
}

# Offline check, safe for CI: every entity the app ships must have a seed row, or its
# record type can never be created and the feature that needs it will fail the way all
# the others did — silently, in Production only.
#
# `status` and `promote` both need a CloudKit management token and the network, so CI
# cannot run them; this needs neither. It catches the drift at the moment it is
# introduced rather than whenever somebody next runs the seed by hand.
cmd_check_seed() {
  require_expected_types
  local seed="$PROJECT_DIR/Soundpost/CloudKitSchemaSeed.swift"
  [ -f "$seed" ] || die "CloudKitSchemaSeed.swift not found — this check cannot verify anything."

  local missing=""
  while read -r t; do
    [ -z "$t" ] && continue
    case "$t" in CD_*) ;; *) continue ;; esac      # hand-rolled types are not seeded here
    local entity="${t#CD_}"
    [ "$entity" = "Capsule" ] && continue          # deliberately excluded; see the seed's doc
    grep -q "case \"$entity\"" "$seed" || missing="$missing$entity"$'\n'
  done < <(expected_types)

  if [ -n "$missing" ]; then
    printf '\033[31m✗ Entities in the shipping schema with no seed row:\033[0m\n' >&2
    printf '%s' "$missing" | sed 's/^/  - /' >&2
    die "Add a case to CloudKitSchemaSeed.seedRow(for:) for each.
    Without one, its CD_ record type is never created in CloudKit Development, so it
    can never be promoted, and the feature silently does not sync in Production."
  fi
  ok "Seed covers every entity in the shipping schema."
}

case "${1:-status}" in
  status)      cmd_status ;;
  promote)     cmd_promote ;;
  check-seed)  cmd_check_seed ;;
  *) die "usage: $0 [status|promote|check-seed]" ;;
esac
