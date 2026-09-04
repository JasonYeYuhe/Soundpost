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

# The entity names in the production `Schema([...])`, from source.
#
# Match `Schema([...])` wherever it appears, not `let schema = Schema([...])`. The
# first version pinned the assignment form and broke the day that declaration became
# a computed property — leaving this script extracting an EMPTY list and therefore
# checking nothing, which is the precise failure it exists to prevent.
schema_entities() {
  sed -n 's/.*Schema(\[\([^]]*\)\]).*/\1/p' \
    "$PROJECT_DIR/Soundpost/Services/SoundpostModelContainer.swift" \
    | head -1 | tr ',' '\n' | sed 's/\.self//g; s/[[:space:]]//g' | grep -v '^$' || true
}

# Every `@Model` class the app DECLARES, wherever it lives.
#
# This is the one list here that is not derived from `Schema([...])`, and that is the
# whole point (M18 §4H). Everything else in this file — the expectation below, the
# seed check, the container, the schema test — reads that array, so a `@Model` left
# out of it is invisible to all of them at once and the feature it belongs to simply
# does not sync, in Production only. A check that iterates an artefact cannot fail
# for what is missing from the artefact.
#
# `^@Model$` anchored, so `@ModelActor` and a `@Model` mentioned in a doc comment are
# not matched; the class name is taken from the next declaration line.
declared_models() {
  grep -rh -A3 '^@Model[[:space:]]*$' "$PROJECT_DIR/Soundpost" --include='*.swift' 2>/dev/null \
    | sed -n 's/^\(final \)\{0,1\}class \([A-Za-z_][A-Za-z0-9_]*\).*/\2/p' | sort -u || true
}

