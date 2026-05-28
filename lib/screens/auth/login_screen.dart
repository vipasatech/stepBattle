import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../config/colors.dart';
import '../../providers/auth_provider.dart';
import '../../utils/network_errors.dart';
import '../../widgets/app_logo.dart';
import '../../widgets/glass_card.dart';
import '../../widgets/no_network_sheet.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  bool _loading = false;
  String? _error;

  // Email sign-in form
  bool _showEmailForm = false;
  bool _isSignUp = false;
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  /// Show the no-network sheet on connection/DNS failures. Returns true if
  /// the user tapped "Try again". Caller decides whether to retry — we
  /// don't loop here so the user can also tap Dismiss and check network
  /// settings before retrying.
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

  Future<void> _signInWithEmail() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text.trim();
    if (email.isEmpty || password.isEmpty) {
      setState(() => _error = 'Please enter email and password.');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final authService = ref.read(authServiceProvider);
      if (_isSignUp) {
        await authService.signUpWithEmail(email, password);
      } else {
        await authService.signInWithEmail(email, password);
      }
    } catch (e) {
      if (await _handleNetworkError(
          e, _isSignUp ? 'create your account' : 'sign in')) {
        if (mounted) setState(() => _loading = false);
        return _signInWithEmail();
      }
      if (mounted) {
        setState(() => _error = _isSignUp
            ? 'Sign up failed. Please try again.'
            : 'Invalid email or password.');
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
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            children: [
              const SizedBox(height: 60),

              // Logo + branding
              const AppLogo(size: 96),
              const SizedBox(height: 16),
              Text(
                'StepBattle',
                style: theme.textTheme.displaySmall?.copyWith(
                  color: AppColors.primaryBrand,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Walk. Compete. Dominate.',
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: AppColors.onSurfaceVariant,
                ),
              ),

              const SizedBox(height: 56),

              // Social sign-in buttons
              _SocialButton(
                onPressed: _loading ? null : _signInWithGoogle,
                icon: Icons.g_mobiledata,
                label: 'Continue with Google',
                backgroundColor: AppColors.surfaceContainerHigh,
              ),
              const SizedBox(height: 12),

              if (Platform.isIOS) ...[
                _SocialButton(
                  onPressed: _loading ? null : _signInWithApple,
                  icon: Icons.apple,
                  label: 'Continue with Apple',
                  backgroundColor: Colors.white,
                  textColor: Colors.black,
                ),
                const SizedBox(height: 12),
              ],

              _SocialButton(
                onPressed: _loading
                    ? null
                    : () => setState(() => _showEmailForm = !_showEmailForm),
                icon: Icons.email_outlined,
                label: 'Continue with Email',
                backgroundColor: AppColors.surfaceContainerHigh,
              ),

              // Email form
              if (_showEmailForm) ...[
                const SizedBox(height: 24),
                GlassCard(
                  padding: const EdgeInsets.all(20),
                  borderRadius: 20,
                  child: Column(
                    children: [
                      TextField(
                        controller: _emailController,
                        keyboardType: TextInputType.emailAddress,
                        style: theme.textTheme.bodyLarge,
                        decoration: const InputDecoration(
                          hintText: 'Email address',
                          prefixIcon: Icon(Icons.email_outlined, size: 20),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _passwordController,
                        obscureText: true,
                        style: theme.textTheme.bodyLarge,
                        decoration: const InputDecoration(
                          hintText: 'Password',
                          prefixIcon: Icon(Icons.lock_outline, size: 20),
                        ),
                      ),
                      const SizedBox(height: 16),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton(
                          onPressed: _loading ? null : _signInWithEmail,
                          child: Text(_isSignUp ? 'Create Account' : 'Sign In'),
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextButton(
                        onPressed: () =>
                            setState(() => _isSignUp = !_isSignUp),
                        child: Text(
                          _isSignUp
                              ? 'Already have an account? Sign In'
                              : "Don't have an account? Sign Up",
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: AppColors.primary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],

              // Error message
              if (_error != null) ...[
                const SizedBox(height: 16),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  decoration: BoxDecoration(
                    color: AppColors.error.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.error_outline,
                          color: AppColors.error, size: 18),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _error!,
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: AppColors.error),
                        ),
                      ),
                    ],
                  ),
                ),
              ],

              // Loading
              if (_loading) ...[
                const SizedBox(height: 24),
                const CircularProgressIndicator(color: AppColors.primary),
              ],

              const SizedBox(height: 48),

              // Footer
              Text(
                'By continuing, you agree to our Terms of Service\nand Privacy Policy.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: AppColors.onSurfaceVariant.withValues(alpha: 0.6),
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}

class _SocialButton extends StatelessWidget {
  final VoidCallback? onPressed;
  final IconData icon;
  final String label;
  final Color backgroundColor;
  final Color? textColor;

  const _SocialButton({
    required this.onPressed,
    required this.icon,
    required this.label,
    required this.backgroundColor,
    this.textColor,
  });

  @override
  Widget build(BuildContext context) {
    final fgColor = textColor ?? AppColors.onSurface;
    return SizedBox(
      width: double.infinity,
      height: 56,
      child: OutlinedButton.icon(
        onPressed: onPressed,
        icon: Icon(icon, color: fgColor, size: 24),
        label: Text(label,
            style: Theme.of(context)
                .textTheme
                .labelLarge
                ?.copyWith(color: fgColor)),
        style: OutlinedButton.styleFrom(
          backgroundColor: backgroundColor,
          side: BorderSide(color: Colors.white.withValues(alpha: 0.05)),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
      ),
    );
  }
}
