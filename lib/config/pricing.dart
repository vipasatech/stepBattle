/// XP-purchase pricing catalog — the CLIENT-SIDE source of truth for
/// what a given (xp tier, currency) costs.
///
/// This MUST stay in sync with the same table in the server-side
/// Stripe Edge Function (`supabase/functions/stripe_create_payment_intent`).
/// The server rejects any (xp_amount, amount_minor, currency) triple
/// that doesn't match its own copy — that's the anti-tampering guarantee.
///
/// If you change a price here, change the server copy in the same
/// commit. There is currently no automated parity check; if this
/// bites us we'll add a build-time script.
library;

/// Supported currencies, ISO 4217 three-letter codes.
enum PriceCurrency {
  inr('INR', '₹', 'India'),
  usd('USD', '\$', 'United States'),
  eur('EUR', '€', 'Europe'),
  gbp('GBP', '£', 'United Kingdom'),
  aud('AUD', 'A\$', 'Australia');

  final String code;
  final String symbol;
  final String regionLabel;
  const PriceCurrency(this.code, this.symbol, this.regionLabel);

  /// Locale country-code → currency mapping used for auto-detection
  /// on first launch. Falls back to USD for unknown regions.
  static PriceCurrency fromCountryCode(String? cc) {
    if (cc == null) return usd;
    switch (cc.toUpperCase()) {
      case 'IN':
        return inr;
      case 'US':
      case 'CA':
      case 'MX':
        return usd;
      case 'GB':
      case 'UK':
        return gbp;
      case 'AU':
      case 'NZ':
        return aud;
      case 'DE':
      case 'FR':
      case 'IT':
      case 'ES':
      case 'NL':
      case 'BE':
      case 'AT':
      case 'PT':
      case 'FI':
      case 'IE':
      case 'GR':
      case 'LU':
      case 'SK':
      case 'SI':
      case 'EE':
      case 'LT':
      case 'LV':
      case 'CY':
      case 'MT':
        return eur;
      default:
        return usd;
    }
  }

  /// Format a minor-unit amount (paise / cents / pence) as a
  /// user-facing string. INR skips the decimal since Indian XP tiers
  /// are round rupees; other currencies show two decimals.
  String formatMinor(int minor) {
    if (this == PriceCurrency.inr) {
      // paise → whole rupees. Comma-separated Indian style.
      final rupees = minor ~/ 100;
      return '$symbol${_indianComma(rupees)}';
    }
    // Two-decimal Western style with thousands separator.
    final whole = minor ~/ 100;
    final cents = minor % 100;
    return '$symbol${_westernComma(whole)}.${cents.toString().padLeft(2, '0')}';
  }

  static String _indianComma(int n) {
    final s = n.toString();
    if (s.length <= 3) return s;
    final lastThree = s.substring(s.length - 3);
    final rest = s.substring(0, s.length - 3);
    // Group the "rest" in twos from the right — Indian lakh/crore style.
    final buf = StringBuffer();
    for (int i = 0; i < rest.length; i++) {
      buf.write(rest[i]);
      final remaining = rest.length - i - 1;
      if (remaining > 0 && remaining % 2 == 0) buf.write(',');
    }
    return '$buf,$lastThree';
  }

  static String _westernComma(int n) {
    final s = n.toString();
    final buf = StringBuffer();
    for (int i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
      buf.write(s[i]);
    }
    return buf.toString();
  }
}

/// Pricing rows — one per (xpAmount, currency) tier. Amounts stored in
/// the currency's smallest unit (paise, cents, pence).
class PriceTier {
  final int xpAmount;
  final Map<PriceCurrency, int> minorByCurrency;
  const PriceTier(this.xpAmount, this.minorByCurrency);

  int minorFor(PriceCurrency c) {
    final v = minorByCurrency[c];
    if (v == null) {
      throw StateError(
          'PriceTier($xpAmount) missing price for ${c.code} — update pricing.dart');
    }
    return v;
  }
}

/// Master tier list. Same six tiers as the original Razorpay flow, now
/// with prices per supported currency.
///
/// **CRITICAL: mirror any change here in
/// `supabase/functions/stripe_create_payment_intent/index.ts` (the
/// `PRICING` constant).** The server rejects mismatched (xp, amount,
/// currency) triples.
const List<PriceTier> kXpPriceTiers = [
  PriceTier(100, {
    PriceCurrency.inr: 10000,   // ₹100
    PriceCurrency.usd: 199,     // $1.99
    PriceCurrency.eur: 179,     // €1.79
    PriceCurrency.gbp: 149,     // £1.49
    PriceCurrency.aud: 299,     // A$2.99
  }),
  PriceTier(500, {
    PriceCurrency.inr: 50000,
    PriceCurrency.usd: 699,
    PriceCurrency.eur: 649,
    PriceCurrency.gbp: 549,
    PriceCurrency.aud: 999,
  }),
  PriceTier(1000, {
    PriceCurrency.inr: 100000,
    PriceCurrency.usd: 1299,
    PriceCurrency.eur: 1199,
    PriceCurrency.gbp: 999,
    PriceCurrency.aud: 1899,
  }),
  PriceTier(2500, {
    PriceCurrency.inr: 250000,
    PriceCurrency.usd: 2999,
    PriceCurrency.eur: 2799,
    PriceCurrency.gbp: 2499,
    PriceCurrency.aud: 4499,
  }),
  PriceTier(5000, {
    PriceCurrency.inr: 500000,
    PriceCurrency.usd: 5499,
    PriceCurrency.eur: 4999,
    PriceCurrency.gbp: 4499,
    PriceCurrency.aud: 7999,
  }),
  PriceTier(10000, {
    PriceCurrency.inr: 1000000,
    PriceCurrency.usd: 9999,
    PriceCurrency.eur: 8999,
    PriceCurrency.gbp: 7999,
    PriceCurrency.aud: 14999,
  }),
];

/// Look up a tier by XP amount. Returns null if it's not a known tier —
/// caller must handle (custom amounts aren't supported in the Stripe
/// flow because the anti-tampering check needs a matching tier).
PriceTier? priceTierFor(int xpAmount) {
  for (final t in kXpPriceTiers) {
    if (t.xpAmount == xpAmount) return t;
  }
  return null;
}
