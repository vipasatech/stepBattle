import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/colors.dart';
import '../providers/auth_provider.dart';
import '../services/razorpay_service.dart';
import '../widgets/bottom_sheet_handle.dart';

/// Buy-XP bottom sheet — â‚¹1 → 1 XP.
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
    if (raw.isEmpty) return;
    final parsed = int.tryParse(raw);
    if (parsed == null) return;
    final clamped = parsed.clamp(_minXp, _maxXp);
    if (clamped != _selected) {
      setState(() => _selected = clamped);
    }
  }

  void _pickPreset(int amount) {
    setState(() => _selected = amount);
    // Clear the custom field so the UI doesn't show two competing values.
    _customController.clear();
    _customFocus.unfocus();
  }

  Future<void> _checkout() async {
    final me = ref.read(currentUserProvider).valueOrNull;
    if (me == null) return;

    setState(() {
      _processing = true;
      _error = null;
    });
    try {
      // Razorpay flow:
      //   1. Edge Function `razorpay_create_order` creates a server-side
      //      order (returns order_id).
      //   2. We launch the Razorpay checkout with that order_id.
      //   3. On success Razorpay calls our Edge Function `razorpay_verify`
      //      with the signature; verify_signature() + credit_user_xp()
      //      finalize the credit.
      //
      // The result hop returns true once verify is acknowledged so we
      // can re-fetch the user's XP and pop.
      final ok = await ref.read(razorpayServiceProvider).startPurchase(
            amountInr: _selected,
            xpAmount: _selected,
            userId: me.userId,
            userEmail: me.email,
            userName: me.displayName,
          );
      if (ok) {
        ref.invalidate(currentUserProvider);
        if (mounted) Navigator.of(context).pop(true);
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
      // Show error in BOTH the inline text AND a SnackBar — the sheet
      // can scroll the inline text out of view and we don't want any
      // failure to look like a silent no-op.
      final msg = e.toString().replaceFirst('Exception: ', '');
      setState(() {
        _processing = false;
        _error = msg;
      });
      ScaffoldMessenger.of(context).showSnackBar(
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
    final balance =
        ref.watch(currentUserProvider).valueOrNull?.totalXP ?? 0;
    return DraggableScrollableSheet(
      initialChildSize: 0.75,
      minChildSize: 0.5,
      maxChildSize: 0.92,
      expand: false,
      builder: (context, scrollController) => Container(
        decoration: BoxDecoration(
          color: AppColors.surfaceContainer,
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
        child: Column(
          children: [
            const BottomSheetHandle(),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Buy XP',
                      style: theme.textTheme.headlineSmall
                          ?.copyWith(fontWeight: FontWeight.w900)),
                  const SizedBox(height: 4),
                  Text(
                    'â‚¹1 = 1 XP · current balance ${_fmt(balance)} XP',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: AppColors.onSurfaceVariant,
                    ),
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
                      // The preset is "selected" only when the custom
                      // input is empty AND the amount matches — that
                      // way typing a custom value visually deselects
                      // the preset cards.
                      selected: _customController.text.trim().isEmpty &&
                          _packs[i] == _selected,
                      onTap: () => _pickPreset(_packs[i]),
                    ),
                  ),
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
                    cursorColor: AppColors.primary,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                    decoration: InputDecoration(
                      prefixText: 'â‚¹ ',
                      prefixStyle: TextStyle(
                        color: AppColors.onSurfaceVariant,
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                      hintText: 'e.g. 750',
                      hintStyle: TextStyle(
                        color: AppColors.onSurfaceVariant,
                      ),
                      helperText:
                          'Min â‚¹$_minXp · Max â‚¹$_maxXp · â‚¹1 = 1 XP',
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
                  onPressed: _processing ? null : _checkout,
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
                        : 'Pay â‚¹${_fmt(_selected)} via Razorpay',
                  ),
                ),
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

class _PackTile extends StatelessWidget {
  final int amount;
  final bool selected;
  final VoidCallback onTap;
  const _PackTile({
    required this.amount,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
              'â‚¹${_fmt(amount)}',
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
