import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:razorpay_flutter/razorpay_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../utils/app_logger.dart';

/// Razorpay payment client + server-side verification glue.
///
/// HOW IT FITS TOGETHER (full XP-purchase round trip):
///   1. UI calls [startPurchase]. We invoke a Supabase Edge Function
///      `razorpay_create_order` (TypeScript) that creates a server-side
///      order via Razorpay's REST API and inserts a row into
///      `xp_purchases` (status: 'created').
///   2. The Edge Function returns `{ order_id, key_id }`. We launch the
///      Razorpay checkout widget with that order_id.
///   3. On payment success the checkout fires the `EVENT_PAYMENT_SUCCESS`
///      stream. We POST the (order_id, payment_id, signature) triple to
///      Edge Function `razorpay_verify` which:
///         a. HMAC-verifies the signature against RAZORPAY_KEY_SECRET.
///         b. Updates the matching `xp_purchases` row to 'paid'.
///         c. Calls `credit_user_xp(user_id, xp_amount, 'purchase')`.
///   4. We re-fetch the user profile to surface the new balance.
///
/// EDGE FUNCTION SPEC (write this in `supabase/functions/`):
///   • `razorpay_create_order/index.ts`
///       INPUT  { user_id: uuid, xp_amount: int, amount_inr: int }
///       OUTPUT { order_id: string, key_id: string }
///       STEPS:
///         - reject if xp_amount < 1 or > 100_000 (sanity limit)
///         - insert into xp_purchases (status='created')
///         - POST https://api.razorpay.com/v1/orders with Basic auth
///         - return { order_id, key_id: RAZORPAY_KEY_ID }
///
///   • `razorpay_verify/index.ts`
///       INPUT  { order_id, payment_id, signature, user_id, xp_amount }
///       OUTPUT { credited: bool, new_balance: int }
///       STEPS:
///         - HMAC-SHA256(order_id|payment_id, RAZORPAY_KEY_SECRET)
///         - reject on mismatch
///         - SELECT FOR UPDATE the xp_purchases row; reject if already
///           status='paid' (idempotency guard)
///         - UPDATE xp_purchases set status='paid', payment_id, signature
///         - SELECT credit_user_xp(user_id, xp_amount, 'purchase',
///                                 jsonb_build_object('order_id', order_id))
///         - return { credited: true, new_balance: ... }
///
/// SECRETS:
///   • RAZORPAY_KEY_ID  → public (sent to client, used to launch checkout)
///   • RAZORPAY_KEY_SECRET → Edge Function env only
///
/// FAILURE MODES:
///   • Network drop after payment but before verify — payment is captured
///     by Razorpay, our verify never runs. The reconciliation job in
///     `supabase/functions/razorpay_reconcile/` (CRON, 5min) pulls
///     Razorpay's recent payments and credits any missing.
///   • Double-tap on "Pay" — the Edge Function uses xp_purchases.order_id
///     as a unique key; the second insert fails and we surface a
///     friendly error.
class RazorpayService {
  final SupabaseClient _supabase;
  RazorpayService(this._supabase);

