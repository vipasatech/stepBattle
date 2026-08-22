// razorpay_webhook — server-of-record for payment lifecycle events.
//
// HTTP:        POST /functions/v1/razorpay_webhook
// Auth:        NONE from Supabase (Razorpay has no JWT). Authenticity is
//              verified via HMAC-SHA256 of the raw body against
//              RAZORPAY_WEBHOOK_SECRET (a value we set both in the
//              Razorpay dashboard on the webhook AND as a Supabase
//              Edge Function secret). This function is registered with
//              `verify_jwt = false` in supabase/config.toml.
//
// Handles these events (register these on the Razorpay dashboard):
//   • payment.captured  — money moved; credit XP if not yet credited
//                          (idempotent vs the client-side verify path).
//   • payment.failed    — order attempt failed; mark xp_purchases failed.
//   • refund.processed  — refund settled; debit XP + flip to refunded.
//
// FAILURE / RETRY BEHAVIOUR
//   Razorpay retries a webhook up to ~24h on non-2xx. So on any
//   transient DB error we return 500 to force a retry; on unknown
//   events or already-idempotent no-ops we return 200 so Razorpay
//   marks the delivery done.
//
// SECRETS (Supabase → Edge Functions → Secrets):
//   • RAZORPAY_WEBHOOK_SECRET   (distinct from RAZORPAY_KEY_SECRET)
// AUTO-INJECTED:
//   • SUPABASE_URL
//   • SUPABASE_SERVICE_ROLE_KEY  (bypasses RLS)

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.0';

interface WebhookPayload {
  event?: string;
  payload?: {
    payment?: { entity?: PaymentEntity };
    refund?:  { entity?: RefundEntity  };
  };
}

interface PaymentEntity {
  id?: string;
  order_id?: string;
  amount?: number;         // paise
  status?: string;
  error_code?: string;
  error_description?: string;
}

interface RefundEntity {
  id?: string;
  payment_id?: string;
  amount?: number;         // paise
  status?: string;
}

Deno.serve(async (req) => {
  // Razorpay only ever POSTs. Any other method is either a browser hitting
  // the URL by mistake or a probe — respond 405.
  if (req.method !== 'POST') {
    return new Response('Method Not Allowed', { status: 405 });
  }

  const secret = Deno.env.get('RAZORPAY_WEBHOOK_SECRET');
  if (!secret) {
    console.error('razorpay_webhook: RAZORPAY_WEBHOOK_SECRET not configured');
    return new Response('secret_missing', { status: 500 });
  }

  // MUST read the raw body BEFORE parsing JSON — HMAC is computed over the
  // exact bytes Razorpay sent, not the pretty-printed re-serialization.
  const rawBody = await req.text();
  const signature = req.headers.get('X-Razorpay-Signature') ?? '';
  if (!signature) {
    console.warn('razorpay_webhook: missing X-Razorpay-Signature');
    return new Response('missing_signature', { status: 401 });
  }

  const expected = await hmacSha256Hex(secret, rawBody);
  if (!timingSafeEqual(expected, signature)) {
    console.warn('razorpay_webhook: signature mismatch');
    return new Response('signature_mismatch', { status: 401 });
  }

  let body: WebhookPayload;
  try {
    body = JSON.parse(rawBody) as WebhookPayload;
  } catch (_) {
    // Signature already verified so this is Razorpay sending garbage,
    // extremely unlikely. Log and 200 so they don't retry forever.
    console.error('razorpay_webhook: body not JSON despite valid signature');
    return new Response('ok', { status: 200 });
  }

  const supabase = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
  );

  const event = body.event ?? '';
  try {
    switch (event) {
      case 'payment.captured':
        return await handlePaymentCaptured(supabase, body);
      case 'payment.failed':
        return await handlePaymentFailed(supabase, body);
      case 'refund.processed':
      case 'refund.created':  // some accounts emit created before processed
        return await handleRefund(supabase, body);
      default:
        // Unknown / uninteresting event (order.paid, etc.). Ack so
        // Razorpay stops retrying.
        console.log('razorpay_webhook: ignoring event', event);
        return new Response('ok', { status: 200 });
    }
  } catch (e) {
    // Something failed unexpectedly — 500 so Razorpay retries. This is
    // the only path that shouldn't return 200; every business-logic
    // no-op ends in 200 above.
    console.error('razorpay_webhook: handler crash', event, e);
    return new Response('handler_crash', { status: 500 });
  }
});

