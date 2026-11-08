-- ============================================================
-- Test for 0003_m21_hygiene.sql (docs/M21-DEVPLAN.md §4F).
--
-- Run against a LOCAL database that already has 0001 and 0003 applied — never
-- against Production. `backend/supabase/tests/run-local.sh` builds a throwaway
-- Postgres cluster for it (no Docker needed); against `supabase start` it runs as is.
-- Every assertion raises on failure, so psql -v ON_ERROR_STOP=1 exits non-zero.
-- ============================================================

-- Refuse a database that holds real rows, before anything else runs: this file empties
-- both tables (inside a transaction it rolls back, but a client that sends the file as
-- one query and stops at the first error would leave that transaction open, holding
-- locks the poller needs). A fresh local database has none.
do $$
begin
  if exists (select 1 from public.notification_jobs) or exists (select 1 from public.device_tokens) then
    raise exception 'refusing to run: notification_jobs or device_tokens already has rows — run this only against a fresh local database';
  end if;
end $$;

begin;

truncate public.notification_jobs, public.device_tokens;

-- Seeded relative to a fixed "now" so the boundaries are exact.
create temp table t_now as select timestamptz '2026-11-08 12:00:00+00' as now;

-- Keys are ≥16 characters, as the app's are.
insert into public.device_tokens (token, user_key, environment)
values ('token-has-a-device', 'user-with-a-token-0001', 'production');

insert into public.notification_jobs
  (capsule_id, user_key, wall_clock, time_zone, status, last_error, locked_at, updated_at)
select c.capsule_id, c.user_key, c.wall_clock, c.time_zone, c.status, c.last_error, c.locked_at, c.updated_at
from t_now, lateral (values
  -- 1. waited for a token 8 days past its instant, still none → expires
  ('expired',        'user-without-tokens-01', timestamp '2026-10-31 09:00', 'Asia/Tokyo',   'pending', 'no_tokens', null::timestamptz, now - interval '1 hour'),
  -- 2. only 6 days past → keeps retrying
  ('six-days',       'user-without-tokens-01', timestamp '2026-11-02 12:00', 'UTC',          'pending', 'no_tokens', null, now - interval '1 hour'),
  -- 3. 8 days past, but the user now has a token → the poller will send it
  ('has-token',      'user-with-a-token-0001', timestamp '2026-10-31 09:00', 'Asia/Tokyo',   'pending', 'no_tokens', null, now - interval '1 hour'),
  -- 4. 8 days past, held by a running poller → left alone
  ('locked',         'user-without-tokens-01', timestamp '2026-10-31 09:00', 'Asia/Tokyo',   'pending', 'no_tokens', now - interval '1 minute', now - interval '1 hour'),
  -- 5. a zone that cannot be read → left alone, and the batch is not aborted
  ('bad-zone',       'user-without-tokens-01', timestamp '2026-01-01 09:00', 'Not/AZone',    'pending', 'no_tokens', null, now - interval '1 hour'),
  -- 6. 8 days past but never deferred for want of a token → not this rule's
  ('other-error',    'user-without-tokens-01', timestamp '2026-10-31 09:00', 'Asia/Tokyo',   'pending', 'apns_500',  null, now - interval '1 hour'),
  -- 7. exactly 7 days past (not more) → keeps retrying
  ('seven-days',     'user-without-tokens-01', timestamp '2026-11-01 12:00', 'UTC',          'pending', 'no_tokens', null, now - interval '1 hour'),
  -- 8. sent 91 days ago → deleted
  ('sent-old',       'user-with-a-token-0001', timestamp '2026-08-01 09:00', 'UTC',          'sent',    null,        null, now - interval '91 days'),
  -- 9. sent 89 days ago → kept
  ('sent-recent',    'user-with-a-token-0001', timestamp '2026-08-10 09:00', 'UTC',          'sent',    null,        null, now - interval '89 days'),
  -- 10. failed 91 days ago → deleted
  ('failed-old',     'user-with-a-token-0001', timestamp '2026-08-01 09:00', 'UTC',          'failed',  'apns_410',  null, now - interval '91 days'),
  -- 11. pending, untouched for 200 days, due in 2030 → never deleted
  ('pending-far',    'user-with-a-token-0001', timestamp '2030-01-01 09:00', 'UTC',          'pending', null,        null, now - interval '200 days')
) as c(capsule_id, user_key, wall_clock, time_zone, status, last_error, locked_at, updated_at);

create temp table t_result as
select * from public.m21_delivery_hygiene((select now from t_now));

do $$
declare
  r record;
  n integer;
begin
  select * into r from t_result;
  if r.expired_no_tokens <> 1 then raise exception 'expired % rows, expected 1', r.expired_no_tokens; end if;
  if r.deleted_old <> 2 then raise exception 'deleted % rows, expected 2', r.deleted_old; end if;

  select count(*) into n from public.notification_jobs
   where capsule_id = 'expired' and status = 'failed' and last_error = 'no_tokens_expired' and locked_at is null;
  if n <> 1 then raise exception 'the 8-day no_tokens job did not settle as failed/no_tokens_expired'; end if;

  for r in select capsule_id from public.notification_jobs
            where capsule_id in ('six-days', 'has-token', 'locked', 'bad-zone', 'other-error', 'seven-days', 'pending-far')
              and status <> 'pending' loop
    raise exception 'job % should still be pending', r.capsule_id;
  end loop;

  select count(*) into n from public.notification_jobs
   where capsule_id in ('six-days', 'has-token', 'locked', 'bad-zone', 'other-error', 'seven-days', 'pending-far', 'sent-recent', 'expired');
  if n <> 9 then raise exception 'a row that should be kept was deleted (% of 9 left)', n; end if;

  select count(*) into n from public.notification_jobs where capsule_id in ('sent-old', 'failed-old');
  if n <> 0 then raise exception 'old sent/failed rows were not deleted'; end if;

  select count(*) into n from public.device_tokens;
  if n <> 1 then raise exception 'the hygiene touched device_tokens'; end if;
end $$;

-- Idempotent: a second run on the same instant changes nothing.
do $$
declare r record;
begin
  select * into r from public.m21_delivery_hygiene(timestamptz '2026-11-08 12:00:00+00');
  if r.expired_no_tokens <> 0 or r.deleted_old <> 0 then
    raise exception 'a second run changed % / % rows', r.expired_no_tokens, r.deleted_old;
  end if;
end $$;

-- 90 days after the expiry, the expired row itself is cleaned up.
do $$
declare r record;
begin
  select * into r from public.m21_delivery_hygiene(timestamptz '2026-11-08 12:00:00+00' + interval '91 days');
  if exists (select 1 from public.notification_jobs where capsule_id = 'expired') then
    raise exception 'the expired row outlived 90 days';
  end if;
end $$;

-- The cron job is scheduled once, under its own name.
do $$
declare n integer;
begin
  select count(*) into n from cron.job where jobname = 'm21_delivery_hygiene';
  if n <> 1 then raise exception 'm21_delivery_hygiene is scheduled % times', n; end if;
end $$;

-- Only the service role and the owner may call it.
do $$
begin
  if has_function_privilege('anon', 'public.m21_delivery_hygiene(timestamptz)', 'execute')
     or has_function_privilege('authenticated', 'public.m21_delivery_hygiene(timestamptz)', 'execute') then
    raise exception 'anon/authenticated can run the hygiene';
  end if;
end $$;

rollback;

select 'ALL PASS' as result;
