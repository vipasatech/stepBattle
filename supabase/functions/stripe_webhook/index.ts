// stripe_webhook — server-of-record for Stripe payment lifecycle events.
//
// HTTP:        POST /functions/v1/stripe_webhook
// Auth:        NONE from Supabase (Stripe has no JWT). Authenticity via
//              HMAC-SHA256 signature in the Stripe-Signature header,
//              verified against STRIPE_WEBHOOK_SECRET. This function is
//              registered with `verify_jwt = false` in supabase/config.toml.
//
// Handles:
//   • payment_intent.succeeded      → credit XP if not already credited
//   • payment_intent.payment_failed → mark xp_purchases as failed
//   • charge.refunded               → debit XP + flip row to refunded
//
// Idempotent — same guarantees as razorpay_webhook: optimistic-concurrency
// on `status = 'created'` for capture, `status = 'captured'` for refund.
// Same row-uniqueness is guaranteed by xp_purchases.stripe_payment_intent_id
// being UNIQUE (migration 0039).
//
// FAILURE / RETRY
//   Stripe retries a 5xx up to 3 days with exponential backoff. Return
//   500 on transient DB errors; return 200 on business-logic no-ops
//   (unknown event, already credited, unknown intent) so Stripe stops
//   retrying.
//
// SECRETS (Supabase → Edge Functions → Secrets):
//   • STRIPE_WEBHOOK_SECRET  (whsec_..., distinct from STRIPE_SECRET_KEY)
// AUTO-INJECTED:
//   • SUPABASE_URL
//   • SUPABASE_SERVICE_ROLE_KEY

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.0';

interface StripeEvent {
  id?: string;
  type?: string;
  data?: {
    object?: PaymentIntentEntity | ChargeEntity;
  };
}

interface PaymentIntentEntity {
  id?: string;
  amount?: number;
  currency?: string;
  status?: string;
  last_payment_error?: { message?: string; code?: string };
  metadata?: { user_id?: string; xp_amount?: string };
}

interface ChargeEntity {
  id?: string;
  payment_intent?: string;
  amount_refunded?: number;
  amount?: number;
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') {
    return new Response('Method Not Allowed', { status: 405 });
  }

  const secret = Deno.env.get('STRIPE_WEBHOOK_SECRET');
  if (!secret) {
    console.error('stripe_webhook: STRIPE_WEBHOOK_SECRET not configured');
    return new Response('secret_missing', { status: 500 });
  }

  // MUST read the raw body BEFORE parsing — HMAC signs the exact bytes.
  const rawBody = await req.text();
  const sigHeader = req.headers.get('Stripe-Signature') ?? '';
  if (!sigHeader) {
    console.warn('stripe_webhook: missing Stripe-Signature');
    return new Response('missing_signature', { status: 401 });
  }

  const sigValid = await verifyStripeSignature(rawBody, sigHeader, secret);
  if (!sigValid) {
    console.warn('stripe_webhook: signature mismatch');
    return new Response('signature_mismatch', { status: 401 });
  }

  let event: StripeEvent;
  try {
    event = JSON.parse(rawBody);
  } catch (_) {
    console.error('stripe_webhook: body not JSON despite valid signature');
    return new Response('ok', { status: 200 });
  }

  const supabase = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
  );

  try {
    switch (event.type) {
      case 'payment_intent.succeeded':
        return await handleIntentSucceeded(supabase, event);
      case 'payment_intent.payment_failed':
        return await handleIntentFailed(supabase, event);
      case 'charge.refunded':
        return await handleChargeRefunded(supabase, event);
      default:
        console.log('stripe_webhook: ignoring event', event.type);
        return new Response('ok', { status: 200 });
    }
  } catch (e) {
    console.error('stripe_webhook: handler crash', event.type, e);
    return new Response('handler_crash', { status: 500 });
  }
});

// -----------------------------------------------------------------------------
// Handlers
// -----------------------------------------------------------------------------

// deno-lint-ignore no-explicit-any
async function handleIntentSucceeded(supabase: any, event: StripeEvent) {
  const pi = event.data?.object as PaymentIntentEntity | undefined;
  if (!pi?.id) return new Response('ok', { status: 200 });

  const { data: purchase, error: selErr } = await supabase
    .from('xp_purchases')
    .select('id, user_id, xp_credited, status')
    .eq('stripe_payment_intent_id', pi.id)
    .maybeSingle();
  if (selErr) throw selErr;
  if (!purchase) {
    // Stray webhook (test event, deleted row, etc.) — ack and move on.
    console.warn('stripe_webhook: no xp_purchases row for pi', pi.id);
    return new Response('ok', { status: 200 });
  }
  if (purchase.status === 'captured') {
    // Already credited (client-side confirm won the race, or duplicate
    // webhook delivery). Nothing to do.
    return new Response('ok', { status: 200 });
  }
  if (purchase.status !== 'created') {
    // failed / refunded — do not credit.
    return new Response('ok', { status: 200 });
  }

  // Optimistic concurrency — only proceed if still in 'created' when we
  // write. Same guarantee we use for razorpay.
  const { error: updErr, count } = await supabase
    .from('xp_purchases')
    .update({
      status: 'captured',
      captured_at: new Date().toISOString(),
    }, { count: 'exact' })
    .eq('id', purchase.id)
    .eq('status', 'created');
  if (updErr) throw updErr;
  if (!count) return new Response('ok', { status: 200 });

  const { error: credErr } = await supabase.rpc('credit_user_xp', {
    p_user_id: purchase.user_id,
    p_delta:   purchase.xp_credited,
    p_reason:  'purchase',
    p_context: { payment_intent_id: pi.id, provider: 'stripe', via: 'webhook' },
  });
  if (credErr) {
    // Roll status back so a retry re-attempts.
    await supabase
      .from('xp_purchases')
      .update({ status: 'created', captured_at: null })
      .eq('id', purchase.id);
    throw credErr;
  }

  console.log('stripe_webhook: credited', {
    payment_intent_id: pi.id,
    user_id: purchase.user_id,
    xp: purchase.xp_credited,
  });
  return new Response('ok', { status: 200 });
}

