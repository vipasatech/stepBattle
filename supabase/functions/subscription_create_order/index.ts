// subscription_create_order — server-side order creation for the
// subscription-upgrade native SDK flow (Pro / Max plans, monthly /
// yearly). Sibling to razorpay_create_order (which handles the XP
// top-up flow). Both talk to the same Razorpay account; they differ
// only in what the client uses the order_id for downstream.
//
// HTTP:        POST /functions/v1/subscription_create_order
// Auth:        Supabase JWT (the user's session — verified by Supabase
//              before we even run, since `verify_jwt = true` is on).
// Input:       { user_id: uuid, tier: 'pro' | 'max', period: 'monthly' | 'yearly' }
// Output:      { order_id: string, key_id: string, amount_paise: int,
//                currency: 'INR' }
//
// Why a NEW Edge Function instead of extending razorpay_create_order:
// XP purchases and subscription upgrades write to DIFFERENT tables
// (xp_purchases vs subscription_orders) with different downstream
// crediting logic (credit_user_xp vs profiles.subscription_tier
// update). Keeping them separate avoids overloading a single
// function with two divergent code paths.
//
// FLOW:
//   1. Validate the payload — tier ∈ {pro, max}, period ∈ {monthly,
//      yearly}. Amounts are looked up from a server-side constant
//      table so a malicious client can't declare a ₹1 payment for a
//      ₹2999 tier.
//   2. Confirm the caller's auth uid matches the body's user_id
//      (no upgrading someone else's account).
//   3. POST https://api.razorpay.com/v1/orders with Basic auth
//      (KEY_ID:SECRET). notes carry {user_id, tier, period} for the
//      webhook to correlate.
//   4. Insert a row in public.subscription_orders (status='pending')
//      keyed by the Razorpay order_id (UNIQUE) so re-runs / retries
//      are idempotent. Same table the web checkout writes to — the
//      webhook doesn't care which surface created the row.
//   5. Return { order_id, key_id, amount_paise, currency } so the
//      client can launch the Razorpay native checkout with the
//      right amount without a second server hop.
//
// SECRETS (set in Supabase → Edge Functions → Secrets):
//   • RAZORPAY_KEY_ID
//   • RAZORPAY_KEY_SECRET
//
// AUTO-INJECTED BY SUPABASE:
//   • SUPABASE_URL
//   • SUPABASE_SERVICE_ROLE_KEY (bypasses RLS — used to write
//     subscription_orders)
//   • SUPABASE_ANON_KEY
//
// Verification lives in `subscription_verify`. This function ONLY
// reserves the order; the tier is NOT granted until the signed
// payment comes back through that sibling function.

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

type Tier = 'pro' | 'max';
type Period = 'monthly' | 'yearly';

interface CreateSubOrderBody {
  user_id?: string;
  tier?: string;
  period?: string;
}

// Server-side price catalog. Must match:
//   • lib/models/subscription_model.dart :: SubscriptionPricing.pro/max
//   • stepBattle_web/api/_plans.js       :: PLANS.pro/family
// If any of those drift, refuse the payment rather than silently
// charging the wrong amount. amounts are in PAISE (Razorpay's unit).
const PRICE_PAISE: Record<Tier, Record<Period, number>> = {
  pro: { monthly: 149_00, yearly: 1_499_00 },
  max: { monthly: 299_00, yearly: 2_999_00 },
};

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

    const body = (await req.json()) as CreateSubOrderBody;
    const { user_id, tier, period } = body;

    if (!user_id || typeof user_id !== 'string') {
      return json({ error: 'Invalid payload: user_id' }, 400);
    }
    if (tier !== 'pro' && tier !== 'max') {
      return json({ error: 'Invalid payload: tier must be pro or max' }, 400);
    }
    if (period !== 'monthly' && period !== 'yearly') {
      return json(
        { error: 'Invalid payload: period must be monthly or yearly' },
        400,
      );
    }
    const amountPaise = PRICE_PAISE[tier][period];
    if (!amountPaise) {
      return json({ error: 'No price for tier/period' }, 400);
    }

    // Authenticate the caller — same pattern as razorpay_create_order.
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

    // Create the Razorpay order. notes carry the tier + period so the
    // webhook (razorpay-webhook — deployed on the web repo's Vercel
    // functions today) can grant the plan when it fires. `receipt` is
    // an opaque string Razorpay echoes back on webhook payloads; we
    // keep it short + traceable.
    const orderPayload = {
      amount: amountPaise,
      currency: 'INR',
      receipt: `sub_${user_id.slice(0, 8)}_${Date.now()}`,
      notes: {
        user_id,
        tier,
        period,
        source: 'mobile_native',
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
      console.error(
        'subscription_create_order:razorpay_failed',
        orderRes.status,
        errText,
      );
      return json(
        { error: 'razorpay_order_create_failed', detail: errText },
        502,
      );
    }
    const order = (await orderRes.json()) as { id: string };
    const orderId = order.id;
    if (!orderId) {
      return json({ error: 'razorpay returned no order id' }, 502);
    }

    // Reserve a subscription_orders row via the service-role client.
    // Same table the web checkout writes to (create-order.js on the
    // web repo); tier column uses the pre-rename catalog value 'pro'
    // or 'family' because the current DB CHECK still expects those.
    // We map max → family at write time so a future rename migration
    // isn't a hard requirement.
    const tierForDb = tier === 'max' ? 'family' : 'pro';
    const supabaseAdmin = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    );
    const { error: insertErr } = await supabaseAdmin
      .from('subscription_orders')
      .insert({
        user_id,
        razorpay_order_id: orderId,
        tier: tierForDb,
        billing_period: period,
        amount_paise: amountPaise,
        currency: 'INR',
        status: 'pending',
      });
    if (insertErr && insertErr.code !== '23505') {
      console.error('subscription_orders insert failed', insertErr);
      return json({ error: 'db_insert_failed', detail: insertErr.message }, 500);
    }

    return json({
      order_id: orderId,
      key_id: keyId,
      amount_paise: amountPaise,
      currency: 'INR',
    });
  } catch (e) {
    console.error('subscription_create_order:unhandled', e);
    return json({ error: 'unhandled', detail: String(e) }, 500);
  }
});

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}
