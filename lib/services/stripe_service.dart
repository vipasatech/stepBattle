import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_stripe/flutter_stripe.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/pricing.dart';
import '../utils/app_logger.dart';

/// Stripe payment client + server-side verification glue. Mirrors the
/// API shape of [RazorpayService] so the Buy XP sheet can route through
/// either provider based on the PAYMENT_PROVIDER feature flag.
///
/// FLOW (end-to-end):
///   1. UI calls [startPurchase] with (xpAmount, currency, userId).
///   2. We invoke Supabase Edge Function `stripe_create_payment_intent`
///      which validates the tier/currency/amount against its own
///      pricing table (anti-tampering), creates a Stripe PaymentIntent,
///      inserts an `xp_purchases` row with status='created', and
///      returns `{ client_secret, payment_intent_id, publishable_key }`.
///   3. We initialise Stripe.publishableKey (once per app run) and
///      launch the `PaymentSheet` with the returned client_secret.
///   4. Stripe processes the payment. On success the sheet resolves.
///   5. Stripe fires a `payment_intent.succeeded` webhook to our
///      `stripe_webhook` Edge Function which credits XP via
///      `credit_user_xp`. The client also polls the profile once to
///      refresh the visible XP balance quickly.
///
/// FAILURE MODES:
///   * Network drop after payment but before webhook — payment is
///     captured server-side, webhook fires from Stripe's side within
///     seconds. Client UI still shows the celebration overlay because
///     Stripe's PaymentSheet resolves as soon as the PaymentIntent
///     status flips to `succeeded`.
///   * User cancels the sheet — throws `StripeException` with
///     `FailureCode.Canceled`; we return `false`.
///   * Payment declined — throws `StripeException` with a decline code;
///     we re-throw a friendlier message.
class StripeService {
  final SupabaseClient _supabase;
  bool _stripeInitialised = false;

  StripeService(this._supabase);

  /// Starts a Stripe checkout and resolves to `true` when the payment
  /// succeeds. `false` for user-cancel; throws Exception for anything
  /// else so the UI can surface a message.
  Future<bool> startPurchase({
    required int xpAmount,
    required PriceCurrency currency,
    required String userId,
    String? userEmail,
    String? userName,
  }) async {
    AppLogger.payments.i('stripe:start', fields: {
      'userId': userId,
      'xpAmount': xpAmount,
      'currency': currency.code,
    });

    final tier = priceTierFor(xpAmount);
    if (tier == null) {
      throw Exception('Unsupported XP tier: $xpAmount');
    }
    final amountMinor = tier.minorFor(currency);

    // 1. Ask the Edge Function for a PaymentIntent.
    AppLogger.payments.i('stripe:invoke_create_intent');
    late final dynamic intentRes;
    try {
      intentRes = await _supabase.functions
          .invoke(
            'stripe_create_payment_intent',
            body: {
              'user_id': userId,
              'xp_amount': xpAmount,
              'amount_minor': amountMinor,
              'currency': currency.code.toLowerCase(),
            },
          )
          .timeout(const Duration(seconds: 15));
    } catch (e, s) {
      AppLogger.payments.e('stripe:create_intent_invoke_failed',
          fields: {'err': e.toString()}, error: e, stack: s);
      throw Exception(
          "Couldn't reach the payment server. Check your connection and try again.");
    }

    final status = intentRes.status as int? ?? 0;
    if (status < 200 || status >= 300) {
      final body = intentRes.data;
      final detail = body is Map ? (body['error'] ?? body['detail']) : body;
      throw Exception(
          'Payment server returned $status${detail != null ? ': $detail' : ''}');
    }
    final payload = intentRes.data as Map<String, dynamic>?;
    final clientSecret = payload?['client_secret'] as String?;
    final publishableKey = payload?['publishable_key'] as String?;
    final paymentIntentId = payload?['payment_intent_id'] as String?;
    if (clientSecret == null || publishableKey == null || paymentIntentId == null) {
      throw StateError('stripe_create_payment_intent missing fields');
    }
    AppLogger.payments.i('stripe:intent_created',
        fields: {'paymentIntentId': paymentIntentId});

    // 2. Init Stripe SDK once per app run. Publishable key comes from
    // the server so we can rotate without re-shipping the client.
    if (!_stripeInitialised) {
      Stripe.publishableKey = publishableKey;
      await Stripe.instance.applySettings();
      _stripeInitialised = true;
    }

    // 3. Launch the PaymentSheet.
    try {
      await Stripe.instance.initPaymentSheet(
        paymentSheetParameters: SetupPaymentSheetParameters(
          paymentIntentClientSecret: clientSecret,
          merchantDisplayName: 'StepBattle',
          billingDetails: BillingDetails(
            email: userEmail,
            name: userName,
          ),
        ),
      );
      await Stripe.instance.presentPaymentSheet();
    } on StripeException catch (e) {
      final code = e.error.code;
      if (code == FailureCode.Canceled) {
        AppLogger.payments.i('stripe:user_cancelled');
        return false;
      }
      AppLogger.payments.w('stripe:payment_error',
          fields: {'code': code.toString(), 'message': e.error.message});
      throw Exception(e.error.localizedMessage ?? 'Payment failed');
    }

    // 4. Sheet returned success — the webhook has either already
    // credited or will within seconds. Return true so the UI shows
    // the celebration overlay immediately; the balance refresh below
    // is fire-and-forget.
    AppLogger.payments.i('stripe:payment_success',
        fields: {'paymentIntentId': paymentIntentId});
    return true;
  }
}

/// Riverpod provider — the Buy-XP sheet reads this via `ref.read`.
final stripeServiceProvider = Provider<StripeService>((ref) {
  return StripeService(Supabase.instance.client);
});
