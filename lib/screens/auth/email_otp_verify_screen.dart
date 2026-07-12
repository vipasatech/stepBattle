import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../config/colors.dart';
import '../../providers/auth_provider.dart';
import '../../utils/network_errors.dart';
import '../../widgets/glass_card.dart';
import '../../widgets/no_network_sheet.dart';
import 'auth_error_banner.dart';

/// Passwordless (Strava-style) OTP verification screen. Reached from
/// the signup/login screens after the user tapped **Send code**.
///
/// Supabase's `signInWithOtp` doesn't distinguish signup from login —
/// the same 6-digit code creates a session either way. So this
/// screen has one path:
///   • User enters the code
///   • We call `verifyEmailOtp`
///   • Session lands in `authStateProvider`
///   • Redirect gate routes to /onboarding (fresh signup) or /home
///     (returning user)
///
/// The X close button routes back to /welcome. On rate-limit errors
/// we parse Supabase's "wait N seconds" message and show it.
class EmailOtpVerifyScreen extends ConsumerStatefulWidget {
  /// Email the OTP was sent to. Required — arriving here without one
  /// is a bug and we bounce back to /welcome.
  final String email;

  /// Cosmetic hint for the header copy. When `signup` we say
  /// "Verify your email"; when `login` we say "Sign in". Doesn't
  /// affect the auth call — that's identical either way.
  final String mode;

  const EmailOtpVerifyScreen({
    super.key,
    required this.email,
    this.mode = 'login',
  });

  @override
  ConsumerState<EmailOtpVerifyScreen> createState() =>
      _EmailOtpVerifyScreenState();
}

class _EmailOtpVerifyScreenState
    extends ConsumerState<EmailOtpVerifyScreen> {
  final _otpController = TextEditingController();
  bool _loading = false;
  bool _resending = false;
  String? _error;
  String? _info;

  @override
  void dispose() {
    _otpController.dispose();
    super.dispose();
  }

  Future<bool> _handleNetworkError(Object error, String action) async {
    if (!isNetworkError(error)) return false;
    if (!mounted) return false;
    final retry = await showNoNetworkSheet(
      context,
      subtitle: "Couldn't $action. Connect to Wi-Fi or mobile data and try again.",
    );
    return retry == true;
  }

  Future<void> _verify() async {
    final otp = _otpController.text.trim();
    if (otp.isEmpty) {
      setState(() => _error = 'Enter the 6-digit code from your email.');
      return;
    }
    if (otp.length != 6 || int.tryParse(otp) == null) {
      setState(() => _error = 'The code is 6 digits.');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
      _info = null;
    });
    try {
      await ref.read(authServiceProvider).verifyEmailOtp(
            email: widget.email,
            otp: otp,
          );
      // Session tick propagates via authStateProvider — the redirect
      // gate routes to /home or /onboarding depending on profile
      // completeness. No explicit navigation needed here.
    } catch (e) {
      if (await _handleNetworkError(e, 'verify the code')) {
        if (mounted) setState(() => _loading = false);
        return _verify();
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
            _error = "Couldn't verify. Please try again.";
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
      await ref.read(authServiceProvider).sendEmailOtp(widget.email);
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
    final title =
        widget.mode == 'signup' ? 'Verify your email' : 'Sign in';
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
                    title,
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
                        const TextSpan(text: 'Enter the 6-digit code we sent to '),
                        TextSpan(
                          text: widget.email,
                          style: const TextStyle(fontWeight: FontWeight.w800),
                        ),
                        const TextSpan(text: '.'),
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
                          autofocus: true,
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
                            onPressed: _loading ? null : _verify,
                            child: _loading
                                ? const SizedBox(
                                    width: 22,
                                    height: 22,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2.5,
                                      color: Colors.white,
                                    ),
                                  )
                                : Text(widget.mode == 'signup'
                                    ? 'Verify & continue'
                                    : 'Verify & sign in'),
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
                  const SizedBox(height: 24),
                  Center(
                    child: TextButton(
                      onPressed: () => context.go('/welcome'),
                      child: Text(
                        'Use a different email',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: AppColors.onSurfaceVariant,
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
                  onPressed: () => context.go('/welcome'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
