import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/colors.dart';
import '../providers/auth_provider.dart';
import '../providers/user_provider.dart';
import '../utils/account_deletion.dart';
import '../utils/app_logger.dart';

/// Full-height bottom sheet gating account deletion.
///
/// Deletion is *irreversible*, so we require the user to type their
/// own userCode (e.g. `#U4X92`) exactly to unlock the destructive
/// button. Once triggered, the client:
///   1. Calls POST /api/user-delete on the website (JWT-authorised —
///      the endpoint reads the caller's uid from the token, so the
///      body can't spoof a different user).
///   2. Server does DELETE FROM profiles WHERE id = uid, relying on
///      the ON DELETE CASCADE foreign keys on step_logs,
///      user_mission_progress, friend_relationships, etc. to sweep
///      the rest.
///   3. Server calls supabase.auth.admin.deleteUser(uid) to remove
///      the auth row too.
///   4. Client closes this sheet, raises [AccountDeletion] so the
///      router routes to /welcome, then signs out. The flag — not this
///      sheet — owns the navigation; see [_confirmDelete].
Future<void> showDeleteAccountSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    useRootNavigator: true,
    isScrollControlled: true,
    builder: (_) => const _DeleteAccountSheet(),
  );
}

class _DeleteAccountSheet extends ConsumerStatefulWidget {
  const _DeleteAccountSheet();

  @override
  ConsumerState<_DeleteAccountSheet> createState() =>
      _DeleteAccountSheetState();
}

class _DeleteAccountSheetState extends ConsumerState<_DeleteAccountSheet> {
  final _typedCode = TextEditingController();
  String _status = 'idle'; // idle | deleting | error
  String _errorMsg = '';

  @override
  void initState() {
    super.initState();
    // Rebuild on every keystroke so the destructive button flips to
    // enabled the instant the typed code matches.
    _typedCode.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _typedCode.dispose();
    super.dispose();
  }

