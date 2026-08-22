import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Payment gateway the Buy XP flow should use. Read once per app run
/// from the `PAYMENT_PROVIDER` env var, defaults to `razorpay` (the
/// legacy provider that shipped in v1.0.1+8).
///
/// Values:
///   * `razorpay` (default) — India-native, ~2% MDR, native UPI.
///     Requires an Indian merchant account. INR-only.
///   * `stripe`             — Global multi-currency. Requires Stripe
///     account (India or global). INR + USD + EUR + GBP + AUD.
///
/// The two providers do NOT coexist in a single build — this flag picks
/// exactly one. Both sets of client code + Edge Functions stay alive
/// so a hot-swap between builds is safe.
///
/// To flip: edit `.env`, change `PAYMENT_PROVIDER=stripe`, rebuild the
/// AAB. No Play declaration changes needed either way.
enum PaymentProvider {
  razorpay,
  stripe;

  static PaymentProvider fromEnv() {
    final raw = (dotenv.env['PAYMENT_PROVIDER'] ?? 'razorpay').trim().toLowerCase();
    return switch (raw) {
      'stripe' => PaymentProvider.stripe,
      _ => PaymentProvider.razorpay,
    };
  }
}

final paymentProviderProvider = Provider<PaymentProvider>((ref) {
  return PaymentProvider.fromEnv();
});