// -----------------------------------------------------------------------------
// Handlers
// -----------------------------------------------------------------------------

// deno-lint-ignore no-explicit-any
async function handlePaymentCaptured(supabase: any, body: WebhookPayload) {
  const p = body.payload?.payment?.entity;
  if (!p?.order_id || !p?.id) {
    return new Response('ok', { status: 200 });
  }

  const { data: purchase, error: selErr } = await supabase
    .from('xp_purchases')
    .select('id, user_id, xp_credited, status')
    .eq('razorpay_order_id', p.order_id)
    .maybeSingle();

  if (selErr) throw selErr;
  if (!purchase) {
    // No reservation row for this order — could be a stray webhook (test
    // event, other product on the same Razorpay account, etc.). Ack and
    // move on.
    console.warn('razorpay_webhook: no xp_purchases row for order', p.order_id);
    return new Response('ok', { status: 200 });
  }

  if (purchase.status === 'captured') {
    // Client's verify path (or a prior webhook delivery) already credited.
    // Idempotent — nothing to do.
    return new Response('ok', { status: 200 });
  }
  if (purchase.status !== 'created') {
    // 'failed' or 'refunded' — do not credit.
    return new Response('ok', { status: 200 });
  }

  // Optimistic concurrency: only proceed if the row is still in 'created'
  // when we write. If the client-side verify races us, one of the two will
  // find status != 'created' and back off.
  const { error: updErr, count } = await supabase
    .from('xp_purchases')
    .update({
      status: 'captured',
      razorpay_payment_id: p.id,
      captured_at: new Date().toISOString(),
    }, { count: 'exact' })
    .eq('id', purchase.id)
    .eq('status', 'created');
  if (updErr) throw updErr;
  if (!count) {
    // Someone else got there first — done.
    return new Response('ok', { status: 200 });
  }

  const { data: newBalance, error: credErr } = await supabase.rpc(
    'credit_user_xp',
    {
      p_user_id: purchase.user_id,
      p_delta:   purchase.xp_credited,
      p_reason:  'purchase',
      p_context: { order_id: p.order_id, payment_id: p.id, via: 'webhook' },
    },
  );
  if (credErr) {
    // Roll status back so we retry on the next delivery.
    await supabase
      .from('xp_purchases')
      .update({ status: 'created', captured_at: null })
      .eq('id', purchase.id);
    throw credErr;
  }

  console.log('razorpay_webhook: credited', {
    order_id: p.order_id,
    payment_id: p.id,
    user_id: purchase.user_id,
    xp: purchase.xp_credited,
  });

  // Fire the "XP added to your wallet" push. INSERT on
  // public.notifications triggers the send-push edge function
  // automatically via migration 0009's trigger — no direct FCM call
  // needed here.
  //
  // Wrapped in try/catch so a transient notification failure NEVER
  // rolls back the payment. The user has already been charged and
  // credited — they just miss the push (still see the in-app bell
  // badge next open). We log so we can spot-repair via Supabase logs.
  try {
    await supabase.from('notifications').insert({
      user_id: purchase.user_id,
      type:    'purchase_completed',
      title:   '💰 XP added to your wallet',
      body:
        '+' + Number(purchase.xp_credited).toLocaleString('en-IN') +
        ' XP credited. New balance: ' +
        Number(newBalance ?? 0).toLocaleString('en-IN') + '.',
      data: {
        xp_credited:       purchase.xp_credited,
        order_id:          purchase.id,
        payment_id:        p.id,
        razorpay_order_id: p.order_id,
        new_balance:       newBalance,
      },
    });
  } catch (notifErr) {
    console.warn(
      'razorpay_webhook: purchase notification failed (non-fatal)',
      notifErr,
    );
  }

  return new Response('ok', { status: 200 });
}

