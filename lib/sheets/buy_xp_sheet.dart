import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/colors.dart';
import '../config/pricing.dart';
import '../providers/auth_provider.dart';
import '../providers/currency_provider.dart';
import '../providers/payment_provider_provider.dart';
import '../services/razorpay_service.dart';
import '../services/stripe_service.dart';
import '../utils/network_errors.dart';
import '../widgets/bottom_sheet_handle.dart';
import '../widgets/no_network_sheet.dart';
import '../widgets/xp_purchase_celebration.dart';
import 'xp_history_sheet.dart';

/// Buy-XP bottom sheet — ₹1 → 1 XP.
///
/// Surfaces preset packs (100 / 500 / 1000 / 2500 / 5000 / 10000 XP) and
/// kicks off the Razorpay checkout via [RazorpayService.startPurchase].
/// On payment success the server-side Edge Function verifies the signature
/// and credits the user's `profiles.total_xp` via `credit_user_xp` — see
/// migration 0016 + the `razorpay_verify` Edge Function spec in
/// `supabase/functions/razorpay_verify/README.md`.
///
/// Why Razorpay over Google Play Billing:
///   • Razorpay: ~2% MDR vs Play's 15–30% take.
///   • UPI native — most Indian users prefer it.
///   • GST compliance + automated INR receipts built in.
///   • CCI's India carve-out lets us bill outside Play for skill-game
///     currency (we are a fitness app, not gambling) — see Anthropic
///     guidance in CLAUDE.md for the legal note.
class BuyXpSheet extends ConsumerStatefulWidget {
  const BuyXpSheet({super.key});

  @override
  ConsumerState<BuyXpSheet> createState() => _BuyXpSheetState();
}

class _BuyXpSheetState extends ConsumerState<BuyXpSheet> {
  /// Preset packs (in INR / XP — they're equal so one int per pack works).
  static const _packs = [100, 500, 1000, 2500, 5000, 10000];

  /// Hard server-side cap on `amount_inr` — mirrors the Edge Function's
  /// validation (1 â‰¤ amount â‰¤ 100,000). The custom-input field is
  /// silently clamped to this range so the user never sends an invalid
  /// amount and gets a server rejection.
  static const int _maxXp = 100000;
  static const int _minXp = 100;

  int _selected = 500;
  bool _processing = false;
  String? _error;

  /// Validation error for the custom-amount TextField. Non-null when the
  /// user's typed value is outside [_minXp, _maxXp]. When set, the pay
  /// button is disabled AND the field renders in error state so the user
  /// sees exactly what's wrong instead of the previous silent-clamp
  /// behaviour that changed ₹10 → ₹100 without telling them.
  String? _customError;

