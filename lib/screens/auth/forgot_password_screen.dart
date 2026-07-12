// ARCHIVED — passwordless OTP auth replaced the password-reset flow
// (see `email_otp_verify_screen.dart`). Kept as commented-out
// reference in case we ever add password auth back.
//
// To restore:
//   1. Delete the `/*` and `*/` wrappers below.
//   2. Re-add the sendPasswordResetOtp method to
//      `lib/services/supabase_auth_service.dart` (Supabase's
//      `resetPasswordForEmail` is the underlying call).
//   3. Re-register `/forgot-password` in `lib/config/routes.dart`
//      and add the "Forgot password?" link back to the login screen.

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

/// Step 1 of the password-reset flow — asks for the email address to
/// send the 6-digit OTP to. On send, routes to `/reset-password`
/// with the email as a query parameter so the next screen can show
/// it and re-use it for the verify + updatePassword calls.
class ForgotPasswordScreen extends ConsumerStatefulWidget {
  final String? prefillEmail;
  const ForgotPasswordScreen({super.key, this.prefillEmail});

  @override
  ConsumerState<ForgotPasswordScreen> createState() =>
      _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends ConsumerState<ForgotPasswordScreen> {
  late final TextEditingController _emailController;
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _emailController = TextEditingController(text: widget.prefillEmail ?? '');
  }

  @override
  void dispose() {
    _emailController.dispose();
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

  Future<void> _send() async {
    final email = _emailController.text.trim();
    if (email.isEmpty) {
      setState(() => _error = 'Enter your email address.');
      return;
    }
    if (!email.contains('@') || !email.contains('.')) {
      setState(() => _error = "That doesn't look like a valid email.");
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await ref.read(authServiceProvider).sendPasswordResetOtp(email);
      if (mounted) {
        context.go('/reset-password?email=${Uri.encodeQueryComponent(email)}');
      }
    } catch (e) {
      if (await _handleNetworkError(e, 'send the reset code')) {
        if (mounted) setState(() => _loading = false);
        return _send();
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
            _error =
                "Couldn't send the reset code. Check the email and try again.";
          }
        });
      }
    } finally {
      if (mounted) setState(() => _loading = false);
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
                    'Forgot password?',
                    style: theme.textTheme.headlineLarge?.copyWith(
                      color: theme.colorScheme.onSurface,
                      fontWeight: FontWeight.w900,
                      letterSpacing: -0.6,
                      height: 1.1,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    "Enter your account email and we'll send you a 6-digit code to reset your password.",
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: AppColors.onSurfaceVariant,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 32),
                  GlassCard(
                    padding: const EdgeInsets.all(20),
                    borderRadius: 20,
                    child: Column(
                      children: [
                        TextField(
                          controller: _emailController,
                          keyboardType: TextInputType.emailAddress,
                          autofillHints: const [AutofillHints.email],
                          style: theme.textTheme.bodyLarge,
                          decoration: const InputDecoration(
                            hintText: 'Email address',
                            prefixIcon: Icon(Icons.email_outlined, size: 20),
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
                            onPressed: _loading ? null : _send,
                            child: _loading
                                ? const SizedBox(
                                    width: 22,
                                    height: 22,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2.5,
                                      color: Colors.white,
                                    ),
                                  )
                                : const Text('Send reset code'),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 16),
                    AuthErrorBanner(message: _error!),
                  ],
                  const SizedBox(height: 24),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        'Remembered it? ',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: AppColors.onSurfaceVariant,
                        ),
                      ),
                      GestureDetector(
                        onTap: () => context.go('/login'),
                        child: Text(
                          'Log in',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: AppColors.primary,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ],
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