// deno-lint-ignore no-explicit-any
async function handleIntentFailed(supabase: any, event: StripeEvent) {
  const pi = event.data?.object as PaymentIntentEntity | undefined;
  if (!pi?.id) return new Response('ok', { status: 200 });

  const reason = pi.last_payment_error?.message
    ?? pi.last_payment_error?.code
    ?? 'stripe_failed';

  const { error } = await supabase
    .from('xp_purchases')
    .update({
      status: 'failed',
      failure_reason: reason,
    })
    .eq('stripe_payment_intent_id', pi.id)
    .eq('status', 'created');
  if (error) throw error;
  return new Response('ok', { status: 200 });
}

// deno-lint-ignore no-explicit-any
async function handleChargeRefunded(supabase: any, event: StripeEvent) {
  const charge = event.data?.object as ChargeEntity | undefined;
  const pi_id = charge?.payment_intent;
  if (!pi_id) return new Response('ok', { status: 200 });

  const { data: purchase, error: selErr } = await supabase
    .from('xp_purchases')
    .select('id, user_id, xp_credited, status, amount_minor')
    .eq('stripe_payment_intent_id', pi_id)
    .maybeSingle();
  if (selErr) throw selErr;
  if (!purchase) {
    console.warn('stripe_webhook: no xp_purchases row for refund', pi_id);
    return new Response('ok', { status: 200 });
  }
  if (purchase.status === 'refunded') {
    return new Response('ok', { status: 200 });
  }
  if (purchase.status !== 'captured') {
    console.warn('stripe_webhook: refund on non-captured purchase',
      { id: purchase.id, status: purchase.status });
    return new Response('ok', { status: 200 });
  }

  // Partial refunds: claw back the proportional XP.
  const refundedMinor = charge?.amount_refunded ?? 0;
  const originalMinor = charge?.amount ?? purchase.amount_minor ?? 0;
  let xpToClawback = purchase.xp_credited;
  if (refundedMinor > 0 && originalMinor > 0 && refundedMinor < originalMinor) {
    xpToClawback = Math.floor(
      (refundedMinor / originalMinor) * purchase.xp_credited,
    );
  }
  if (xpToClawback <= 0) return new Response('ok', { status: 200 });

  const { error: updErr, count } = await supabase
    .from('xp_purchases')
    .update({
      status: 'refunded',
      refunded_at: new Date().toISOString(),
    }, { count: 'exact' })
    .eq('id', purchase.id)
    .eq('status', 'captured');
  if (updErr) throw updErr;
  if (!count) return new Response('ok', { status: 200 });

  const { error: credErr } = await supabase.rpc('credit_user_xp', {
    p_user_id: purchase.user_id,
    p_delta:   -xpToClawback,
    p_reason:  'purchase_refund',
    p_context: {
      order_id: purchase.id,
      payment_intent_id: pi_id,
      charge_id: charge?.id,
      provider: 'stripe',
    },
  });
  if (credErr) {
    await supabase
      .from('xp_purchases')
      .update({ status: 'captured', refunded_at: null })
      .eq('id', purchase.id);
    throw credErr;
  }

  console.log('stripe_webhook: refunded', {
    payment_intent_id: pi_id,
    user_id: purchase.user_id,
    xp: -xpToClawback,
  });
  return new Response('ok', { status: 200 });
}

// -----------------------------------------------------------------------------
// Signature verification — Stripe's Stripe-Signature header format:
//   `t=<unix-timestamp>,v1=<hex-sha256>,v0=<hex-sha256>,...`
// The signed payload is `<timestamp>.<raw-body>`, HMAC-SHA256 with the
// webhook secret. Compare the v1 signature.
// -----------------------------------------------------------------------------

async function verifyStripeSignature(
  rawBody: string,
  sigHeader: string,
  secret: string,
): Promise<boolean> {
  try {
    const parts = sigHeader.split(',').map((s) => s.trim());
    let timestamp = '';
    const signatures: string[] = [];
    for (const p of parts) {
      const [k, v] = p.split('=');
      if (k === 't') timestamp = v;
      if (k === 'v1' && v) signatures.push(v);
    }
    if (!timestamp || signatures.length === 0) return false;

    const signedPayload = `${timestamp}.${rawBody}`;
    const expected = await hmacSha256Hex(secret, signedPayload);
    for (const sig of signatures) {
      if (timingSafeEqual(sig, expected)) return true;
    }
    return false;
  } catch (e) {
    console.error('stripe_webhook: signature verify threw', e);
    return false;
  }
}

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
