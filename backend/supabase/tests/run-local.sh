#!/bin/bash
# Run the delivery-server SQL tests against a THROWAWAY local Postgres cluster —
# never against Production (docs/M21-DEVPLAN.md §4F). Needs only Homebrew's
# postgresql (initdb, pg_ctl, psql); no Docker, no Supabase CLI.
#
# Supabase's own pieces the migrations name — the anon/authenticated/service_role
# roles, the `extensions` and `vault` schemas, and pg_cron's `cron.schedule` — are
# stood in for with the smallest stubs that let 0001 and 0003 apply. 0002 (pg_net,
# the per-minute poller) is not applied: nothing here depends on it.
#
# usage: backend/supabase/tests/run-local.sh
set -euo pipefail
# The postmaster refuses to start on macOS without a valid locale in the environment
# ("postmaster became multithreaded during startup").
export LC_ALL=C

here="$(cd "$(dirname "$0")" && pwd)"
migrations="$here/../migrations"
for tool in initdb pg_ctl psql; do
  command -v "$tool" >/dev/null || { echo "run-local.sh: $tool not found (brew install postgresql@17)" >&2; exit 2; }
done

# The throwaway cluster (~40 MB) lives in $TMPDIR, which macOS empties on its own; the
# script stops the server and deletes nothing.
work="$(mktemp -d "${TMPDIR:-/tmp}/soundpost-sqltest.XXXXXX")"
port=$(( 55000 + RANDOM % 5000 ))
cleanup() {
  pg_ctl -D "$work/data" stop -m fast >/dev/null 2>&1 || true
}
trap cleanup EXIT

initdb -D "$work/data" -U postgres --auth=trust >/dev/null
# TCP on loopback only, no Unix socket: a socket path under a long $TMPDIR can
# exceed the 103-byte limit.
if ! pg_ctl -D "$work/data" -o "-p $port -c listen_addresses=127.0.0.1 -c unix_socket_directories=''" \
       -l "$work/pg.log" -w start >/dev/null; then
  cat "$work/pg.log" >&2
  exit 1
fi
db() { psql -X -q -v ON_ERROR_STOP=1 -h 127.0.0.1 -p "$port" -U postgres -d postgres "$@"; }

db <<'SQL'
create role anon nologin;
create role authenticated nologin;
create role service_role nologin;
create schema extensions;
create schema vault;
create view vault.decrypted_secrets as select null::text as name, null::text as decrypted_secret where false;
create schema cron;
create table cron.job (jobid bigserial primary key, jobname text unique, schedule text, command text);
create function cron.schedule(job_name text, schedule text, command text) returns bigint as $$
  insert into cron.job (jobname, schedule, command) values (job_name, schedule, command)
  on conflict (jobname) do update set schedule = excluded.schedule, command = excluded.command
  returning jobid;
$$ language sql;
create function cron.unschedule(job_name text) returns boolean as $$
begin
  delete from cron.job where jobname = job_name;
  if not found then raise exception 'could not find valid entry for job ''%''', job_name; end if;
  return true;
end;
$$ language plpgsql;
SQL

db -f "$migrations/0001_m10_delivery.sql"
db -f "$migrations/0003_m21_hygiene.sql"
db -f "$migrations/0003_m21_hygiene.sql"   # idempotent: applying twice must succeed
for test in "$here"/*_test.sql; do
  echo "== $(basename "$test")"
  db -f "$test"
done