  Future<void> _confirmDelete() async {
    setState(() {
      _status = 'deleting';
      _errorMsg = '';
    });

    // Capture everything that needs `ref` up front, while this sheet is
    // guaranteed mounted. The delete POST below is a network round-trip
    // the user can dismiss the sheet during, and the router's redirect
    // can tear it down too — `ref` on a disposed ConsumerState throws,
    // which is how the entire post-delete path used to die silently.
    //
    // `signOut()` is not just a token clear: it stops the foreground
    // service, cancels the alarm schedule, drops the FCM token-refresh
    // listener, signs out of Google and wipes every repository cache.
    // Skipping it would leave background isolates syncing for a deleted
    // user, so it has to run whether or not this widget survives.
    final authService = ref.read(authServiceProvider);

    final session = Supabase.instance.client.auth.currentSession;
    final token = session?.accessToken;
    final uid = session?.user.id;
    if (token == null || uid == null) {
      setState(() {
        _status = 'error';
        _errorMsg = 'Session expired. Sign in again.';
      });
      return;
    }

    try {
      final res = await http.post(
        Uri.parse('https://www.stepbattle.fit/api/user-delete'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
      );
      if (res.statusCode != 200) {
        throw Exception('Server returned ${res.statusCode}: ${res.body}');
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _status = 'error';
        _errorMsg = e.toString();
      });
      return;
    }

    // Deletion succeeded server-side. Three things now have to happen,
    // in this order, and the ordering is the whole fix (2026-11-02).
    //
    // 1. CLOSE THE SHEET — while we still unambiguously own this route.
    //    Once the flag in step 2 moves the page underneath us, go_router
    //    pops imperatively-pushed routes whose page has left, and that
    //    teardown would race our own pop.
    if (mounted) {
      // `isCurrent` guards the narrow case where the profile row's
      // realtime delete beat the HTTP response and a redirect already
      // pushed something over us — popping then would dismiss that
      // instead of this sheet.
      final route = ModalRoute.of(context);
      if (route?.isCurrent ?? false) Navigator.of(context).pop();
    }

    // 2. RAISE THE DELETION FLAG — synchronously, before any further
    //    await. From here until the session clears, this device is
    //    authenticated with no profile row, which by provider values
    //    alone is indistinguishable from a fresh signup. The flag is
    //    the only thing that tells the router which of the two it's
    //    looking at; its listener drives the redirect to /welcome
    //    immediately, so navigation no longer depends on how long
    //    sign-out takes. See [AccountDeletion] for the full rationale
    //    and for the three race-based attempts this replaces.
    AccountDeletion.begin(uid);

    // 3. SIGN OUT — via the service captured at the top of this method,
    //    so it runs even if this widget is already gone. A failure here
    //    is survivable and must not be silent: the auth row is already
    //    deleted server-side so the token is worthless, and the flag
    //    keeps the router on /welcome regardless. `AccountDeletion` is
    //    scoped to this uid precisely so a stuck flag can't trap a
    //    later signup on this device.
    try {
      await authService.signOut();
    } catch (e) {
      AppLogger.auth.w('deleteAccount:signOutFailed', fields: {
        'uid': uid,
        'error': e.toString(),
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final userCode =
        ref.watch(userProfileProvider).valueOrNull?.userCode ?? '';
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    final matches = userCode.isNotEmpty &&
        _typedCode.text.trim().toUpperCase() ==
            userCode.trim().toUpperCase();
    final deleting = _status == 'deleting';

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
            Row(
              children: [
                Icon(Icons.warning_amber_rounded,
                    color: AppColors.error, size: 22),
                const SizedBox(width: 8),
                Text(
                  'Delete your account',
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              'This is permanent. We\'ll erase your profile, step '
              'history, battles, missions, streaks, and any payment '
              'history tied to your account. You can\'t undo this — '
              'the same email will start from zero if you sign up '
              'again.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: Colors.white.withValues(alpha: 0.7),
                height: 1.55,
              ),
            ),
            const SizedBox(height: 18),
            Text(
              'Type your code to confirm',
              style: theme.textTheme.labelMedium?.copyWith(
                color: Colors.white.withValues(alpha: 0.75),
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              userCode.isEmpty ? '(no code on file)' : userCode,
              style: TextStyle(
                color: AppColors.primary,
                fontFamily: 'Space Grotesk',
                fontSize: 20,
                fontWeight: FontWeight.w900,
                letterSpacing: 2,
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _typedCode,
              enabled: !deleting && userCode.isNotEmpty,
              autofocus: true,
              autocorrect: false,
              textCapitalization: TextCapitalization.characters,
              style: const TextStyle(
                color: Colors.white,
                fontFamily: 'Space Grotesk',
                fontSize: 18,
                letterSpacing: 2,
              ),
              decoration: InputDecoration(
                hintText: userCode.isEmpty ? '' : '#XXXXX',
                hintStyle: TextStyle(
                  color: Colors.white.withValues(alpha: 0.3),
                  letterSpacing: 2,
                ),
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
                  borderSide: BorderSide(
                    color: matches ? AppColors.error : AppColors.primary,
                  ),
                ),
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: 14, vertical: 14),
              ),
            ),
            if (_status == 'error') ...[
              const SizedBox(height: 8),
              Text(
                _errorMsg,
                style:
                    TextStyle(color: AppColors.error, fontSize: 12.5),
              ),
            ],
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed:
                        deleting ? null : () => Navigator.of(context).pop(),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                      side: BorderSide(
                        color: Colors.white.withValues(alpha: 0.2),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 13),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: const Text('Cancel'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton(
                    onPressed: (matches && !deleting)
                        ? () => _confirmDelete()
                        : null,
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.error,
                      disabledBackgroundColor:
                          AppColors.error.withValues(alpha: 0.3),
                      padding: const EdgeInsets.symmetric(vertical: 13),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: deleting
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation<Color>(
                                  Colors.white),
                            ),
                          )
                        : const Text('Delete forever'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
