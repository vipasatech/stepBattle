// ARCHIVED — passwordless OTP auth replaced the password-reset flow
// (see `email_otp_verify_screen.dart`). Kept as commented-out
// reference in case we ever add password auth back.
//
// To restore:
//   1. Delete the `/*` and `*/` wrappers below.
//   2. Re-add the verifyPasswordResetOtp + updatePassword methods to
//      `lib/services/supabase_auth_service.dart` (Supabase's
//      `verifyOTP(type: OtpType.recovery)` + `updateUser` are the
//      underlying calls).
//   3. Re-register `/reset-password` in `lib/config/routes.dart`
//      and make sure the redirect gate allows signed-in users to
//      stay on it mid-flow (verifyOTP establishes a session before
//      updatePassword runs).

/*
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../config/colors.dart';
import '../../providers/auth_provider.dart';
import '../../utils/network_errors.dart';
import '../../widgets/glass_card.dart';
import '../../widgets/no_network_sheet.dart';
import 'auth_error_banner.dart';

/// Step 2 of the password-reset flow — verifies the 6-digit OTP the
/// user received by email, then sets a new password + confirm
/// password. On success the recovery session is left signed in, so
/// the redirect gate routes to /home (or /onboarding for a fresh
/// profile).
class ResetPasswordScreen extends ConsumerStatefulWidget {
  final String email;
  const ResetPasswordScreen({super.key, required this.email});

  @override
  ConsumerState<ResetPasswordScreen> createState() =>
      _ResetPasswordScreenState();
}

class _ResetPasswordScreenState extends ConsumerState<ResetPasswordScreen> {
  final _otpController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmController = TextEditingController();
  bool _loading = false;
  bool _resending = false;
  String? _error;
  String? _info;

  @override
  void dispose() {
    _otpController.dispose();
    _passwordController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  Future<bool> _handleNetworkError(Object error, String action) async {
    if (!isNetworkError(error)) return false;
    if (!mounted) return false;
    final retry = await showNoNetworkSheet(
      context,
      subtitle:
          "Couldn't $action. Connect to Wi-Fi or mobile data and try again.",
    );
    return retry == true;
  }

  Future<void> _submit() async {
    final otp = _otpController.text.trim();
    final password = _passwordController.text;
    final confirm = _confirmController.text;
    if (otp.isEmpty || password.isEmpty || confirm.isEmpty) {
      setState(() => _error = 'Please fill every field.');
      return;
    }
    if (otp.length != 6 || int.tryParse(otp) == null) {
      setState(() => _error = 'The code is 6 digits.');
      return;
    }
    if (password.length < 6) {
      setState(() => _error = 'Password must be at least 6 characters.');
      return;
    }
    if (password != confirm) {
      setState(() => _error = "Passwords don't match.");
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
      _info = null;
    });
    try {
      final auth = ref.read(authServiceProvider);
      await auth.verifyPasswordResetOtp(email: widget.email, otp: otp);
      await auth.updatePassword(password);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Password updated.')),
        );
        context.go('/home');
      }
    } catch (e) {
      if (await _handleNetworkError(e, 'reset your password')) {
        if (mounted) setState(() => _loading = false);
        return _submit();
      }
      if (mounted) {
        final msg = e.toString().toLowerCase();
        setState(() {
          if (msg.contains('token') ||
              msg.contains('otp') ||
              msg.contains('expired') ||
              msg.contains('invalid')) {
            _error = 'That code is invalid or expired. Try again.';
          } else {
            _error = "Couldn't reset your password. Please try again.";
          }
        });
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _resend() async {
    setState(() {
      _resending = true;
      _error = null;
      _info = null;
    });
    try {
      await ref.read(authServiceProvider).sendPasswordResetOtp(widget.email);
      if (mounted) {
        setState(() => _info = 'Sent a new code to ${widget.email}.');
      }
    } catch (e) {
      if (await _handleNetworkError(e, 'send a new code')) {
        if (mounted) setState(() => _resending = false);
        return _resend();
      }
      if (mounted) {
        final msg = e.toString();
        final lower = msg.toLowerCase();
        setState(() {
          if (lower.contains('rate limit') ||
              lower.contains('for security purposes') ||
              lower.contains('statuscode: 429')) {
            final match = RegExp(r'after (\d+) seconds').firstMatch(msg);
            final wait = match?.group(1);
            _error = wait != null
                ? 'Too many resend attempts. Try again in $wait seconds.'
                : 'Too many resend attempts. Wait a minute and try again.';
          } else {
            _error = "Couldn't send a new code. Try again shortly.";
          }
        });
      }
    } finally {
      if (mounted) setState(() => _resending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 80, 24, 24),
              physics: const ClampingScrollPhysics(),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Reset password',
                    style: theme.textTheme.headlineLarge?.copyWith(
                      color: theme.colorScheme.onSurface,
                      fontWeight: FontWeight.w900,
                      letterSpacing: -0.6,
                      height: 1.1,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text.rich(
                    TextSpan(
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: AppColors.onSurfaceVariant,
                        height: 1.4,
                      ),
                      children: [
                        const TextSpan(text: 'Enter the 6-digit code sent to '),
                        TextSpan(
                          text: widget.email,
                          style: const TextStyle(fontWeight: FontWeight.w800),
                        ),
                        const TextSpan(text: ' and choose a new password.'),
                      ],
                    ),
                  ),
                  const SizedBox(height: 32),
                  GlassCard(
                    padding: const EdgeInsets.all(20),
                    borderRadius: 20,
                    child: Column(
                      children: [
                        TextField(
                          controller: _otpController,
                          keyboardType: TextInputType.number,
                          maxLength: 6,
                          textAlign: TextAlign.center,
                          style: theme.textTheme.headlineSmall?.copyWith(
                            letterSpacing: 12,
                            fontWeight: FontWeight.w800,
                            color: theme.colorScheme.onSurface,
                          ),
                          decoration: const InputDecoration(
                            hintText: '••••••',
                            counterText: '',
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _passwordController,
                          obscureText: true,
                          autofillHints: const [AutofillHints.newPassword],
                          style: theme.textTheme.bodyLarge,
                          decoration: const InputDecoration(
                            hintText: 'New password (min 6 characters)',
                            prefixIcon: Icon(Icons.lock_outline, size: 20),
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _confirmController,
                          obscureText: true,
                          autofillHints: const [AutofillHints.newPassword],
                          style: theme.textTheme.bodyLarge,
                          decoration: const InputDecoration(
                            hintText: 'Confirm password',
                            prefixIcon: Icon(Icons.lock_outline, size: 20),
                          ),
                        ),
                        const SizedBox(height: 16),
                        SizedBox(
                          width: double.infinity,
                          height: 50,
                          child: FilledButton(
                            style: FilledButton.styleFrom(
                              backgroundColor: AppColors.primary,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                            ),
                            onPressed: _loading ? null : _submit,
                            child: _loading
                                ? const SizedBox(
                                    width: 22,
                                    height: 22,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2.5,
                                      color: Colors.white,
                                    ),
                                  )
                                : const Text('Reset password'),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (_info != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      _info!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: AppColors.success,
                        fontWeight: FontWeight.w700,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: 16),
                    AuthErrorBanner(message: _error!),
                  ],
                  const SizedBox(height: 16),
                  Center(
                    child: TextButton(
                      onPressed: _loading || _resending ? null : _resend,
                      child: Text(
                        _resending
                            ? 'Sending…'
                            : "Didn't get the code? Resend",
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: AppColors.primary,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Positioned(
              top: 8,
              right: 8,
              child: Material(
                color: Colors.transparent,
                child: IconButton(
                  icon: Icon(
                    Icons.close_rounded,
                    color: theme.colorScheme.onSurface,
                    size: 28,
                  ),
                  onPressed: () => context.go('/login'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
*/
