import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/colors.dart';
import '../providers/auth_provider.dart';
import '../providers/referral_provider.dart';
import '../services/referral_service.dart';
import '../widgets/bottom_sheet_handle.dart';

/// Bottom sheet where the current user enters a friend's user_code to
/// claim the referral bonus. Both users receive XP after the referee
/// has completed 500 steps AND been on the app for 24 hours — the
/// delayed-reward design blocks signup-farm abuse.
///
/// Exposed via [showRedeemReferralSheet]. Closes on success.
///
/// If the user has already redeemed a code, the sheet still opens but
/// the RPC returns `already_redeemed` on submit and the UI surfaces
/// that clearly.
class RedeemReferralSheet extends ConsumerStatefulWidget {
  const RedeemReferralSheet({super.key});

  @override
  ConsumerState<RedeemReferralSheet> createState() =>
      _RedeemReferralSheetState();
}

Future<void> showRedeemReferralSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    useRootNavigator: true,
    builder: (_) => const RedeemReferralSheet(),
  );
}

class _RedeemReferralSheetState extends ConsumerState<RedeemReferralSheet> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  bool _submitting = false;
  ReferralRedeemResult? _result;

  @override
  void initState() {
    super.initState();
    // Autofocus after the sheet's slide-in animation settles so the
    // keyboard doesn't fight the sheet's own transition.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final code = _controller.text.trim();
    if (code.isEmpty || _submitting) return;
    setState(() {
      _submitting = true;
      _result = null;
    });
    final result =
        await ref.read(referralServiceProvider).redeem(code);
    if (!mounted) return;
    setState(() {
      _submitting = false;
      _result = result;
    });
    if (result.ok) {
      // Refresh the current user so any UI reading `referred_by` sees
      // the update; the actual XP bump will land later via
      // qualify_pending_referrals.
      ref.invalidate(currentUserProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.surfaceContainer,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Center(child: BottomSheetHandle()),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: AppColors.primary.withValues(alpha: 0.18),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(Icons.card_giftcard,
                          color: AppColors.primary, size: 22),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Redeem a referral code',
                        style: theme.textTheme.titleLarge
                            ?.copyWith(fontWeight: FontWeight.w800),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  'Enter a friend\'s StepBattle user code. Once you\'ve '
                  'completed 500 steps and been on the app for 24 hours, '
                  'you\'ll earn 50 XP and your friend will earn 100 XP.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: AppColors.onSurfaceVariant,
                    height: 1.45,
                  ),
                ),
                const SizedBox(height: 20),
                TextField(
                  controller: _controller,
                  focusNode: _focus,
                  autofocus: true,
                  textCapitalization: TextCapitalization.characters,
                  inputFormatters: [
                    LengthLimitingTextInputFormatter(12),
                    FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9]')),
                    _UpperCaseTextFormatter(),
                  ],
                  onSubmitted: (_) => _submit(),
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 2,
                    color: AppColors.onSurface,
                    fontFamily: 'Manrope',
                  ),
                  decoration: InputDecoration(
                    hintText: 'e.g. U4X92',
                    hintStyle: TextStyle(
                      color: AppColors.onSurfaceVariant.withValues(alpha: 0.5),
                      letterSpacing: 2,
                      fontWeight: FontWeight.w700,
                    ),
                    filled: true,
                    fillColor: AppColors.surfaceContainerLow,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 18, vertical: 18),
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
                if (_result != null) ...[
                  const SizedBox(height: 14),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: (_result!.ok
                              ? AppColors.success
                              : AppColors.error)
                          .withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: (_result!.ok
                                ? AppColors.success
                                : AppColors.error)
                            .withValues(alpha: 0.4),
                      ),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          _result!.ok
                              ? Icons.check_circle_outline
                              : Icons.error_outline,
                          color: _result!.ok
                              ? AppColors.success
                              : AppColors.error,
                          size: 20,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            _result!.userMessage,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: AppColors.onSurface,
                              height: 1.4,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 20),
                SizedBox(
                  height: 52,
                  child: FilledButton(
                    onPressed: (_submitting || (_result?.ok ?? false))
                        ? null
                        : _submit,
                    style: FilledButton.styleFrom(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                    child: _submitting
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white),
                          )
                        : Text(
                            (_result?.ok ?? false) ? 'Redeemed' : 'Redeem',
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.3,
                            ),
                          ),
                  ),
                ),
                if (_result?.ok ?? false) ...[
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Close'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Forces the text field's content to uppercase as the user types —
/// user_codes are stored/compared uppercase server-side.
class _UpperCaseTextFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
      TextEditingValue oldValue, TextEditingValue newValue) {
    return TextEditingValue(
      text: newValue.text.toUpperCase(),
      selection: newValue.selection,
    );
  }
}
