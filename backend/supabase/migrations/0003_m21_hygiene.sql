-- ============================================================
-- Soundpost M21 — delivery hygiene: the poller stops retrying forever, and old
-- rows expire. Date: 2026-11-08. docs/M21-DEVPLAN.md §4F.
--
-- SQL only: no Edge Function changes, so applying this file is the whole deploy.
-- Touches only `public.notification_jobs` and one cron job of its own,
-- `m21_delivery_hygiene`. This project is shared with other apps; nothing here
-- reads or writes anything else.
--
-- Two rules, run nightly by `public.m21_delivery_hygiene()`:
--
--   1. A job that has waited for a device token for a week past its fire instant
--      ends. Until now a due job whose user had no token (`no_tokens`) was
--      deferred an hour at a time, without burning an attempt, forever
--      (`mark_job_deferred`, 0001). It becomes `failed` with
--      `last_error = 'no_tokens_expired'` — but only while that user still has no
--      token at all, and never while a poller run holds the row. The person still
--      sees the capsule resurface the next time they open the app; only the push
--      is given up.
--   2. `sent` and `failed` rows untouched for 90 days are deleted. Nothing reads
--      them: a sent job is never re-armed except by an upsert with a new fire
--      instant, which inserts again if the row is gone.
--
-- The fire instant is computed with the same throw-proof guard `is_job_due` uses:
-- a malformed `time_zone` must not abort the batch (it reads as "not past", so
-- such a row is simply left alone).
--
-- Idempotent: safe to re-run.
-- ============================================================

-- The fire instant of a job, or null when its zone cannot be read.
create or replace function public.m21_job_fire_instant(
  p_wall_clock timestamp without time zone,
  p_time_zone  text
) returns timestamptz as $$
begin
  return p_wall_clock at time zone p_time_zone;
exception when others then
  return null;
end;
$$ language plpgsql stable set search_path = pg_catalog, public, extensions;

create or replace function public.m21_delivery_hygiene(p_now timestamptz default now())
returns table (expired_no_tokens integer, deleted_old integer) as $$
declare
  v_expired integer;
  v_deleted integer;
begin
  update public.notification_jobs j
     set status     = 'failed',
         last_error = 'no_tokens_expired',
         locked_at  = null,
         updated_at = p_now
   where j.status = 'pending'
     and j.last_error = 'no_tokens'
     and (j.locked_at is null or j.locked_at < p_now - interval '10 minutes')
     and public.m21_job_fire_instant(j.wall_clock, j.time_zone) < p_now - interval '7 days'
     and not exists (select 1 from public.device_tokens t where t.user_key = j.user_key);
  get diagnostics v_expired = row_count;

  delete from public.notification_jobs j
   where j.status in ('sent', 'failed')
     and j.updated_at < p_now - interval '90 days';
  get diagnostics v_deleted = row_count;

  return query select v_expired, v_deleted;
end;
$$ language plpgsql security definer set search_path = pg_catalog, public, extensions;

revoke all on function public.m21_job_fire_instant(timestamp, text) from public, anon, authenticated;
revoke all on function public.m21_delivery_hygiene(timestamptz) from public, anon, authenticated;

-- Nightly at 03:17 UTC. Idempotent: unschedule any prior copy first (as 0002).
do $$
begin
  perform cron.unschedule('m21_delivery_hygiene');
exception when others then null;
end $$;

select cron.schedule(
  'm21_delivery_hygiene',
  '17 3 * * *',
  $cron$select public.m21_delivery_hygiene()$cron$
);
