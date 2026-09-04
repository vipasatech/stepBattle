// subscription_verify — finalises a subscription upgrade after the
// user pays via the native Razorpay SDK. Sibling to razorpay_verify
// (XP top-up); differs in what gets granted (profiles.subscription_*
// vs credit_user_xp).
//
// HTTP:        POST /functions/v1/subscription_verify
// Auth:        Supabase JWT (the user's session).
// Input:       {
//                order_id:   string,   // from subscription_create_order
//                payment_id: string,   // from Razorpay checkout event
//                signature:  string,   // from Razorpay checkout event
//                user_id:    uuid,
//              }
// Output:      { granted: bool, tier?: string, expires_at?: string }
//
// FLOW:
//   1. Validate payload + verify caller's auth uid matches user_id.
//   2. HMAC-SHA256(`${order_id}|${payment_id}`, RAZORPAY_KEY_SECRET)
//      and compare against `signature`. Constant-time compare.
//   3. SELECT the matching subscription_orders row. Reject if
//      missing, if the user_id doesn't match, or if status is
//      already 'success' (idempotency — a double-fire on the
//      success event must not double-grant).
//   4. UPDATE the row to status='success', stamp payment_id +
//      completed_at.
//   5. UPDATE profiles: subscription_tier, subscription_expires_at
//      (now + 30d for monthly, now + 365d for yearly),
//      subscription_billing_period.
//   6. Return {granted: true, tier, expires_at}.
//
// Coexistence with the webhook path (stepBattle_web razorpay-webhook):
//   • The webhook is the AUTHORITY on payment settlement — Razorpay
//     will fire it regardless of whether this function runs. If the
//     user closes the app between paying and the client posting to
//     this function, the webhook still lands and grants the tier
//     from the same subscription_orders row.
//   • This function exists so the mobile app can grant the tier
//     IMMEDIATELY without waiting for the webhook (which may take
//     seconds to arrive from Razorpay). We race the webhook and
//     whichever lands first wins — the second UPDATE is a no-op
//     because status='success' is already there.
//   • Both paths use the same idempotency guard (status transition
//     from 'pending' → 'success' only).
//
// SECRETS: RAZORPAY_KEY_SECRET (set in Supabase → Edge Functions →
// Secrets).

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.0';

// Inlined (used to live in ../_shared/cors.ts). Kept inline so the
// Supabase Dashboard editor can deploy this function as a single file
// — the Dashboard sandbox doesn't resolve sibling folder imports. The
// content is identical to the shared version used by the XP functions.
const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers':
    'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

interface VerifyBody {
  order_id?: string;
  payment_id?: string;
  signature?: string;
  user_id?: string;
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    const keySecret = Deno.env.get('RAZORPAY_KEY_SECRET');
    if (!keySecret) {
      return json({ error: 'razorpay secret not configured' }, 500);
    }

    const body = (await req.json()) as VerifyBody;
    const { order_id, payment_id, signature, user_id } = body;
    if (!order_id || !payment_id || !signature || !user_id) {
      return json({ error: 'Invalid payload' }, 400);
    }

    // Confirm the caller owns the user_id.
    const authHeader = req.headers.get('Authorization') ?? '';
    const supabaseAnon = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_ANON_KEY')!,
      { global: { headers: { Authorization: authHeader } } },
    );
    const { data: userData, error: userErr } =
      await supabaseAnon.auth.getUser();
    if (userErr || !userData.user) {
      return json({ error: 'Not authenticated' }, 401);
    }
    if (userData.user.id !== user_id) {
      return json({ error: 'user_id mismatch' }, 403);
    }

    // HMAC verify.
    const expected = await hmacSha256Hex(
      keySecret,
      `${order_id}|${payment_id}`,
    );
    if (!timingSafeEqual(expected, signature)) {
      console.warn('subscription_verify:signature_mismatch', {
        order_id,
        user_id,
      });
      return json({ granted: false, error: 'signature_mismatch' }, 400);
    }

    // Look up the reservation row.
    const supabaseAdmin = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    );
    const { data: sub, error: selErr } = await supabaseAdmin
      .from('subscription_orders')
      .select('id, user_id, tier, billing_period, status')
      .eq('razorpay_order_id', order_id)
      .maybeSingle();
    if (selErr) {
      console.error('subscription_orders select failed', selErr);
      return json({ error: 'db_select_failed' }, 500);
    }
    if (!sub) {
      return json({ error: 'order_not_found' }, 404);
    }
    if (sub.user_id !== user_id) {
      return json({ error: 'user_id mismatch on order row' }, 403);
    }

    // Compute expires_at from period.
    const now = new Date();
    const periodMs = sub.billing_period === 'yearly'
      ? 365 * 24 * 60 * 60 * 1000
      : 30 * 24 * 60 * 60 * 1000;
    const expiresAt = new Date(now.getTime() + periodMs);

    if (sub.status === 'success') {
      // Idempotent re-fire (webhook already ran, or client re-invoked).
      // Return the current state so the client UX is consistent.
      return json({
        granted: true,
        idempotent: true,
        tier: sub.tier,
        expires_at: expiresAt.toISOString(),
      });
    }
    if (sub.status !== 'pending') {
      return json({ error: `order status is ${sub.status}` }, 409);
    }

    // Stamp the order row BEFORE profile update — optimistic
    // concurrency guard on status='pending' ensures only one path
    // (this function OR the webhook) wins.
    const { error: updErr } = await supabaseAdmin
      .from('subscription_orders')
      .update({
        status: 'success',
        razorpay_payment_id: payment_id,
        // Actual column name is `completed_at` (verified via
        // information_schema query 2026-08-31). Earlier draft wrote
        // `captured_at` mirroring xp_purchases' column but the
        // subscription_orders schema uses `completed_at`.
        completed_at: now.toISOString(),
      })
      .eq('id', sub.id)
      .eq('status', 'pending');
    if (updErr) {
      console.error('subscription_orders update failed', updErr);
      return json({ error: 'db_update_failed' }, 500);
    }

    // Grant the tier on the profile. Same columns the webhook writes
    // (mirror the web razorpay-webhook.js semantics exactly).
    const { error: profileErr } = await supabaseAdmin
      .from('profiles')
      .update({
        subscription_tier: sub.tier,
        subscription_expires_at: expiresAt.toISOString(),
        subscription_billing_period: sub.billing_period,
      })
      .eq('id', user_id);
    if (profileErr) {
      // Roll back the order row so the webhook can retry the grant.
      // We DON'T zero out payment_id — that's proof of payment that
      // must survive a re-grant attempt.
      await supabaseAdmin
        .from('subscription_orders')
        .update({ status: 'pending' })
        .eq('id', sub.id);
      console.error('profiles subscription update failed', profileErr);
      return json({ granted: false, error: 'profile_update_failed' }, 500);
    }

    return json({
      granted: true,
      tier: sub.tier,
      expires_at: expiresAt.toISOString(),
    });
  } catch (e) {
    console.error('subscription_verify:unhandled', e);
    return json({ error: 'unhandled', detail: String(e) }, 500);
  }
});

async function hmacSha256Hex(
  secret: string,
  message: string,
): Promise<string> {
  const enc = new TextEncoder();
  const key = await crypto.subtle.importKey(
    'raw',
    enc.encode(secret),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign'],
  );
  const sig = await crypto.subtle.sign('HMAC', key, enc.encode(message));
  return Array.from(new Uint8Array(sig))
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('');
}

function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) {
    diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  }
  return diff === 0;
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}