  final _customController = TextEditingController();
  final _customFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    // Keep the custom-input visually in sync with preset taps — when the
    // user picks a preset card the input clears so they're not confused
    // about which value will be charged.
    _customController.addListener(_onCustomChanged);
  }

  @override
  void dispose() {
    _customController.removeListener(_onCustomChanged);
    _customController.dispose();
    _customFocus.dispose();
    super.dispose();
  }

  void _onCustomChanged() {
    final raw = _customController.text.trim();
    // Empty input → fall back to the preset selection. No error state;
    // the button re-enables and shows the preset price.
    if (raw.isEmpty) {
      if (_customError != null) setState(() => _customError = null);
      return;
    }
    final parsed = int.tryParse(raw);
    if (parsed == null) {
      if (_customError != 'Enter a whole rupee amount') {
        setState(() => _customError = 'Enter a whole rupee amount');
      }
      return;
    }
    // Below-min / above-max → surface an explicit error instead of the
    // silent .clamp() we used to do. The user typed ₹10 and expected
    // to see WHY it wouldn't proceed, not have ₹100 charged in place.
    if (parsed < _minXp) {
      setState(() => _customError = 'Minimum is ₹${_fmt(_minXp)}');
      return;
    }
    if (parsed > _maxXp) {
      setState(() => _customError = 'Maximum is ₹${_fmt(_maxXp)}');
      return;
    }
    // Valid input — commit to _selected and clear any error.
    setState(() {
      _selected = parsed;
      _customError = null;
    });
  }

  void _pickPreset(int amount) {
    setState(() {
      _selected = amount;
      // Tapping a preset invalidates any pending custom-input error;
      // the preset amount is by definition within range.
      _customError = null;
    });
    // Clear the custom field so the UI doesn't show two competing values.
    _customController.clear();
    _customFocus.unfocus();
  }

  Future<void> _checkout() async {
    final me = ref.read(currentUserProvider).valueOrNull;
    if (me == null) return;

    // Capture navigators / messengers BEFORE the async gap so we can
    // safely fire the celebration + error surfaces after the sheet's
    // own `context` may have been torn down by pop().
    final rootNavigator = Navigator.of(context, rootNavigator: true);
    final messenger = ScaffoldMessenger.of(context);

    setState(() {
      _processing = true;
      _error = null;
    });
    try {
      // Route via the PAYMENT_PROVIDER feature flag. Both providers
      // ship in every build so we can flip via .env without a code
      // change; the server-side Edge Functions for both stay alive so
      // in-flight purchases on old clients continue to settle.
      final provider = ref.read(paymentProviderProvider);
      final bool ok;
      if (provider == PaymentProvider.stripe) {
        final currency = ref.read(selectedCurrencyProvider);
        ok = await ref.read(stripeServiceProvider).startPurchase(
              xpAmount: _selected,
              currency: currency,
              userId: me.userId,
              userEmail: me.email,
              userName: me.displayName,
            );
      } else {
        // Razorpay path — India-native, INR-only.
        // 1. Edge Function `razorpay_create_order` creates a server-side
        //    order (returns order_id).
        // 2. We launch the Razorpay checkout with that order_id.
        // 3. On success Razorpay calls our Edge Function `razorpay_verify`
        //    with the signature; verify_signature() + credit_user_xp()
        //    finalize the credit.
        ok = await ref.read(razorpayServiceProvider).startPurchase(
              amountInr: _selected,
              xpAmount: _selected,
              userId: me.userId,
              userEmail: me.email,
              userName: me.displayName,
            );
      }
      if (ok) {
        // Refresh the profile so the badge reflects the new balance,
        // pop the sheet, then celebrate. Celebration is pushed on the
        // root navigator so it stays visible after the sheet dismisses.
        ref.invalidate(currentUserProvider);
        final creditedAmount = _selected;
        if (mounted) Navigator.of(context).pop(true);
        // Defer the celebration push until AFTER the sheet's pop has
        // settled. Same-tick push-after-pop trips Navigator's
        // `!_debugLocked` assertion because the navigator is still
        // finalising the pop when the new push tries to acquire the
        // lock. A single post-frame callback is enough to unlock.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          // ignore_for_file: use_build_context_synchronously — rootNavigator
          // was captured before the await, so its context is still valid.
          // ignore: unawaited_futures
          showXpPurchaseCelebration(
            rootNavigator.context,
            xpAmount: creditedAmount,
          );
        });
      } else {
        if (mounted) {
          setState(() {
            _processing = false;
            _error = 'Payment cancelled.';
          });
        }
      }
    } catch (e) {
      if (!mounted) return;
      // Network / DNS failures get the friendly "No connection" sheet
      // instead of the raw exception text. Same treatment as the auth
      // screens.
      if (isNetworkError(e)) {
        setState(() {
          _processing = false;
          _error = null;
        });
        final retry = await showNoNetworkSheet(
          rootNavigator.context,
          subtitle:
              "Couldn't reach the payment server. Connect to Wi-Fi or "
              "mobile data and try again.",
        );
        if (retry == true && mounted) {
          // Fire the checkout again on retry — user stays in the sheet.
          // ignore: unawaited_futures
          _checkout();
        }
        return;
      }
      // Non-network failure: keep the existing inline + SnackBar surface
      // so payment-server 4xx/5xx errors still reach the user clearly.
      final msg = e.toString().replaceFirst('Exception: ', '');
      setState(() {
        _processing = false;
        _error = msg;
      });
      messenger.showSnackBar(
        SnackBar(
          content: Text(msg),
          duration: const Duration(seconds: 6),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // `select` — only rebuild when the XP balance actually changes.
    // The full profile row updates constantly (steps, streak, missions).
    final balance = ref.watch(currentUserProvider
        .select((async) => async.valueOrNull?.totalXP ?? 0));
    final paymentProvider = ref.watch(paymentProviderProvider);
    final currency = ref.watch(selectedCurrencyProvider);
    // Stripe uses fixed tiers with server-side price validation; custom
    // amount doesn't fit that model. Only shown on the Razorpay path.
    final showCustomInput = paymentProvider == PaymentProvider.razorpay;
    // Subtitle changes per provider — Razorpay is INR-only, Stripe
    // shows the active currency so the user sees which region they're
    // being priced in.
    final subtitle = paymentProvider == PaymentProvider.razorpay
        ? '₹1 = 1 XP · current balance ${_fmt(balance)} XP'
        : 'Prices in ${currency.code} · current balance ${_fmt(balance)} XP';
    // Pull ColorScheme from the actual resolved theme rather than
    // AppColors.* — inside a bottom sheet the AppColors global-brightness
    // flag can go stale (see [AppColors.updateBrightness] docs), and
    // hardcoded Colors.white on the input rendered as white-on-white in
    // light mode.
    final scheme = theme.colorScheme;
    // Push the whole sheet up by the on-screen keyboard height so the
    // custom-amount TextField stays visible when the user starts typing.
    // DraggableScrollableSheet doesn't auto-resize on keyboard inset —
    // we handle it explicitly in the outer Padding here.
    final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;
    return DraggableScrollableSheet(
      initialChildSize: 0.75,
      minChildSize: 0.5,
      maxChildSize: 0.92,
      expand: false,
      builder: (context, scrollController) => Padding(
        padding: EdgeInsets.only(bottom: keyboardInset),
        child: Container(
        decoration: BoxDecoration(
          color: AppColors.surfaceContainer,
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
        child: Column(
          children: [
            const BottomSheetHandle(),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Buy XP',
                            style: theme.textTheme.headlineSmall?.copyWith(
                              color: scheme.onSurface,
                              fontWeight: FontWeight.w900,
                            )),
                        const SizedBox(height: 4),
                        Text(
                          subtitle,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  // "i" affordance → opens the XP history sheet so users
                  // can see every earn / spend / refund from the last 7
                  // days before deciding to top up. Tap target matches
                  // the header baseline so it doesn't feel bolted-on.
                  IconButton(
                    tooltip: 'XP history',
                    icon: Icon(Icons.info_outline, color: scheme.primary),
                    onPressed: () => showXpHistorySheet(context),
                  ),
                ],
              ),
            ),
            // Preset grid + custom amount field stay together in a
            // scroll view so the layout doesn't break when the keyboard
            // opens on small phones.
            Expanded(
              child: ListView(
                controller: scrollController,
                padding: const EdgeInsets.fromLTRB(24, 12, 24, 12),
                children: [
                  GridView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 2,
                      mainAxisSpacing: 10,
                      crossAxisSpacing: 10,
                      childAspectRatio: 1.8,
                    ),
                    itemCount: _packs.length,
                    itemBuilder: (_, i) => _PackTile(
                      amount: _packs[i],
                      currency: currency,
                      // The preset is "selected" only when the custom
                      // input is empty AND the amount matches — that
                      // way typing a custom value visually deselects
                      // the preset cards.
                      selected: (_customController.text.trim().isEmpty ||
                              !showCustomInput) &&
                          _packs[i] == _selected,
                      onTap: () => _pickPreset(_packs[i]),
                    ),
                  ),
                  if (showCustomInput) ...[
                    const SizedBox(height: 18),
                    Row(
                      children: [
                        Expanded(
                          child: Container(
                            height: 1,
                            color: AppColors.outlineVariant
                                .withValues(alpha: 0.5),
                          ),
                        ),
                        Padding(
                          padding:
                              const EdgeInsets.symmetric(horizontal: 10),
                          child: Text(
                            'OR ENTER A CUSTOM AMOUNT',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: AppColors.onSurfaceVariant,
                              letterSpacing: 1.5,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                        Expanded(
                          child: Container(
                            height: 1,
                            color: AppColors.outlineVariant
                                .withValues(alpha: 0.5),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _customController,
                      focusNode: _customFocus,
                      keyboardType: TextInputType.number,
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                        LengthLimitingTextInputFormatter(6),
                      ],
                      cursorColor: scheme.primary,
                      // Use the RESOLVED color scheme — the previous
                      // `Colors.white` rendered as white-on-white when
                      // the sheet opened in light mode. `onSurface` from
                      // the inherited theme always matches the actual
                      // rendered brightness.
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: scheme.onSurface,
                      ),
                      decoration: InputDecoration(
                        prefixText: '₹ ',
                        prefixStyle: TextStyle(
                          color: scheme.onSurfaceVariant,
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        ),
                        hintText: 'e.g. 750',
                        hintStyle: TextStyle(
                          color: scheme.onSurfaceVariant,
                        ),
                        // errorText takes priority; helperText shows the
                        // range hint when there's no active error. Both
                        // occupy the same slot below the field so the
                        // sheet height doesn't jump when validation
                        // toggles.
                        errorText: _customError,
                        errorStyle: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                        helperText: _customError == null
                            ? 'Min ₹$_minXp · Max ₹$_maxXp · ₹1 = 1 XP'
                            : null,
                        helperStyle: TextStyle(
                          color: AppColors.onSurfaceVariant,
                          fontSize: 12,
                        ),
                        filled: true,
                        fillColor: AppColors.surfaceContainerLow,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 18,
                          vertical: 18,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide.none,
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide(
                            color: AppColors.primary,
                            width: 2,
                          ),
                        ),
                      ),
                    ),
                  ],
                  // Reserve room above the CTA so the very bottom of the
                  // grid is reachable when the on-screen keyboard pushes
                  // the sheet up.
                  const SizedBox(height: 12),
                ],
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Text(_error!,
                    style: TextStyle(color: AppColors.error)),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
              child: SizedBox(
                width: double.infinity,
                height: 56,
                child: FilledButton.icon(
                  // Disabled while a payment is in flight OR the custom
                  // input has a validation error. Preset taps clear the
                  // error automatically (see _pickPreset), so a user
                  // stuck on the error can always tap a preset to
                  // recover — no dead-end.
                  onPressed: (_processing || _customError != null)
                      ? null
                      : _checkout,
                  icon: _processing
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.lock_outline),
                  label: Text(
                    _processing
                        ? 'Processing…'
                        : (_customError != null
                            // While error is active, the button becomes
                            // a nudge back to a valid amount instead of
                            // showing a misleading "Pay ₹100" price.
                            ? 'Enter ₹$_minXp – ₹${_fmt(_maxXp)}'
                            : _ctaLabel(paymentProvider, currency, _selected)),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      ),
    );
  }

  static String _fmt(int n) {
    final s = n.toString();
    final buf = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
      buf.write(s[i]);
    }
    return buf.toString();
  }

  /// CTA button label. Razorpay shows "Pay ₹NNN via Razorpay" using the
  /// custom-amount value. Stripe uses the tier's price in the active
  /// currency (via the pricing catalog).
  static String _ctaLabel(
      PaymentProvider provider, PriceCurrency currency, int selected) {
    if (provider == PaymentProvider.razorpay) {
      return 'Pay ₹${_fmt(selected)} via Razorpay';
    }
    final tier = priceTierFor(selected);
    if (tier == null) return 'Pay via Stripe';
    return 'Pay ${currency.formatMinor(tier.minorFor(currency))} via Stripe';
  }
}

class _PackTile extends StatelessWidget {
  final int amount;
  final bool selected;
  final VoidCallback onTap;
  final PriceCurrency currency;
  const _PackTile({
    required this.amount,
    required this.currency,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Price rendered in the active currency via the pricing catalog.
    // Falls back to ₹NNN if the tier isn't in the catalog (shouldn't
    // happen — the preset list matches the catalog exactly).
    final tier = priceTierFor(amount);
    final priceLabel = tier != null
        ? currency.formatMinor(tier.minorFor(currency))
        : '₹${_fmt(amount)}';
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: selected
              ? AppColors.primary.withValues(alpha: 0.15)
              : AppColors.surfaceContainerLow,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected
                ? AppColors.primary
                : AppColors.outlineVariant,
            width: selected ? 2 : 1,
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${_fmt(amount)} XP',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
                color: selected
                    ? AppColors.primary
                    : AppColors.onSurface,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              priceLabel,
              style: theme.textTheme.bodySmall?.copyWith(
                color: AppColors.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _fmt(int n) {
    final s = n.toString();
    final buf = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
      buf.write(s[i]);
    }
    return buf.toString();
  }
}