# The record types the app's schema implies: every @Model in the production Schema([...]),
# prefixed CD_ the way NSPersistentCloudKitContainer names them. Derived from source
# rather than hard-coded, so adding an entity cannot silently escape this check.
expected_types() {
  schema_entities | sed 's/^/CD_/'

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

  # ── There is no cktool path from Development to Production. ──────────────────
  #
  # Measured 2026-08-28, the first time this command was ever run to completion:
  #
  #     --environment production --validate  ->  Operation: validate
  #     --environment production             ->  Operation: schema
  #     both: BadRequestException: endpoint not applicable in the environment
  #           'production'
  #
  # `cktool import-schema` writes Development only, and `cktool` offers no deploy or
  # promote subcommand at all (`reset-schema` runs the other way: Production ->
  # Development). Apple exposes the Development -> Production deploy **only** in the
  # CloudKit Console web UI.
  #
  # So this script had never once promoted anything. It was written, it was never
  # exercised against Production, and its failure mode stayed invisible until the day
  # it was needed — which is the exact shape this file was created to catch, in the
  # file itself. The header's own note that "M9 did the promotion by hand for
  # CD_Capsule" is the corroboration nobody read as one.
  #
  # What survives, and is worth keeping, is everything above this line: the drift
  # report, the field-level preview, and the refusal to proceed on a partial set.
  # Those are the parts that tell a human what they are about to deploy.
  echo
  printf '\033[33mThis last step is not automatable — deploy it in the CloudKit Console:\033[0m\n'
  echo
  echo "  1. https://icloud.developer.apple.com/dashboard/"
  echo "  2. Container: $CONTAINER"
  echo "  3. Schema -> Deploy Schema Changes…"
  echo "  4. Confirm the two record types above, and only those, then Deploy."
  echo
  echo "Then verify from here — it reads Production back, it does not trust the click:"
  echo "  $0 status"
  echo
  die "nothing was deployed by this run; see the steps above"

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

# Offline check, safe for CI: every `@Model` the app declares must be in the shipping
# `Schema([...])`.
#
# The trap this closes was already set, in the exact file M18 had to edit, and two
# reviewers found it independently. Add `@Model final class SoundRejection` and forget
# the schema line, and FOUR gates stay green at once: the container never mirrors it,
# so CloudKit never creates the record type; `expected_types()` above is derived from
# that same array, so it compares only what is listed; `CloudKitSchemaSeed` iterates
# `container.schema.entities`, so it has nothing to seed; and the schema unit test
# asserted membership of two known names, which a third entity cannot fail.
#
# So this reads the SOURCE rather than the schema. `ModelRegistrationTests` asks the
# same question of the built binary via the Objective-C runtime. Two checks over two
# different artefacts, deliberately: the answer to "a list nobody updated" must not
# itself be a list somebody has to update.
cmd_check_models() {
  require_expected_types
  local declared registered missing=""
  declared="$(declared_models)"
  registered="$(schema_entities)"

  # Never let an empty scan read as "nothing is missing" — the same refusal
  # `require_expected_types` makes about the other side of this comparison.
  if [ -z "$declared" ]; then
    die "Found no @Model declarations under Soundpost/ at all.
    Refusing to report on a source tree this script cannot see — an empty scan
    would pass every check while verifying nothing."
  fi

  while read -r m; do
    [ -z "$m" ] && continue
    printf '%s\n' "$registered" | grep -qx "$m" || missing="$missing$m"$'\n'
  done <<< "$declared"

  if [ -n "$missing" ]; then
    printf '\033[31m✗ @Model types the app declares that are NOT in Schema([...]):\033[0m\n' >&2
    printf '%s' "$missing" | sed 's/^/  - /' >&2
    die "Add each to SoundpostModelContainer.productionSchema, and a seed row to
    CloudKitSchemaSeed.seedRow(for:).
    Until then CloudKit never creates its record type, this script's own expectation
    is derived from that array so it cannot notice, and the feature does not sync in
    Production. Nothing throws; nothing reports; it is simply absent."
  fi

  ok "Every @Model the app declares is in the shipping schema ($(printf '%s' "$declared" | tr '\n' ' '))."
}

# ---- check-fields: the checked-in snapshot must still be what the server says ----
#
# `CloudKitFieldCoverageTests` compares the app's declared fields against
# `docs/cloudkit-schema/*.ckdb`, offline, so it runs in CI and in the suite. That is
# only worth anything while those files are what the server actually holds. This is
# what refreshes them and fails if they had drifted.
#
# It exists because of what M19 §4C found. M17 §14D concluded `export-schema` "omits
# unindexed fields" and wrote off every gate built on it. Checked field by field
# against the CloudKit Console's own Development schema on 2026-09-05, the export
# matches exactly — same fields, same index sets. The export is field-complete for
# what the server HOLDS. What no diff between two server environments can see is a
# field the app declares that neither environment has, because CoreData creates a
# Development field only when a record carrying a value for it is first written.
# That is a real case in this container right now: CD_Capsule.CD_serverJobSyncedAt.
cmd_check_fields() {
  local snap="$PROJECT_DIR/docs/cloudkit-schema"
  local drifted=""
  for env in DEVELOPMENT PRODUCTION; do
    fetch "$env" "$WORK/$env.ckdb"
    if [ ! -f "$snap/$env.ckdb" ]; then
      cp "$WORK/$env.ckdb" "$snap/$env.ckdb"
      printf '  wrote a first snapshot for %s\n' "$env"
    elif ! diff -q "$snap/$env.ckdb" "$WORK/$env.ckdb" >/dev/null; then
      printf '\033[31m✗ %s has drifted from the checked-in snapshot:\033[0m\n' "$env" >&2
      # `|| true`: `diff` exits 1 when files differ, and this file runs under
      # `set -o pipefail`, so the pipeline's status is 1 and `set -e` aborts here —
      # after the message and before the refresh below. The first version of this
      # function printed "drifted", promised a refresh, and exited without doing it.
      diff "$snap/$env.ckdb" "$WORK/$env.ckdb" | sed 's/^/    /' >&2 || true
      cp "$WORK/$env.ckdb" "$snap/$env.ckdb"
      drifted="$drifted $env"
    fi
  done
  if [ -n "$drifted" ]; then
    die "Snapshots refreshed for$drifted. Commit them, and read the diff before you do:
    a field appearing in DEVELOPMENT still needs a human deploy in the Console to
    reach PRODUCTION, and CloudKitFieldCoverageTests.knownAbsent may need updating."
  fi
  ok "Both schema snapshots match the server."
}

case "${1:-status}" in
  status)       cmd_status ;;
  promote)      cmd_promote ;;
  check-seed)   cmd_check_seed ;;
  check-models) cmd_check_models ;;
  check-fields) cmd_check_fields ;;
  *) die "usage: $0 [status|promote|check-seed|check-models|check-fields]" ;;
esac
