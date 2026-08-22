// =============================================================================
// StepBattle — sync-wake-broadcast Edge Function
//
// Fetches every profile with a non-null fcm_token and calls the existing
// `send-push` function once per user with `silent: true` + a `sync_wake`
// data payload. The push briefly wakes the app (data-only, no tray
// notification) so it can call `headlessStepSync` and upload steps even
// when the OS has killed the foreground service and WorkManager.
//
// WHY REUSE send-push INSTEAD OF SPEAKING TO FCM DIRECTLY:
//   send-push already implements the whole FCM v1 auth dance (JWT sign,
//   token exchange, PEM parsing) and knows the `silent: true` shape
//   Android + iOS need. Duplicating that here would leave two places to
//   fix if the FCM API changes. This function is a fan-out wrapper only.
//
// TRIGGERED BY: pg_cron every 3 hours (see migration 0054 Step 3).
//
// DEPLOY:
//   supabase functions deploy sync-wake-broadcast --no-verify-jwt
// (`--no-verify-jwt` because pg_cron invokes via net.http_post, no user JWT.)
//
// SECRETS USED (all pre-existing):
//   PUSH_WEBHOOK_SECRET   shared secret guarding send-push
//   SUPABASE_URL          auto-populated by Supabase runtime
//   SUPABASE_SERVICE_ROLE_KEY  auto-populated; used to bypass RLS on
//                              the profiles read (fcm_token is not
//                              publicly readable).
// No FCM credentials needed here — send-push holds those.
// =============================================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { serve } from "https://deno.land/std@0.224.0/http/server.ts";

const CONCURRENCY = 8;

serve(async (_req: Request): Promise<Response> => {
  const started = Date.now();

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const pushSecret = Deno.env.get("PUSH_WEBHOOK_SECRET");
  if (!supabaseUrl || !serviceRoleKey || !pushSecret) {
    return jsonResponse(
      { error: "missing_env", need: ["SUPABASE_URL", "SUPABASE_SERVICE_ROLE_KEY", "PUSH_WEBHOOK_SECRET"] },
      500,
    );
  }

  const supabase = createClient(supabaseUrl, serviceRoleKey);

  // Pull every user with a device token. `is null` filter is server-side —
  // we never ship the null-token rows over the wire.
  const { data: rows, error } = await supabase
    .from("profiles")
    .select("id, fcm_token")
    .not("fcm_token", "is", null);
  if (error) return jsonResponse({ error: error.message }, 500);

  const pushUrl = `${supabaseUrl}/functions/v1/send-push`;
  const queue = [...(rows ?? [])];
  let sent = 0;
  let failed = 0;

  // Small concurrency (Deno single-threaded event loop). FCM's per-project
  // QPS default is ~600k/min — we send at most ~10k/tick, so we're not
  // limited by FCM; the cap keeps us gentle on the send-push function's
  // per-call cold-start budget and pg_net's response buffer.
  const workers = Array.from({ length: CONCURRENCY }, async () => {
    while (queue.length) {
      const row = queue.shift();
      if (!row?.fcm_token) continue;
      try {
        const res = await fetch(pushUrl, {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            "x-webhook-secret": pushSecret,
          },
          body: JSON.stringify({
            token: row.fcm_token,
            silent: true,
            data: { type: "sync_wake" },
          }),
        });
        if (res.ok) sent++;
        else failed++;
      } catch {
        failed++;
      }
    }
  });
  await Promise.all(workers);

  return jsonResponse({
    ok: true,
    total: rows?.length ?? 0,
    sent,
    failed,
    totalMs: Date.now() - started,
  });
});

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}
