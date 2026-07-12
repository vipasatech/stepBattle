import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../config/colors.dart';
import '../../providers/auth_provider.dart';
import '../../utils/network_errors.dart';
import '../../widgets/glass_card.dart';
import '../../widgets/no_network_sheet.dart';
import 'auth_error_banner.dart';
import 'auth_social_button.dart';

/// Passwordless login — one email field, "Send code" button. Same
/// Supabase call as [SignupScreen] (`signInWithOtp`); the auth
/// backend collapses signup + login into a single flow. Two screens
/// exist purely for the marketing copy + cross-link.
///
/// Existing accounts that were created with a password before the
/// passwordless switch still log in fine through this flow — Supabase
/// accepts an OTP for any email-registered user.
class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  bool _loading = false;
  String? _error;

  final _emailController = TextEditingController();

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
      subtitle: "Couldn't $action. Connect to Wi-Fi or mobile data and try again.",
    );
    return retry == true;
  }

  Future<void> _signInWithGoogle() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await ref.read(authServiceProvider).signInWithGoogle();
    } catch (e) {
      if (await _handleNetworkError(e, 'sign in with Google')) {
        if (mounted) setState(() => _loading = false);
        return _signInWithGoogle();
      }
      if (mounted) {
        setState(() => _error = 'Google sign-in failed. Please try again.');
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _signInWithApple() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await ref.read(authServiceProvider).signInWithApple();
    } catch (e) {
      if (await _handleNetworkError(e, 'sign in with Apple')) {
        if (mounted) setState(() => _loading = false);
        return _signInWithApple();
      }
      if (mounted) {
        setState(() => _error = 'Apple sign-in failed. Please try again.');
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _sendCode() async {
    final email = _emailController.text.trim();
    if (email.isEmpty || !email.contains('@') || !email.contains('.')) {
      setState(() => _error = "That doesn't look like a valid email.");
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await ref.read(authServiceProvider).sendEmailOtp(email);
      if (mounted) {
        context.go(
          '/verify-otp?email=${Uri.encodeQueryComponent(email)}&mode=login',
        );
      }
    } catch (e) {
      if (await _handleNetworkError(e, 'send the code')) {
        if (mounted) setState(() => _loading = false);
        return _sendCode();
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
                ? 'Too many attempts. Try again in $wait seconds.'
                : 'Too many attempts. Wait a minute and try again.';
          } else {
            _error = "Couldn't send the code. Please try again.";
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
              padding: const EdgeInsets.fromLTRB(24, 120, 24, 24),
              physics: const ClampingScrollPhysics(),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // ---- Title ----------------------------------
                  Text(
                    'Welcome back',
                    style: theme.textTheme.headlineLarge?.copyWith(
                      color: theme.colorScheme.onSurface,
                      fontWeight: FontWeight.w900,
                      letterSpacing: -0.6,
                      height: 1.1,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Log in to keep your streak going.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: AppColors.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 32),

                  // ---- Social ---------------------------------
                  AuthSocialButton(
                    onPressed: _loading ? null : _signInWithGoogle,
                    icon: Icons.g_mobiledata,
                    label: 'Continue with Google',
                    backgroundColor: AppColors.surfaceContainerHigh,
                  ),
                  const SizedBox(height: 12),
                  if (Platform.isIOS) ...[
                    AuthSocialButton(
                      onPressed: _loading ? null : _signInWithApple,
                      icon: Icons.apple,
                      label: 'Continue with Apple',
                      backgroundColor: Colors.white,
                      textColor: Colors.black,
                    ),
                    const SizedBox(height: 12),
                  ],
                  const SizedBox(height: 8),

                  // ---- Email + Send code ----------------------
                  GlassCard(
                    padding: const EdgeInsets.all(20),
                    borderRadius: 20,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.email_outlined,
                              size: 20,
                              color: theme.colorScheme.onSurface,
                            ),
                            const SizedBox(width: 10),
                            Text(
                              'Log in with Email',
                              style: theme.textTheme.titleMedium
                                  ?.copyWith(
                                fontWeight: FontWeight.w800,
                                color: theme.colorScheme.onSurface,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        TextField(
                          controller: _emailController,
                          keyboardType: TextInputType.emailAddress,
                          autofillHints: const [AutofillHints.email],
                          style: theme.textTheme.bodyLarge,
                          decoration: const InputDecoration(
                            hintText: 'Email address',
                            prefixIcon:
                                Icon(Icons.email_outlined, size: 20),
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
                            onPressed: _loading ? null : _sendCode,
                            child: _loading
                                ? const SizedBox(
                                    width: 22,
                                    height: 22,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2.5,
                                      color: Colors.white,
                                    ),
                                  )
                                : const Text('Send code'),
                          ),
                        ),
                      ],
                    ),
                  ),

                  if (_error != null) ...[
                    const SizedBox(height: 16),
                    AuthErrorBanner(message: _error!),
                  ],

                  const SizedBox(height: 20),

                  // ---- Cross-link + terms ---------------------
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        "Don't have an account? ",
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: AppColors.onSurfaceVariant,
                        ),
                      ),
                      GestureDetector(
                        onTap: () => context.go('/signup'),
                        child: Text(
                          'Sign up',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: AppColors.primary,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'By continuing, you agree to our Terms of Service\nand Privacy Policy.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: AppColors.onSurfaceVariant.withValues(alpha: 0.6),
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),

            // ---- Close button ---------------------------------
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
