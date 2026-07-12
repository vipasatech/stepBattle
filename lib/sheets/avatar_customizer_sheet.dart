import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fluttermoji/fluttermoji.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/colors.dart';
import '../providers/auth_provider.dart';

/// Full-screen sheet where the user builds their Bitmoji-style avatar.
///
/// UI layout:
///   • Large [FluttermojiCircleAvatar] preview at the top — reacts
///     live to every change the user makes in the customizer below.
///   • [FluttermojiCustomizer] tabbed picker (11 attribute tabs:
///     hair, hair colour, eyes, brows, mouth, skin, outfit, etc.).
///   • `Save avatar` primary button at the bottom — writes the
///     chosen spec to `profiles.avatar_config` in Supabase and pops.
///
/// Called from [showAvatarCustomizerIfNeeded] on the Create Battle
/// and Map entry points; `hasCompletedOnboardingProvider`-style
/// second-chance rule handles cancellation (the user can back out
/// but the sheet re-shows on the next protected entry).
///
/// **Persistence**: fluttermoji stores selections in
/// SharedPreferences under `fluttermojiSelectedOptions`. We mirror
/// that string into Supabase JSONB on save, and restore SharedPrefs
/// from Supabase on entry so a user who set their avatar on device A
/// sees the same spec when they customize on device B.
class AvatarCustomizerSheet extends ConsumerStatefulWidget {
  const AvatarCustomizerSheet({super.key});

  @override
  ConsumerState<AvatarCustomizerSheet> createState() =>
      _AvatarCustomizerSheetState();
}

class _AvatarCustomizerSheetState
    extends ConsumerState<AvatarCustomizerSheet> {
  bool _saving = false;
  bool _restoring = true;

  @override
  void initState() {
    super.initState();
    // If the user already has a spec on file, seed SharedPreferences
    // BEFORE we render the customizer so the tabs open on the user's
    // existing look rather than the default face.
    WidgetsBinding.instance.addPostFrameCallback((_) => _seedFromProfile());
  }

  Future<void> _seedFromProfile() async {
    final me = ref.read(currentUserProvider).valueOrNull;
    final cfg = me?.avatarConfig;
    if (cfg != null) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('fluttermojiSelectedOptions', jsonEncode(cfg));
    }
    if (mounted) setState(() => _restoring = false);
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      // Pull the current selections that fluttermoji has written to
      // SharedPreferences as a JSON string.
      final specString =
          await FluttermojiFunctions().encodeMySVGtoString();
      final Map<String, dynamic> spec = jsonDecode(specString);

      final me = ref.read(currentUserProvider).valueOrNull;
      if (me == null) return;
      await ref.read(authServiceProvider).updateAvatarConfig(
            userId: me.userId,
            config: spec,
          );
      // Bust the profile stream so the new avatar shows up
      // immediately on the caller's next frame.
      ref.invalidate(currentUserProvider);
      if (mounted) Navigator.of(context).pop(true);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Couldn't save avatar. Try again.")),
        );
        setState(() => _saving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: _restoring
            ? const Center(child: CircularProgressIndicator())
            : Column(
                children: [
                  // ---- Header ------------------------------------
                  Padding(
                    padding:
                        const EdgeInsets.fromLTRB(12, 8, 12, 0),
                    child: Row(
                      children: [
                        IconButton(
                          icon: Icon(Icons.close,
                              color: theme.colorScheme.onSurface),
                          onPressed: _saving
                              ? null
                              : () => Navigator.of(context).pop(false),
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            'Design your avatar',
                            style: theme.textTheme.titleLarge?.copyWith(
                              color: theme.colorScheme.onSurface,
                              fontWeight: FontWeight.w900,
                              letterSpacing: -0.4,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),

                  // ---- Live preview -------------------------------
                  Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: AppColors.primary.withValues(alpha: 0.35),
                          blurRadius: 30,
                          spreadRadius: 3,
                        ),
                      ],
                    ),
                    child: FluttermojiCircleAvatar(
                      radius: 70,
                      backgroundColor:
                          AppColors.surfaceContainerHigh,
                    ),
                  ),
                  const SizedBox(height: 16),

                  // ---- Customizer tabs (expands to fill) ----------
                  Expanded(
                    // FluttermojiCustomizer isn't const, so this
                    // wrapper can't be either.
                    child: FluttermojiCustomizer(
                      // `autosave: true` writes each change back to
                      // SharedPreferences immediately so our final
                      // `encodeMySVGtoString()` read on Save picks
                      // up the latest state.
                      autosave: true,
                    ),
                  ),

                  // ---- Save CTA ----------------------------------
                  Padding(
                    padding:
                        const EdgeInsets.fromLTRB(20, 8, 20, 20),
                    child: SizedBox(
                      width: double.infinity,
                      height: 54,
                      child: FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: AppColors.primary,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(999),
                          ),
                        ),
                        onPressed: _saving ? null : _save,
                        child: _saving
                            ? const SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.5,
                                  color: Colors.white,
                                ),
                              )
                            : Text(
                                'Save avatar',
                                style: theme.textTheme.titleMedium
                                    ?.copyWith(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

/// Shows [AvatarCustomizerSheet] if the signed-in user hasn't set up
/// their fluttermoji spec yet. No-op when [UserModel.avatarConfig] is
/// already populated. Returns `true` when the user saved a spec in
/// this invocation, `false` otherwise (cancelled or already had one).
///
/// Call at the top of any flow that wants the user's avatar rendered
/// as a Bitmoji character — currently Create Battle and Map entry.
Future<bool> showAvatarCustomizerIfNeeded(
  BuildContext context,
  WidgetRef ref,
) async {
  final me = ref.read(currentUserProvider).valueOrNull;
  if (me == null) return false;
  if (me.avatarConfig != null) return false;
  final result = await Navigator.of(context, rootNavigator: true).push<bool>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => const AvatarCustomizerSheet(),
    ),
  );
  return result == true;
}
