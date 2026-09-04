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
      // Same reason as startSubscription's catch — invoke() throws
      // FunctionException for non-2xx responses, so the status-based
      // 404 branch further down never runs on a missing function.
      final msg = e.toString();
      if (msg.contains('status: 404') || msg.contains('NOT_FOUND')) {
        throw Exception(
          'XP purchases are being upgraded on our end. Please try again '
          'in a few minutes or contact support if this persists.',
        );
      }
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
      // 404 = Edge Function not deployed on this Supabase project.
      // Give a message the user can act on rather than a raw
      // "NOT_FOUND: Requested function was not found" gRPC detail.
      if (status == 404) {
        throw Exception(
          'XP purchases are being upgraded on our end. Please try again '
          'in a few minutes or contact support if this persists.',
        );
      }
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

  /// Subscription-upgrade payment. Mirrors [startPurchase] but talks to
  /// the sibling Edge Functions `subscription_create_order` +
  /// `subscription_verify` which write to `subscription_orders` and
  /// grant `profiles.subscription_tier` / `subscription_expires_at`
  /// instead of the XP-crediting path.
  ///
  /// Added 2026-08-30 to replace the previous web-checkout hop
  /// (`launchUrl('stepbattle.fit/upgrade')`). The web flow was
  /// vulnerable to bank OTP delivery quirks that the native SDK avoids
  /// via its in-app SMS-reader. The web hop is preserved as a fallback
  /// text link on the upgrade sheet for users on devices where the
  /// native SDK misbehaves.
  ///
  /// Returns `true` after our `subscription_verify` Edge Function has
  /// confirmed the signature + granted the tier server-side. Returns
  /// `false` if the user cancels or closes the checkout. Throws on
  /// server-side errors so the caller can surface a snackbar.
  ///
  /// [tier] must be `'pro'` or `'max'` (server-side allow-list).
  /// [period] must be `'monthly'` or `'yearly'`.
  Future<bool> startSubscription({
    required String tier,
    required String period,
    required String userId,
    String? userEmail,
    String? userName,
  }) async {
    AppLogger.payments.i('subscription:start', fields: {
      'userId': userId,
      'tier': tier,
      'period': period,
    });

    // 1. Create the order server-side. Same 15-s hard timeout pattern
    // as startPurchase so the UI can show an actionable error instead
    // of spinning if the Edge Function hangs.
    AppLogger.payments.i('subscription:invoke_create_order');
    late final dynamic orderRes;
    try {
      orderRes = await _supabase.functions
          .invoke(
            'subscription_create_order',
            body: {
              'user_id': userId,
              'tier': tier,
              'period': period,
            },
          )
          .timeout(const Duration(seconds: 15));
    } catch (e, s) {
      AppLogger.payments.e('subscription:create_order_invoke_failed',
          fields: {'err': e.toString()}, error: e, stack: s);
      // supabase_flutter's `functions.invoke` throws `FunctionException`
      // directly on non-2xx responses — the status-based 404 check
      // further down NEVER runs for 404 because we never get past this
      // catch block. Detect 404 by substring on the message (the class
      // isn't publicly imported cleanly) and swap to a user-actionable
      // message so people don't see the raw "NOT_FOUND: Requested
      // function was not found" grpc string in the sheet snackbar.
      final msg = e.toString();
      if (msg.contains('status: 404') || msg.contains('NOT_FOUND')) {
        throw Exception(
          'Payments are being upgraded on our end. Please try again in '
          'a few minutes, or use "Prefer the browser?" below to pay via '
          'the website.',
        );
      }
      throw Exception(
          "Couldn't reach the payment server. Check your connection and try again. ($e)");
    }

    AppLogger.payments.i('subscription:create_order_response', fields: {
      'status': (orderRes.status as int?) ?? -1,
      'hasData': orderRes.data != null,
    });

    final status = orderRes.status as int? ?? 0;
    if (status < 200 || status >= 300) {
      final body = orderRes.data;
      final detail = body is Map ? (body['error'] ?? body['detail']) : body;
      // 404 = Edge Function not deployed on this Supabase project (or
      // deployed under a different name). Users see this immediately
      // after cutting a build against a server that hasn't been
      // updated yet. Give them a message they can actually act on
      // instead of the raw "NOT_FOUND: Requested function was not
      // found" gRPC-style detail.
      if (status == 404) {
        throw Exception(
          'Payments are being upgraded on our end. Please try again in '
          'a few minutes, or use "Prefer the browser?" below to pay via '
          'the website.',
        );
      }
      throw Exception(
          'Payment server returned $status${detail != null ? ': $detail' : ''}');
    }

    final order = orderRes.data as Map<String, dynamic>?;
    if (order == null) {
      throw StateError('subscription_create_order returned empty response');
    }
    final orderId = order['order_id'] as String?;
    final keyId = order['key_id'] as String?;
    final amountPaise = (order['amount_paise'] as num?)?.toInt();
    if (orderId == null || keyId == null || amountPaise == null) {
      throw StateError(
          'subscription_create_order missing keys (body: $order)');
    }
    AppLogger.payments.i('subscription:order_created', fields: {
      'orderId': orderId,
      'amountPaise': amountPaise,
    });

    // 2. Launch native checkout. Same Completer + event-wiring pattern
    // as startPurchase — whichever event (success / error / dismiss)
    // fires first resolves the future.
    final razorpay = Razorpay();
    final completer = Completer<_PaymentOutcome>();
    void resolve(_PaymentOutcome o) {
      if (!completer.isCompleted) completer.complete(o);
    }

    razorpay.on(Razorpay.EVENT_PAYMENT_SUCCESS,
        (PaymentSuccessResponse r) {
      resolve(_PaymentOutcome(
        success: true,
        paymentId: r.paymentId,
        signature: r.signature,
      ));
    });
    razorpay.on(Razorpay.EVENT_PAYMENT_ERROR,
        (PaymentFailureResponse r) {
      AppLogger.payments.w('subscription:payment_error',
          fields: {'code': r.code, 'message': r.message});
      resolve(_PaymentOutcome(success: false));
    });
    razorpay.on(Razorpay.EVENT_EXTERNAL_WALLET,
        (ExternalWalletResponse _) {});

    AppLogger.payments.i('subscription:opening_checkout',
        fields: {'orderId': orderId});
    try {
      razorpay.open({
        'key': keyId,
        'order_id': orderId,
        'amount': amountPaise,
        'currency': 'INR',
        'name': 'StepBattle',
        'description':
            '${tier == 'pro' ? 'Pro' : 'Max'} · ${period == 'yearly' ? 'Yearly' : 'Monthly'} plan',
        'prefill': {
          if (userEmail != null) 'email': userEmail,
          if (userName != null) 'name': userName,
        },
        'theme': {'color': '#A855F7'},
      });
    } catch (e, s) {
      AppLogger.payments.e('subscription:open_checkout_failed',
          fields: {'err': e.toString()}, error: e, stack: s);
      razorpay.clear();
      throw Exception("Couldn't open the payment window. ($e)");
    }

    final outcome = await completer.future;
    razorpay.clear();
    if (!outcome.success ||
        outcome.paymentId == null ||
        outcome.signature == null) {
      return false;
    }

    // 3. Server-side verify + grant tier. Same 15-s timeout.
    AppLogger.payments.i('subscription:invoke_verify');
    late final dynamic verifyRes;
    try {
      verifyRes = await _supabase.functions
          .invoke(
            'subscription_verify',
            body: {
              'order_id': orderId,
              'payment_id': outcome.paymentId,
              'signature': outcome.signature,
              'user_id': userId,
            },
          )
          .timeout(const Duration(seconds: 15));
    } catch (e, s) {
      AppLogger.payments.e('subscription:verify_invoke_failed',
          fields: {'err': e.toString()}, error: e, stack: s);
      throw Exception(
          'Payment succeeded but verification failed. Your plan will activate shortly (webhook backstop). ($e)');
    }

    final vStatus = verifyRes.status as int? ?? 0;
    if (vStatus < 200 || vStatus >= 300) {
      final body = verifyRes.data;
      final detail = body is Map ? (body['error'] ?? body['detail']) : body;
      AppLogger.payments.e('subscription:verify_http_error',
          fields: {'status': vStatus, 'detail': detail?.toString()});
      throw Exception(
          'Verification failed ($vStatus${detail != null ? ': $detail' : ''})');
    }
    final verify = verifyRes.data as Map<String, dynamic>?;
    final granted = (verify?['granted'] as bool?) ?? false;
    AppLogger.payments.i('subscription:verify_result',
        fields: {'granted': granted, 'tier': verify?['tier']});
    return granted;
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
