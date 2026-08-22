// [3D-DISABLED-2026-08-21] — See lib/models/character_3d.dart header for
// re-enable checklist. Whole file dormant.

/*
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/colors.dart';
import '../models/character_3d.dart';
import '../providers/auth_provider.dart';
import '../providers/character_3d_provider.dart';
import '../providers/user_provider.dart';
import '../widgets/animated_character_viewer.dart';
import '../widgets/bottom_sheet_handle.dart';

/// Bottom sheet that lets the user pick their 3D character. Backed by the
/// closed catalog in [Character3D.catalog] (2 entries — female / male).
///
/// UX:
///   • Big live 3D preview of the currently-selected character (~360 dp
///     tall). Only ONE Flutter3DViewer is instantiated at a time — the
///     `key` on the viewer forces a fresh WebView when the user toggles
///     between characters, and there's never more than one running.
///   • Two pill buttons below (Female / Male) toggle which character is
///     previewed above.
///   • "Save" persists via `SupabaseAuthService.updateCharacter3D` — the
///     value goes to `profiles.character_3d_id` so opponents see it too.
class Character3DPickerSheet extends ConsumerStatefulWidget {
  const Character3DPickerSheet({super.key});

  @override
  ConsumerState<Character3DPickerSheet> createState() =>
      _Character3DPickerSheetState();
}

class _Character3DPickerSheetState
    extends ConsumerState<Character3DPickerSheet> {
  late Character3D _selected;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    // Seed from the currently-resolved character (explicit pick OR gender
    // fallback). No async setup needed — provider is synchronous.
    _selected = ref.read(currentCharacter3DProvider);
  }

  Future<void> _save() async {
    final me = ref.read(userProfileProvider).valueOrNull;
    if (me == null) return;
    // No-op short-circuit — same id already on the profile.
    if (_selected.id == me.character3dId) {
      Navigator.of(context).pop(_selected);
      return;
    }
    setState(() => _saving = true);
    try {
      await ref.read(authServiceProvider).updateCharacter3D(
            userId: me.userId,
            characterId: _selected.id,
          );
      // Invalidate so watchers (home showcase, arena band, this sheet)
      // pick up the new selection immediately.
      ref.invalidate(userProfileProvider);
      if (mounted) Navigator.of(context).pop(_selected);
    } catch (_) {
      if (mounted) setState(() => _saving = false);
      rethrow;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DraggableScrollableSheet(
      initialChildSize: 0.9,
      minChildSize: 0.6,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) => Container(
        decoration: BoxDecoration(
          color: AppColors.surfaceContainer,
          borderRadius:
              const BorderRadius.vertical(top: Radius.circular(28)),
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
                    'Pick your character',
                    style: theme.textTheme.headlineSmall
                        ?.copyWith(fontWeight: FontWeight.w900),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Your 3D avatar for the Home screen showcase. '
                    'Change any time.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: AppColors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            // Live 3D preview of the selected character.
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(20),
                  child: Container(
                    color: AppColors.surfaceContainerLow,
                    // `ValueKey` forces a fresh WebView when the user
                    // toggles between M/F; reusing the widget with a new
                    // `src` doesn't reliably swap the loaded model in
                    // some versions of the pkg.
                    child: AnimatedCharacterViewer(
                      key: ValueKey('picker-${_selected.id}'),
                      glbAssetPath: _selected.glbAssetPath,
                      progressBarColor: AppColors.primary,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            // 2×2 grid of character pills. Layout stays hand-rolled with
            // Rows so we can wrap-safely on very-narrow screens without
            // pulling in GridView + shrinkWrap complications inside the
            // scroll sheet.
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Column(
                children: [
                  for (var i = 0; i < Character3D.catalog.length; i += 2)
                    Padding(
                      padding: EdgeInsets.only(
                        top: i == 0 ? 0 : 12,
                      ),
                      child: Row(
                        children: [
                          Expanded(child: _CharacterPill(
                            character: Character3D.catalog[i],
                            isSelected: Character3D.catalog[i].id == _selected.id,
                            onTap: () => setState(
                                () => _selected = Character3D.catalog[i]),
                          )),
                          if (i + 1 < Character3D.catalog.length) ...[
                            const SizedBox(width: 12),
                            Expanded(child: _CharacterPill(
                              character: Character3D.catalog[i + 1],
                              isSelected: Character3D.catalog[i + 1].id == _selected.id,
                              onTap: () => setState(
                                  () => _selected = Character3D.catalog[i + 1]),
                            )),
                          ],
                        ],
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
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

class _CharacterPill extends StatelessWidget {
  final Character3D character;
  final bool isSelected;
  final VoidCallback onTap;

  const _CharacterPill({
    required this.character,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: isSelected
              ? AppColors.primary.withValues(alpha: 0.15)
              : AppColors.surfaceContainerLow,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isSelected ? AppColors.primary : AppColors.outlineVariant,
            width: isSelected ? 2 : 1,
          ),
        ),
        child: Center(
          child: Text(
            character.label,
            style: theme.textTheme.labelLarge?.copyWith(
              fontWeight: FontWeight.w800,
              color: isSelected
                  ? AppColors.primary
                  : AppColors.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}

/// Convenience opener — same signature as [showAvatarPickerSheet]. Returns
/// the newly-saved [Character3D], or `null` if the user dismissed.
Future<Character3D?> showCharacter3DPickerSheet(BuildContext context) {
  return showModalBottomSheet<Character3D>(
    context: context,
    isScrollControlled: true,
    useRootNavigator: true,
    backgroundColor: Colors.transparent,
    builder: (_) => const Character3DPickerSheet(),
  );
}
*/
