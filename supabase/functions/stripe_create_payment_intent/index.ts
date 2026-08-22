// stripe_create_payment_intent — server-side PaymentIntent creation for
// the Stripe XP-purchase flow.
//
// HTTP:        POST /functions/v1/stripe_create_payment_intent
// Auth:        Supabase JWT (verify_jwt = true — the client's session).
// Input:       {
//                user_id: uuid,
//                xp_amount: int,          // XP the user is buying
//                amount_minor: int,       // total in currency's smallest unit
//                                         // (paise for INR, cents for USD, etc.)
//                currency: string,        // ISO 4217, lowercase (e.g. 'inr','usd')
//              }
// Output:      {
//                client_secret: string,
//                payment_intent_id: string,
//                publishable_key: string,
//              }
//
// FLOW:
//   1. Validate payload — currency is one of the supported set, xp_amount
//      and amount_minor are positive integers, currency matches the price
//      the client is showing (server enforces via the pricing catalog
//      duplicated below — a malicious client can't send $0.01 for 100 XP).
//   2. Verify JWT — caller's auth uid matches user_id (no buying XP for
//      someone else).
//   3. Create Stripe PaymentIntent with amount+currency, capture on-payment
//      (default `automatic` capture), attach metadata { user_id, xp_amount }.
//   4. Insert xp_purchases row with provider='stripe', status='created',
//      stripe_payment_intent_id, currency, amount_minor.
//   5. Return client_secret so the client can confirm via PaymentSheet.
//
// SECRETS (Supabase → Edge Functions → Secrets):
//   • STRIPE_SECRET_KEY        — sk_test_... / sk_live_...
//   • STRIPE_PUBLISHABLE_KEY   — pk_test_... / pk_live_...
// AUTO-INJECTED:
//   • SUPABASE_URL
//   • SUPABASE_SERVICE_ROLE_KEY
//   • SUPABASE_ANON_KEY

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.0';
import { corsHeaders } from '../_shared/cors.ts';

// SERVER-SIDE pricing catalog — the single source of truth for what a
// given (xp_amount, currency) tier costs. Keeps clients honest: even if
// the app requests 10000 XP for $0.01, we reject.
//
// Mirrors lib/config/pricing.dart on the client. If you change one,
// change the other. Tests / lint could enforce parity later.
const PRICING: Record<string, Record<number, number>> = {
  inr: {
    100:   10000,    // ₹100 → 10,000 paise
    500:   50000,
    1000:  100000,
    2500:  250000,
    5000:  500000,
    10000: 1000000,
  },
  usd: {
    100:   199,      // 100 XP → $1.99 → 199 cents
    500:   699,
    1000:  1299,
    2500:  2999,
    5000:  5499,
    10000: 9999,
  },
  eur: {
    100:   179,
    500:   649,
    1000:  1199,
    2500:  2799,
    5000:  4999,
    10000: 8999,
  },
  gbp: {
    100:   149,
    500:   549,
    1000:  999,
    2500:  2499,
    5000:  4499,
    10000: 7999,
  },
  aud: {
    100:   299,
    500:   999,
    1000:  1899,
    2500:  4499,
    5000:  7999,
    10000: 14999,
  },
};
const SUPPORTED_CURRENCIES = new Set(Object.keys(PRICING));

interface CreatePaymentIntentBody {
  user_id?: string;
  xp_amount?: number;
  amount_minor?: number;
  currency?: string;
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    const stripeKey = Deno.env.get('STRIPE_SECRET_KEY');
    const stripePub = Deno.env.get('STRIPE_PUBLISHABLE_KEY');
    if (!stripeKey || !stripePub) {
      return json({ error: 'stripe_keys_not_configured' }, 500);
    }

    const body = (await req.json()) as CreatePaymentIntentBody;
    const { user_id, xp_amount, amount_minor } = body;
    const currency = (body.currency ?? '').toLowerCase();

    // Payload shape.
    if (
      !user_id ||
      typeof xp_amount !== 'number' ||
      typeof amount_minor !== 'number' ||
      !currency
    ) {
      return json({ error: 'invalid_payload' }, 400);
    }
    if (!Number.isInteger(xp_amount) || xp_amount < 1) {
      return json({ error: 'invalid_xp_amount' }, 400);
    }
    if (!Number.isInteger(amount_minor) || amount_minor < 1) {
      return json({ error: 'invalid_amount_minor' }, 400);
    }
    if (!SUPPORTED_CURRENCIES.has(currency)) {
      return json({ error: 'unsupported_currency' }, 400);
    }
    const expected = PRICING[currency][xp_amount];
    if (expected === undefined) {
      return json({ error: 'unsupported_xp_tier' }, 400);
    }
    if (expected !== amount_minor) {
      return json({
        error: 'amount_mismatch',
        expected_minor: expected,
        got_minor: amount_minor,
      }, 400);
    }

    // Authenticate caller.
    const authHeader = req.headers.get('Authorization') ?? '';
    const supabaseAnon = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_ANON_KEY')!,
      { global: { headers: { Authorization: authHeader } } },
    );
    const { data: userData, error: userErr } = await supabaseAnon.auth.getUser();
    if (userErr || !userData.user) {
      return json({ error: 'not_authenticated' }, 401);
    }
    if (userData.user.id !== user_id) {
      return json({ error: 'user_id_mismatch' }, 403);
    }

    // Create Stripe PaymentIntent via the REST API. We hand-roll the
    // POST because pulling in the Stripe SDK for one call bloats the
    // function cold-start. Automatic payment methods let Stripe pick
    // the best set based on the merchant's dashboard config.
    const form = new URLSearchParams();
    form.set('amount', String(amount_minor));
    form.set('currency', currency);
    form.set('automatic_payment_methods[enabled]', 'true');
    form.set('metadata[user_id]', user_id);
    form.set('metadata[xp_amount]', String(xp_amount));

    const stripeRes = await fetch('https://api.stripe.com/v1/payment_intents', {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${stripeKey}`,
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: form.toString(),
    });
    if (!stripeRes.ok) {
      const errText = await stripeRes.text();
      console.error('stripe payment_intent create failed', stripeRes.status, errText);
      return json({ error: 'stripe_intent_create_failed', detail: errText }, 502);
    }
    const intent = await stripeRes.json() as {
      id: string;
      client_secret: string;
    };
    if (!intent.id || !intent.client_secret) {
      return json({ error: 'stripe_returned_no_intent' }, 502);
    }

    // Reserve the row in xp_purchases via service_role (bypasses RLS).
    // stripe_payment_intent_id is UNIQUE — retries are idempotent.
    const supabaseAdmin = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    );
    const { error: insertErr } = await supabaseAdmin
      .from('xp_purchases')
      .insert({
        user_id,
        provider: 'stripe',
        xp_credited: xp_amount,
        stripe_payment_intent_id: intent.id,
        currency: currency.toUpperCase(),
        amount_minor,
        // amount_inr kept populated for legacy readers — approx via
        // pricing catalog (INR direct, others use the catalog's INR
        // price for the same xp tier for cross-currency reporting).
        amount_inr: PRICING.inr[xp_amount],
        status: 'created',
      });
    if (insertErr && !insertErr.message.includes('duplicate key')) {
      console.error('xp_purchases insert failed', insertErr);
      return json({ error: 'db_insert_failed', detail: insertErr.message }, 500);
    }

    return json({
      client_secret: intent.client_secret,
      payment_intent_id: intent.id,
      publishable_key: stripePub,
    });
  } catch (e) {
    console.error('stripe_create_payment_intent:unhandled', e);
    return json({ error: 'unhandled', detail: String(e) }, 500);
  }
});

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}