  /// Starts a Razorpay checkout and resolves to `true` only after our
  /// `razorpay_verify` Edge Function has confirmed the signature + the
  /// XP credit. Resolves to `false` if the user cancels or closes the
  /// checkout sheet; throws on any server-side error.
  Future<bool> startPurchase({
    required int amountInr,
    required int xpAmount,
    required String userId,
    String? userEmail,
    String? userName,
  }) async {
    AppLogger.payments.i('xp_purchase:start', fields: {
      'userId': userId,
      'amountInr': amountInr,
      'xpAmount': xpAmount,
    });

    // 1. Create the order server-side. Hard timeout (15s) so a hung
    // request fails fast and the UI can show an actionable error
    // instead of spinning indefinitely.
    AppLogger.payments.i('xp_purchase:invoke_create_order');
    late final dynamic orderRes;
    try {
      orderRes = await _supabase.functions
          .invoke(
            'razorpay_create_order',
            body: {
              'user_id': userId,
              'xp_amount': xpAmount,
              'amount_inr': amountInr,
            },
          )
          .timeout(const Duration(seconds: 15));
    } catch (e, s) {
      AppLogger.payments.e('xp_purchase:create_order_invoke_failed',
          fields: {'err': e.toString()}, error: e, stack: s);
      throw Exception(
          'Couldn\'t reach the payment server. Check your connection and try again. ($e)');
    }

    AppLogger.payments.i('xp_purchase:create_order_response', fields: {
      'status': (orderRes.status as int?) ?? -1,
      'hasData': orderRes.data != null,
      'dataType': orderRes.data?.runtimeType.toString() ?? 'null',
    });

    // The supabase-flutter client returns a FunctionResponse with both
    // data and status. A non-2xx status doesn't always throw — surface
    // it explicitly so 400/500 from the Edge Function reaches the user.
    final status = orderRes.status as int? ?? 0;
    if (status < 200 || status >= 300) {
      final body = orderRes.data;
      final detail = body is Map ? (body['error'] ?? body['detail']) : body;
      throw Exception(
          'Payment server returned $status${detail != null ? ': $detail' : ''}');
    }

    final order = orderRes.data as Map<String, dynamic>?;
    if (order == null) {
      throw StateError('razorpay_create_order returned empty response');
    }
    final orderId = order['order_id'] as String?;
    final keyId = order['key_id'] as String?;
    if (orderId == null || keyId == null) {
      throw StateError(
          'razorpay_create_order missing keys (body: $order)');
    }
    AppLogger.payments
        .i('xp_purchase:order_created', fields: {'orderId': orderId});

    // 2. Launch checkout. We resolve a single Completer from whichever
    //    event fires first — success / error / dismiss.
    final razorpay = Razorpay();
    final completer = Completer<_PaymentOutcome>();
    void resolve(_PaymentOutcome o) {
      if (!completer.isCompleted) completer.complete(o);
    }

    razorpay.on(Razorpay.EVENT_PAYMENT_SUCCESS, (PaymentSuccessResponse r) {
      resolve(_PaymentOutcome(
        success: true,
        paymentId: r.paymentId,
        signature: r.signature,
      ));
    });
    razorpay.on(Razorpay.EVENT_PAYMENT_ERROR, (PaymentFailureResponse r) {
      AppLogger.payments.w('xp_purchase:payment_error',
          fields: {'code': r.code, 'message': r.message});
      resolve(_PaymentOutcome(success: false));
    });
    razorpay.on(Razorpay.EVENT_EXTERNAL_WALLET, (ExternalWalletResponse _) {
      // External-wallet flow handled in-app by Razorpay; nothing to do.
    });

    AppLogger.payments
        .i('xp_purchase:opening_checkout', fields: {'orderId': orderId});
    try {
      razorpay.open({
        'key': keyId,
        'order_id': orderId,
        'amount': amountInr * 100, // Razorpay expects paise.
        'currency': 'INR',
        'name': 'StepBattle',
        'description': '$xpAmount XP top-up',
        'prefill': {
          if (userEmail != null) 'email': userEmail,
          if (userName != null) 'name': userName,
        },
        'theme': {'color': '#A855F7'}, // AppColors.primary
      });
    } catch (e, s) {
      AppLogger.payments.e('xp_purchase:open_checkout_failed',
          fields: {'err': e.toString()}, error: e, stack: s);
      razorpay.clear();
      throw Exception('Couldn\'t open the payment window. ($e)');
    }

    final outcome = await completer.future;
    razorpay.clear();
    if (!outcome.success ||
        outcome.paymentId == null ||
        outcome.signature == null) {
      return false;
    }

    // 3. Server-side verify + credit. Same timeout treatment.
    AppLogger.payments.i('xp_purchase:invoke_verify');
    late final dynamic verifyRes;
    try {
      verifyRes = await _supabase.functions
          .invoke(
            'razorpay_verify',
            body: {
              'order_id': orderId,
              'payment_id': outcome.paymentId,
              'signature': outcome.signature,
              'user_id': userId,
              'xp_amount': xpAmount,
            },
          )
          .timeout(const Duration(seconds: 15));
    } catch (e, s) {
      AppLogger.payments.e('xp_purchase:verify_invoke_failed',
          fields: {'err': e.toString()}, error: e, stack: s);
      throw Exception(
          'Payment succeeded but verification failed. XP will be credited shortly. ($e)');
    }

    final vStatus = verifyRes.status as int? ?? 0;
    if (vStatus < 200 || vStatus >= 300) {
      final body = verifyRes.data;
      final detail = body is Map ? (body['error'] ?? body['detail']) : body;
      AppLogger.payments.e('xp_purchase:verify_http_error',
          fields: {'status': vStatus, 'detail': detail?.toString()});
      throw Exception(
          'Verification failed ($vStatus${detail != null ? ': $detail' : ''})');
    }
    final verify = verifyRes.data as Map<String, dynamic>?;
    final credited = (verify?['credited'] as bool?) ?? false;
    AppLogger.payments
        .i('xp_purchase:verify_result', fields: {'credited': credited});
    return credited;
  }
}

class _PaymentOutcome {
  final bool success;
  final String? paymentId;
  final String? signature;
  _PaymentOutcome({
    required this.success,
    this.paymentId,
    this.signature,
  });
}

/// Riverpod provider — the Buy-XP sheet reads this via `ref.read`.
final razorpayServiceProvider = Provider<RazorpayService>((ref) {
  return RazorpayService(Supabase.instance.client);
});
