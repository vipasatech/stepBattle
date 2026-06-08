-- =============================================================================
-- StepBattle — push delivery for in-app notifications
--
-- WHAT IT DOES:
--   Every row inserted into `public.notifications` (battle results, invites,
--   level-ups, etc.) fires a trigger that POSTs to the `send-push` Edge
--   Function via pg_net, which delivers an FCM push to the recipient's device.
--   `notification`-type FCM messages are shown by the OS even when the app is
--   backgrounded or terminated — this is what actually "wakes the phone".
--
--   This complements migration 0008: the cron resolves battles server-side no
--   matter what; this nudges the user so they reopen the app and a fresh step
--   sync lands.
--
-- PREREQUISITES (one-time, do these BEFORE running this file):
--   1. Deploy the Edge Function (see supabase/functions/send-push/index.ts):
--        supabase secrets set FCM_SERVICE_ACCOUNT="$(cat service-account.json)"
--        supabase secrets set PUSH_WEBHOOK_SECRET="<random-long-string>"
--        supabase functions deploy send-push --no-verify-jwt
--   2. Enable the Vault extension (Dashboard → Database → Extensions →
--      `supabase_vault`) if it isn't already.
--   3. Store the function URL + the SAME secret in Vault so the trigger can
--      reach the function without hard-coding secrets in SQL:
--        select vault.create_secret(
--          'https://<PROJECT_REF>.supabase.co/functions/v1/send-push',
--          'push_function_url');
--        select vault.create_secret('<random-long-string>', 'push_webhook_secret');
--      (Find <PROJECT_REF> in Dashboard → Project Settings → General.)
--
-- HOW TO APPLY:
--   Dashboard → SQL Editor → paste this whole file → Run.
--
-- SAFE TO RE-RUN: extension/function use IF NOT EXISTS / CREATE OR REPLACE and
--   the trigger is dropped before being recreated. (vault.create_secret above
--   is NOT idempotent — only run those two lines once.)
-- =============================================================================

create extension if not exists pg_net;

-- -----------------------------------------------------------------------------
-- notify_push_on_insert() — look up the recipient's device token and hand the
-- notification off to the send-push Edge Function. Fire-and-forget (pg_net
-- queues the request, so the INSERT is never blocked). No-op when the user has
-- no token or push isn't configured yet.
-- -----------------------------------------------------------------------------
create or replace function public.notify_push_on_insert()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_token  text;
  v_url    text;
  v_secret text;
begin
  select fcm_token into v_token from public.profiles where id = new.user_id;
  if v_token is null or v_token = '' then
    return new;
  end if;

  select decrypted_secret into v_url
  from vault.decrypted_secrets where name = 'push_function_url';
  select decrypted_secret into v_secret
  from vault.decrypted_secrets where name = 'push_webhook_secret';
  if v_url is null or v_secret is null then
    return new;  -- push not configured yet
  end if;

  perform net.http_post(
    url := v_url,
    body := jsonb_build_object(
      'token', v_token,
      'title', new.title,
      'body',  new.body,
      'data',  coalesce(new.data, '{}'::jsonb)
                 || jsonb_build_object('type', new.type, 'notification_id', new.id)
    ),
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-webhook-secret', v_secret
    ),
    timeout_milliseconds := 5000
  );

  return new;
exception
  when others then
    -- Never let push failures roll back the notification insert.
    return new;
end;
$$;

drop trigger if exists notifications_push_trigger on public.notifications;
create trigger notifications_push_trigger
  after insert on public.notifications
  for each row execute function public.notify_push_on_insert();

-- =============================================================================
-- Verify after applying:
--   -- recent pg_net responses (HTTP status from the Edge Function)
--   select id, status_code, content
--   from net._http_response
--   order by created desc limit 20;
--
--   -- the Vault secrets exist
--   select name from vault.decrypted_secrets
--   where name in ('push_function_url','push_webhook_secret');
-- =============================================================================