// deno-lint-ignore no-explicit-any
async function handlePaymentFailed(supabase: any, body: WebhookPayload) {
  const p = body.payload?.payment?.entity;
  if (!p?.order_id) return new Response('ok', { status: 200 });

  const { error } = await supabase
    .from('xp_purchases')
    .update({
      status: 'failed',
      failure_reason: p.error_description ?? p.error_code ?? 'razorpay_failed',
    })
    .eq('razorpay_order_id', p.order_id)
    .eq('status', 'created');
  if (error) throw error;
  return new Response('ok', { status: 200 });
}

// deno-lint-ignore no-explicit-any
async function handleRefund(supabase: any, body: WebhookPayload) {
  const r = body.payload?.refund?.entity;
  const p = body.payload?.payment?.entity;
  if (!r?.payment_id) return new Response('ok', { status: 200 });

  const { data: purchase, error: selErr } = await supabase
    .from('xp_purchases')
    .select('id, user_id, xp_credited, status')
    .eq('razorpay_payment_id', r.payment_id)
    .maybeSingle();
  if (selErr) throw selErr;
  if (!purchase) {
    console.warn('razorpay_webhook: no xp_purchases row for refund',
      r.payment_id);
    return new Response('ok', { status: 200 });
  }
  if (purchase.status === 'refunded') {
    return new Response('ok', { status: 200 });
  }
  if (purchase.status !== 'captured') {
    // Refunding a non-captured purchase shouldn't happen; ack + log.
    console.warn('razorpay_webhook: refund on non-captured purchase',
      { id: purchase.id, status: purchase.status });
    return new Response('ok', { status: 200 });
  }

  // Compute XP to claw back. Partial refunds: Razorpay's `refund.amount`
  // is in paise; we mapped 1 paise → 1/100 XP originally (rate ₹1 = 1 XP,
  // amount was in paise). For a full refund, `r.amount === p.amount`.
  // For a partial, claw back the proportional XP.
  const refundPaise = r.amount ?? 0;
  const originalPaise = p?.amount ?? 0;
  let xpToClawback = purchase.xp_credited;
  if (refundPaise > 0 && originalPaise > 0 && refundPaise < originalPaise) {
    xpToClawback = Math.floor(
      (refundPaise / originalPaise) * purchase.xp_credited,
    );
  }
  if (xpToClawback <= 0) {
    return new Response('ok', { status: 200 });
  }

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

  const { data: newBalance, error: credErr } = await supabase.rpc(
    'credit_user_xp',
    {
      p_user_id: purchase.user_id,
      p_delta:   -xpToClawback,
      p_reason:  'purchase_refund',
      p_context: {
        order_id:   purchase.id,
        refund_id:  r.id,
        payment_id: r.payment_id,
      },
    },
  );
  if (credErr) {
    await supabase
      .from('xp_purchases')
      .update({ status: 'captured', refunded_at: null })
      .eq('id', purchase.id);
    throw credErr;
  }

  console.log('razorpay_webhook: refunded', {
    payment_id: r.payment_id,
    user_id:    purchase.user_id,
    xp:         -xpToClawback,
  });

  // Fire "Refund processed" push. Trust matters — the user's card
  // was charged and now the server has acknowledged the refund. Money
  // itself reaches their bank in 2-7 business days (varies by rail),
  // so we set that expectation in the body. Same non-fatal-catch
  // pattern as the capture path above.
  try {
    const refundInr = (refundPaise / 100).toLocaleString('en-IN');
    await supabase.from('notifications').insert({
      user_id: purchase.user_id,
      type:    'purchase_refunded',
      title:   '↩ Refund processed',
      body:
        '₹' + refundInr + ' refund initiated. Money reaches your bank in 2-7 business days. Balance: ' +
        Number(newBalance ?? 0).toLocaleString('en-IN') + ' XP.',
      data: {
        order_id:   purchase.id,
        refund_id:  r.id,
        payment_id: r.payment_id,
        xp_debited: xpToClawback,
        amount_inr: refundPaise / 100,
        new_balance: newBalance,
      },
    });
  } catch (notifErr) {
    console.warn(
      'razorpay_webhook: refund notification failed (non-fatal)',
      notifErr,
    );
  }

  return new Response('ok', { status: 200 });
}

// -----------------------------------------------------------------------------
// Crypto helpers (same as razorpay_verify — duplicated for module isolation)
// -----------------------------------------------------------------------------

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
