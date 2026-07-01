import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/colors.dart';
import '../models/avatar.dart';
import '../providers/auth_provider.dart';
import '../widgets/bottom_sheet_handle.dart';

/// Bottom sheet that lets the user choose their battle-ground avatar
/// (migration 0019). Backed by the closed catalog in [Avatar.catalog].
///
/// UX:
///   • 3-column grid of all 12 avatars on a transparent background.
///   • Tap to preview a selection (no commit yet — the user can switch
///     freely without writing to the network).
///   • "Save" persists `profiles.battle_avatar_id` via the auth service.
///   • The current selection ring uses the brand primary; the rest sit
///     on the standard surface chip background.
///
/// Returned future resolves to the saved id (or null if the user cancels).
class AvatarPickerSheet extends ConsumerStatefulWidget {
  const AvatarPickerSheet({super.key});

  @override
  ConsumerState<AvatarPickerSheet> createState() => _AvatarPickerSheetState();
}

class _AvatarPickerSheetState extends ConsumerState<AvatarPickerSheet> {
  late String _selected;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // Seed from the current user's stored selection (defaults to
    // 'avatar_01' for legacy rows). Reading at init time is fine — the
    // sheet is short-lived and we don't need to react to live changes
    // from elsewhere mid-pick.
    final me = ref.read(currentUserProvider).valueOrNull;
    _selected = me?.battleAvatarId ?? Avatar.defaultAvatar.id;
  }

  Future<void> _save() async {
    final me = ref.read(currentUserProvider).valueOrNull;
    if (me == null) return;
    if (_selected == me.battleAvatarId) {
      // No-op save → just close. Avoids a wasted network call.
      Navigator.of(context).pop(_selected);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref.read(authServiceProvider).updateBattleAvatar(
            userId: me.userId,
            avatarId: _selected,
          );
      // Invalidate so subsequent reads reflect the new selection — the
      // arena screen reads currentUserProvider for "is this my avatar?".
      ref.invalidate(currentUserProvider);
      if (mounted) Navigator.of(context).pop(_selected);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DraggableScrollableSheet(
      initialChildSize: 0.85,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) => Container(
        decoration: BoxDecoration(
          color: AppColors.surfaceContainer,
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
        child: Column(
          children: [
            const BottomSheetHandle(),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Pick your runner',
                    style: theme.textTheme.headlineSmall
                        ?.copyWith(fontWeight: FontWeight.w900),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'This is how you\'ll appear on the battle ground. Changeable any time.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: AppColors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: GridView.builder(
                controller: scrollController,
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
                gridDelegate:
                    const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 12,
                  childAspectRatio: 0.85,
                ),
                itemCount: Avatar.catalog.length,
                itemBuilder: (_, i) {
                  final a = Avatar.catalog[i];
                  final isSelected = a.id == _selected;
                  return GestureDetector(
                    onTap: () => setState(() => _selected = a.id),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      decoration: BoxDecoration(
                        color: isSelected
                            ? AppColors.primary.withValues(alpha: 0.15)
                            : AppColors.surfaceContainerLow,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: isSelected
                              ? AppColors.primary
                              : AppColors.outlineVariant,
                          width: isSelected ? 2 : 1,
                        ),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: Column(
                          children: [
                            Expanded(
                              child: Image.asset(
                                a.assetPath,
                                fit: BoxFit.contain,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              a.label,
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: isSelected
                                    ? AppColors.primary
                                    : AppColors.onSurfaceVariant,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Text(
                  _error!,
                  style: TextStyle(color: AppColors.error),
                  maxLines: 2,
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
              child: SizedBox(
                width: double.infinity,
                height: 52,
                child: FilledButton(
                  onPressed: _saving ? null : _save,
                  child: _saving
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        )
                      : const Text('Save'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Convenience opener — opens the sheet over the root navigator (so it
/// sits above the bottom-nav bar) and returns the new selected id, or
/// null if cancelled.
Future<String?> showAvatarPickerSheet(BuildContext context) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    useRootNavigator: true,
    backgroundColor: Colors.transparent,
    builder: (_) => const AvatarPickerSheet(),
  );
}
