import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/colors.dart';

/// Bottom sheet for changing the user's email. Wraps Supabase's
/// `auth.updateUser(email:)` which sends a confirmation link to
/// BOTH the current and the new email — the change only takes
/// effect after the user clicks the link in the new inbox.
///
/// UI states:
///   * idle        — form visible, user can type + submit
///   * submitting  — spinner on the button, form disabled
///   * pending     — success view: "Check {new email}, click the
///                    link to confirm."
///   * error       — inline error under the field, form re-enabled
Future<void> showChangeEmailSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    useRootNavigator: true,
    isScrollControlled: true,
    builder: (_) => const _ChangeEmailSheet(),
  );
}

class _ChangeEmailSheet extends StatefulWidget {
  const _ChangeEmailSheet();

  @override
  State<_ChangeEmailSheet> createState() => _ChangeEmailSheetState();
}

class _ChangeEmailSheetState extends State<_ChangeEmailSheet> {
  final _controller = TextEditingController();
  String _status = 'idle'; // idle | submitting | pending | error
  String _errorMsg = '';
  String? _sentTo;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final email = _controller.text.trim();
    if (email.isEmpty || !email.contains('@')) {
      setState(() {
        _status = 'error';
        _errorMsg = 'Enter a valid email address.';
      });
      return;
    }
    setState(() {
      _status = 'submitting';
      _errorMsg = '';
    });
    try {
      await Supabase.instance.client.auth.updateUser(
        UserAttributes(email: email),
      );
      if (!mounted) return;
      setState(() {
        _status = 'pending';
        _sentTo = email;
      });
    } on AuthException catch (e) {
      if (!mounted) return;
      setState(() {
        _status = 'error';
        _errorMsg = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _status = 'error';
        _errorMsg = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return SafeArea(
      top: false,
      child: Container(
        decoration: const BoxDecoration(
          color: Color(0xFF14141A),
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: EdgeInsets.fromLTRB(24, 12, 24, 24 + bottomInset),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.25),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            if (_status == 'pending')
              _PendingView(email: _sentTo!)
            else ..._formFields(theme),
          ],
        ),
      ),
    );
  }

  List<Widget> _formFields(ThemeData theme) {
    final submitting = _status == 'submitting';
    return [
      Text(
        'Change email',
        style: theme.textTheme.titleMedium?.copyWith(
          color: Colors.white,
          fontWeight: FontWeight.w800,
        ),
      ),
      const SizedBox(height: 4),
      Text(
        'We\'ll send a confirmation link to the new address. '
        'The change only takes effect once you click it.',
        style: theme.textTheme.bodySmall?.copyWith(
          color: Colors.white.withValues(alpha: 0.6),
          height: 1.5,
        ),
      ),
      const SizedBox(height: 18),
      TextField(
        controller: _controller,
        enabled: !submitting,
        autofocus: true,
        keyboardType: TextInputType.emailAddress,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _submit(),
        style: const TextStyle(color: Colors.white, fontSize: 15),
        decoration: InputDecoration(
          hintText: 'you@example.com',
          hintStyle:
              TextStyle(color: Colors.white.withValues(alpha: 0.35)),
          filled: true,
          fillColor: Colors.white.withValues(alpha: 0.05),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(
              color: Colors.white.withValues(alpha: 0.1),
            ),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(
              color: Colors.white.withValues(alpha: 0.1),
            ),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: AppColors.primary),
          ),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        ),
      ),
      if (_status == 'error') ...[
        const SizedBox(height: 8),
        Text(
          _errorMsg,
          style: TextStyle(
            color: AppColors.error,
            fontSize: 12.5,
          ),
        ),
      ],
      const SizedBox(height: 18),
      SizedBox(
        width: double.infinity,
        child: FilledButton(
          onPressed: submitting ? null : _submit,
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.primary,
            padding: const EdgeInsets.symmetric(vertical: 14),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          child: submitting
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor:
                        AlwaysStoppedAnimation<Color>(Colors.white),
                  ),
                )
              : const Text('Send confirmation link'),
        ),
      ),
    ];
  }
}

class _PendingView extends StatelessWidget {
  final String email;
  const _PendingView({required this.email});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.mark_email_unread,
            color: AppColors.primary, size: 32),
        const SizedBox(height: 12),
        Text(
          'Check your inbox',
          style: theme.textTheme.titleMedium?.copyWith(
            color: Colors.white,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'A confirmation link was sent to $email. Click it to '
          'finish the switch. Your login email stays the same until '
          'you confirm.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: Colors.white.withValues(alpha: 0.7),
            height: 1.55,
          ),
        ),
        const SizedBox(height: 18),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.primary,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: const Text('Done'),
          ),
        ),
      ],
    );
  }
}
