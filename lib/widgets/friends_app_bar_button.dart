import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../config/colors.dart';
import '../providers/friend_provider.dart';
import '../sheets/add_friends_sheet.dart';

/// AppBar action that opens the Friends Hub sheet (manage mode).
///
/// Shows a primary-colored badge with the count of incoming pending
/// friend requests. Auto-lands on the Requests tab when there's something
/// to act on; otherwise lands on the Friends tab.
///
/// Use this anywhere you want a discoverable Friends entry point —
/// currently surfaced on Home and Clan tab AppBars.
class FriendsAppBarButton extends ConsumerWidget {
  const FriendsAppBarButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pendingCount = ref.watch(incomingRequestCountProvider);

    return GestureDetector(
      onTap: () => showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        // Push to the root navigator so the sheet's bottom action area
        // sits above the shell's bottom nav (extendBody: true on shell).
        useRootNavigator: true,
        backgroundColor: Colors.transparent,
        builder: (_) => AddFriendsSheet(
          mode: FriendsSheetMode.manage,
          initialTab: pendingCount > 0 ? 2 : 0,
        ),
      ),
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: AppColors.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            const Icon(Icons.group_outlined,
                color: AppColors.onSurface, size: 20),
            if (pendingCount > 0)
              Positioned(
                top: -4,
                right: -4,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                  constraints:
                      const BoxConstraints(minWidth: 16, minHeight: 16),
                  decoration: BoxDecoration(
                    color: AppColors.primary,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                        color: AppColors.background, width: 1.5),
                  ),
                  child: Text(
                    pendingCount > 9 ? '9+' : '$pendingCount',
                    style: const TextStyle(
                      fontSize: 9,
                      fontWeight: FontWeight.w900,
                      color: AppColors.onPrimary,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
