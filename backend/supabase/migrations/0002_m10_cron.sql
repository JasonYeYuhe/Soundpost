-- ============================================================
-- Soundpost M10 — pg_cron trigger for the due-time poller. Date: 2026-06-20.
--
-- Apply AFTER enabling pg_cron + pg_net and setting the Vault secrets below.
-- A per-minute job POSTs `send-due-notifications` with a timing-safe shared
-- secret that is DISTINCT from the service-role key (docs/M10-DEVPLAN.md §E/§G).
-- Up-to-60s delivery latency is acceptable for far-future seals.
--
-- Required Vault secrets (Project Settings → Vault, or `select vault.create_secret(...)`):
--   m10_app_url      e.g. https://<project-ref>.functions.supabase.co  (or .../functions/v1 base)
--   m10_cron_secret  a long random string; ALSO set as the CRON_SECRET function env var
--
-- Idempotent: safe to re-run.
-- ============================================================

create extension if not exists pg_cron  with schema pg_catalog;
create extension if not exists pg_net    with schema extensions;

create or replace function public.trigger_send_due_notifications()
returns void as $$
declare
  v_url    text;
  v_secret text;
begin
  select decrypted_secret into v_url
  from vault.decrypted_secrets where name = 'm10_app_url';
  select decrypted_secret into v_secret
  from vault.decrypted_secrets where name = 'm10_cron_secret';

  if v_url is null or v_secret is null or v_url = '' or v_secret = '' then
    raise notice 'trigger_send_due_notifications: vault secrets not set; skipping';
    return;
  end if;

  perform net.http_post(
    url     := rtrim(v_url, '/') || '/send-due-notifications',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || v_secret,
      'X-Internal-Trigger', 'send_due_notifications_cron'
    ),
    body    := '{}'::jsonb,
    timeout_milliseconds := 8000
  );
end;
$$ language plpgsql security definer set search_path = pg_catalog, public, extensions, net, vault;

revoke all on function public.trigger_send_due_notifications() from public, anon, authenticated;

-- Schedule every minute. Idempotent: unschedule any prior copy first.
do $$
begin
  perform cron.unschedule('m10_send_due_notifications');
exception when others then null;
end $$;

select cron.schedule(
  'm10_send_due_notifications',
  '* * * * *',
  $cron$select public.trigger_send_due_notifications()$cron$
);
