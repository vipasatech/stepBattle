import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../config/colors.dart';
import '../../providers/clan_provider.dart';
import '../../widgets/friends_app_bar_button.dart';
import 'clan_entry_view.dart';
import 'clan_dashboard_view.dart';

/// Clan tab — switches between entry state (no clan) and dashboard (has clan).
class ClanScreen extends ConsumerWidget {
  const ClanScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasClan = ref.watch(hasClanProvider);
    final clan = ref.watch(currentClanProvider).valueOrNull;

    return Scaffold(
      appBar: AppBar(
        title: hasClan && clan != null
            ? Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: AppColors.primaryContainer,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.shield,
                        color: AppColors.onPrimary, size: 20),
                  ),
                  const SizedBox(width: 10),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(clan.name.toUpperCase(),
                          style:
                              Theme.of(context).textTheme.titleMedium?.copyWith(
                                    color: AppColors.primaryBrand,
                                    fontWeight: FontWeight.w900,
                                    fontStyle: FontStyle.italic,
                                  )),
                      Text('${clan.memberCount} / ${clan.maxMembers} members',
                          style: Theme.of(context)
                              .textTheme
                              .labelSmall
                              ?.copyWith(color: AppColors.onSurfaceVariant)),
                    ],
                  ),
                ],
              )
            : Row(
                children: [
                  Icon(Icons.sports_kabaddi,
                      color: AppColors.primaryBrand, size: 24),
                  const SizedBox(width: 8),
                  Text('CLAN',
                      style:
                          Theme.of(context).textTheme.headlineSmall?.copyWith(
                                color: AppColors.primaryBrand,
                                fontWeight: FontWeight.w700,
                              )),
                ],
              ),
        actions: [
          // Friends hub — discoverable from any tab. Same widget + badge
          // as the Home AppBar.
          const FriendsAppBarButton(),
          const SizedBox(width: 8),
          if (hasClan)
            IconButton(
              icon: const Icon(Icons.settings, color: AppColors.onSurfaceVariant),
              tooltip: 'Clan details',
              onPressed: () => context.go('/clan/details'),
            ),
        ],
      ),
      body: hasClan ? const ClanDashboardView() : const ClanEntryView(),
    );
  }
}
