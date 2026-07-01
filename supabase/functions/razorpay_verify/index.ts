// razorpay_verify — finalizes an XP top-up after the user pays.
//
// HTTP:        POST /functions/v1/razorpay_verify
// Auth:        Supabase JWT (the user's session).
// Input:       {
//                order_id:   string,   // from razorpay_create_order
//                payment_id: string,   // from Razorpay checkout success event
//                signature:  string,   // from Razorpay checkout success event
//                user_id:    uuid,
//                xp_amount:  int,
//              }
// Output:      { credited: bool, new_balance?: int }
//
// FLOW:
//   1. Validate payload + verify caller's auth uid matches user_id.
//   2. HMAC-SHA256(`${order_id}|${payment_id}`, RAZORPAY_KEY_SECRET) and
//      compare against `signature`. Constant-time compare to avoid timing
//      side channels.
//   3. SELECT the matching xp_purchases row. Reject if missing, if the
//      user_id doesn't match, or if status is already 'captured'
//      (idempotency — a double-fire on the success event must not
//      double-credit).
//   4. UPDATE the row to status='captured', stamp payment_id + signature
//      + captured_at.
//   5. Call credit_user_xp(user_id, xp_amount, 'purchase', {order_id}).
//      Read the returned bigint balance and return it.
//
// SECRETS: RAZORPAY_KEY_SECRET (set in Supabase → Edge Functions → Secrets).

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.0';
import { corsHeaders } from '../_shared/cors.ts';

interface VerifyBody {
  order_id?: string;
  payment_id?: string;
  signature?: string;
  user_id?: string;
  xp_amount?: number;
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
    const { order_id, payment_id, signature, user_id, xp_amount } = body;

    if (
      !order_id ||
      !payment_id ||
      !signature ||
      !user_id ||
      typeof xp_amount !== 'number' ||
      !Number.isInteger(xp_amount) ||
      xp_amount < 1
    ) {
      return json({ error: 'Invalid payload' }, 400);
    }

    // Confirm the caller owns the user_id they're claiming to credit.
    const authHeader = req.headers.get('Authorization') ?? '';
    const supabaseAnon = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_ANON_KEY')!,
      { global: { headers: { Authorization: authHeader } } },
    );
    const { data: userData, error: userErr } = await supabaseAnon.auth.getUser();
    if (userErr || !userData.user) {
      return json({ error: 'Not authenticated' }, 401);
    }
    if (userData.user.id !== user_id) {
      return json({ error: 'user_id mismatch' }, 403);
    }

    // HMAC verify. Razorpay docs: signature = hmac_sha256(`${orderId}|${paymentId}`, secret)
    // returned as hex. Use a constant-time compare to avoid timing leaks.
    const expected = await hmacSha256Hex(keySecret, `${order_id}|${payment_id}`);
    if (!timingSafeEqual(expected, signature)) {
      console.warn('razorpay_verify:signature_mismatch', { order_id, user_id });
      return json({ credited: false, error: 'signature_mismatch' }, 400);
    }

    // Look up the reservation row + check it's not already captured.
    const supabaseAdmin = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    );
    const { data: purchase, error: selErr } = await supabaseAdmin
      .from('xp_purchases')
      .select('id, user_id, xp_credited, status')
      .eq('razorpay_order_id', order_id)
      .maybeSingle();

    if (selErr) {
      console.error('xp_purchases select failed', selErr);
      return json({ error: 'db_select_failed' }, 500);
    }
    if (!purchase) {
      return json({ error: 'order_not_found' }, 404);
    }
    if (purchase.user_id !== user_id) {
      return json({ error: 'user_id mismatch on purchase row' }, 403);
    }
    if (purchase.status === 'captured') {
      // Idempotent re-fire — the original credit already happened. Surface
      // success so the client UX is consistent.
      return json({ credited: true, idempotent: true });
    }
    if (purchase.status !== 'created') {
      // 'failed' or 'refunded' — refuse to credit.
      return json({ error: `purchase status is ${purchase.status}` }, 409);
    }
    if (purchase.xp_credited !== xp_amount) {
      // Client is asking to credit a different amount than what was
      // reserved. Reject — the reservation is the source of truth.
      return json({ error: 'xp_amount mismatch vs reservation' }, 400);
    }

    // Stamp the row BEFORE crediting. If credit_user_xp fails we'll retry
    // on the next call (status flips back to 'created' on failure path
    // below); a duplicate stamp is harmless because the unique-on-order
    // guarantees there's only one row.
    const { error: updErr } = await supabaseAdmin
      .from('xp_purchases')
      .update({
        status: 'captured',
        razorpay_payment_id: payment_id,
        razorpay_signature: signature,
        captured_at: new Date().toISOString(),
      })
      .eq('id', purchase.id)
      .eq('status', 'created'); // optimistic concurrency guard
    if (updErr) {
      console.error('xp_purchases update failed', updErr);
      return json({ error: 'db_update_failed' }, 500);
    }

    // Credit the user. credit_user_xp returns the new balance.
    const { data: creditData, error: creditErr } = await supabaseAdmin.rpc(
      'credit_user_xp',
      {
        p_user_id: user_id,
        p_delta: xp_amount,
        p_reason: 'purchase',
        p_context: { order_id, payment_id },
      },
    );
    if (creditErr) {
      // Roll the status back so a retry can re-attempt. We DON'T zero out
      // payment_id/signature because they're the proof of payment that
      // needs to survive a re-credit.
      await supabaseAdmin
        .from('xp_purchases')
        .update({ status: 'created' })
        .eq('id', purchase.id);
      console.error('credit_user_xp failed', creditErr);
      return json({ credited: false, error: 'credit_failed' }, 500);
    }

    return json({ credited: true, new_balance: creditData });
  } catch (e) {
    console.error('razorpay_verify:unhandled', e);
    return json({ error: 'unhandled', detail: String(e) }, 500);
  }
});

async function hmacSha256Hex(secret: string, message: string): Promise<string> {
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
