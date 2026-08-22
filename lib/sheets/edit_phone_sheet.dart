import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/colors.dart';
import '../providers/auth_provider.dart';
import '../providers/user_provider.dart';

/// Bottom sheet for adding / changing the profile phone number.
///
/// v1 stores the phone as a plain text column (profiles.phone) with
/// no OTP verification. Once an SMS provider is wired into Supabase
/// (Twilio / MSG91), we can swap the write for a
/// `supabase.auth.updateUser(phone:)` call that triggers the OTP
/// challenge — no UI change needed at that point.
Future<void> showEditPhoneSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    useRootNavigator: true,
    isScrollControlled: true,
    builder: (_) => const _EditPhoneSheet(),
  );
}

class _EditPhoneSheet extends ConsumerStatefulWidget {
  const _EditPhoneSheet();

  @override
  ConsumerState<_EditPhoneSheet> createState() => _EditPhoneSheetState();
}

class _EditPhoneSheetState extends ConsumerState<_EditPhoneSheet> {
  late final TextEditingController _controller;
  String _status = 'idle'; // idle | submitting | error
  String _errorMsg = '';

  @override
  void initState() {
    super.initState();
    // Prefill with the existing phone so users just tweak instead of
    // retyping the country code.
    final existing =
        ref.read(userProfileProvider).valueOrNull?.phone ?? '';
    _controller = TextEditingController(text: existing);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final raw = _controller.text.trim();
    // Strip everything except digits and leading + for a clean E.164-
    // ish canonical form. Not enforcing a specific format — validation
    // will tighten when we wire real OTP.
    final cleaned = raw.replaceAll(RegExp(r'[^\d+]'), '');
    if (cleaned.isNotEmpty && cleaned.length < 7) {
      setState(() {
        _status = 'error';
        _errorMsg = 'Phone number looks too short.';
      });
      return;
    }

    setState(() {
      _status = 'submitting';
      _errorMsg = '';
    });

    final uid = ref.read(authStateProvider).valueOrNull?.id;
    if (uid == null) {
      setState(() {
        _status = 'error';
        _errorMsg = 'You need to be signed in.';
      });
      return;
    }

    try {
      await Supabase.instance.client
          .from('profiles')
          .update({'phone': cleaned.isEmpty ? null : cleaned})
          .eq('id', uid);
      // userProfileProvider is a realtime stream on the profile row —
      // it will re-emit with the new value; the Settings row rebuilds
      // automatically. Just close.
      if (!mounted) return;
      Navigator.of(context).pop();
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
    final submitting = _status == 'submitting';

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
            Text(
              'Phone number',
              style: theme.textTheme.titleMedium?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Kept private — never shown to other users. Support can '
              'use it to reach you if something goes wrong with a '
              'payment or your account.',
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
              keyboardType: TextInputType.phone,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _submit(),
              style: const TextStyle(color: Colors.white, fontSize: 15),
              decoration: InputDecoration(
                hintText: '+91 98765 43210',
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
                style: TextStyle(color: AppColors.error, fontSize: 12.5),
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
                    : const Text('Save'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
