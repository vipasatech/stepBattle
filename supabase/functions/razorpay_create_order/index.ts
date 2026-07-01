// razorpay_create_order — server-side order creation for the XP top-up flow.
//
// HTTP:        POST /functions/v1/razorpay_create_order
// Auth:        Supabase JWT (the user's session — verified by Supabase before
//              we even run, since `verify_jwt = true` is the default).
// Input:       { user_id: uuid, xp_amount: int, amount_inr: int }
// Output:      { order_id: string, key_id: string }
//
// FLOW:
//   1. Validate the payload. xp_amount and amount_inr must be equal (₹1 = 1 XP
//      — the rate is fixed server-side so a malicious client can't claim a
//      big XP grant for a small payment). amount_inr ∈ [1, 100_000].
//   2. Confirm the caller's auth user_id matches the body's user_id (no
//      buying XP for someone else).
//   3. POST https://api.razorpay.com/v1/orders with Basic auth (KEY_ID:SECRET).
//   4. Insert a row in public.xp_purchases (status='created') keyed by the
//      Razorpay order_id (UNIQUE) so re-runs / retries are idempotent.
//   5. Return { order_id, key_id } so the client can launch the Razorpay
//      checkout widget.
//
// SECRETS (set in Supabase → Edge Functions → Secrets):
//   • RAZORPAY_KEY_ID
//   • RAZORPAY_KEY_SECRET
//
// AUTO-INJECTED BY SUPABASE:
//   • SUPABASE_URL
//   • SUPABASE_SERVICE_ROLE_KEY  (bypasses RLS — used to write xp_purchases)
//   • SUPABASE_ANON_KEY
//
// Note: the verify step lives in `razorpay_verify`. This function ONLY
// reserves the order; XP is not credited until the signed payment comes
// back through that sibling function.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.0';
import { corsHeaders } from '../_shared/cors.ts';

interface CreateOrderBody {
  user_id?: string;
  xp_amount?: number;
  amount_inr?: number;
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    const keyId = Deno.env.get('RAZORPAY_KEY_ID');
    const keySecret = Deno.env.get('RAZORPAY_KEY_SECRET');
    if (!keyId || !keySecret) {
      return json({ error: 'Razorpay keys not configured' }, 500);
    }

    const body = (await req.json()) as CreateOrderBody;
    const { user_id, xp_amount, amount_inr } = body;

    if (
      !user_id ||
      typeof xp_amount !== 'number' ||
      typeof amount_inr !== 'number'
    ) {
      return json({ error: 'Invalid payload' }, 400);
    }
    // Rate is fixed server-side at ₹1 = 1 XP. Anything else is a bug or an
    // attempt to game the system; either way, reject.
    if (xp_amount !== amount_inr) {
      return json({ error: 'xp_amount must equal amount_inr (rate ₹1 = 1 XP)' }, 400);
    }
    if (!Number.isInteger(amount_inr) || amount_inr < 1 || amount_inr > 100_000) {
      return json({ error: 'amount_inr must be an integer between 1 and 100000' }, 400);
    }

    // Authenticate the caller by re-running the JWT against an anon client.
    // (verify_jwt is on by default, but Supabase doesn't expose the user's
    //  uid in the function — we have to pull it from the Authorization
    //  header ourselves.)
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

    // Create the order at Razorpay. amount is in paise (smallest INR unit).
    const orderPayload = {
      amount: amount_inr * 100,
      currency: 'INR',
      // Receipt is just a free-form string Razorpay echoes back on the
      // webhook. Keep it short + traceable.
      receipt: `xp_${user_id.slice(0, 8)}_${Date.now()}`,
      notes: {
        user_id,
        xp_amount: String(xp_amount),
      },
    };

    const basic = btoa(`${keyId}:${keySecret}`);
    const orderRes = await fetch('https://api.razorpay.com/v1/orders', {
      method: 'POST',
      headers: {
        Authorization: `Basic ${basic}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify(orderPayload),
    });
    if (!orderRes.ok) {
      const errText = await orderRes.text();
      console.error('razorpay order create failed', orderRes.status, errText);
      return json({ error: 'razorpay_order_create_failed', detail: errText }, 502);
    }
    const order = await orderRes.json() as { id: string };
    const orderId = order.id;
    if (!orderId) {
      return json({ error: 'razorpay returned no order id' }, 502);
    }

    // Reserve the row in xp_purchases with the service-role client so RLS
    // doesn't bite. UNIQUE on razorpay_order_id makes a retry idempotent.
    const supabaseAdmin = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    );
    const { error: insertErr } = await supabaseAdmin
      .from('xp_purchases')
      .insert({
        user_id,
        amount_inr,
        xp_credited: xp_amount,
        razorpay_order_id: orderId,
        status: 'created',
      });
    if (insertErr && !insertErr.message.includes('duplicate key')) {
      console.error('xp_purchases insert failed', insertErr);
      return json({ error: 'db_insert_failed' }, 500);
    }

    return json({ order_id: orderId, key_id: keyId });
  } catch (e) {
    console.error('razorpay_create_order:unhandled', e);
    return json({ error: 'unhandled', detail: String(e) }, 500);
  }
});

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}
