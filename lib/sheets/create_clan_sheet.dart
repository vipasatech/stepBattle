import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../config/colors.dart';
import '../config/constants.dart';
import '../models/user_model.dart';
import '../providers/clan_provider.dart';
import '../widgets/bottom_sheet_handle.dart';
import 'add_friends_sheet.dart';

class CreateClanSheet extends ConsumerStatefulWidget {
  const CreateClanSheet({super.key});

  @override
  ConsumerState<CreateClanSheet> createState() => _CreateClanSheetState();
}

class _CreateClanSheetState extends ConsumerState<CreateClanSheet> {
  final _nameController = TextEditingController();
  final List<UserModel> _invitedMembers = [];
  bool _creating = false;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  bool get _isValid {
    final name = _nameController.text.trim();
    return name.length >= AppConstants.clanNameMinLength &&
        name.length <= AppConstants.clanNameMaxLength;
  }

  void _openAddFriends() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => AddFriendsSheet(
        multiSelect: true,
        confirmLabel: 'Add to Clan',
        onConfirm: (selected) =>
            setState(() => _invitedMembers
              ..clear()
              ..addAll(selected)),
      ),
    );
  }

  Future<void> _create() async {
    if (!_isValid) return;
    setState(() => _creating = true);

    try {
      final uid = FirebaseAuth.instance.currentUser!.uid;
      await ref.read(clanServiceProvider).createClan(
            name: _nameController.text.trim(),
            captainId: uid,
            invitedUserIds:
                _invitedMembers.map((u) => u.userId).toList(),
          );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _invitedMembers.isEmpty
                  ? 'Clan created!'
                  : 'Clan created! Invites sent to ${_invitedMembers.length} friend${_invitedMembers.length == 1 ? '' : 's'}.',
            ),
          ),
        );
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final name = _nameController.text.trim();

    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surfaceContainer,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
            24, 0, 24, 32 + MediaQuery.of(context).viewInsets.bottom),
        child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const BottomSheetHandle(),

          Text('Create a Clan',
              style: theme.textTheme.headlineMedium
                  ?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text('Build your squad and dominate together',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: AppColors.onSurfaceVariant)),

          const SizedBox(height: 28),

          // Clan name field
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('CLAN NAME',
                  style: theme.textTheme.labelMedium
                      ?.copyWith(color: AppColors.onSurfaceVariant)),
              Text('${name.length} / ${AppConstants.clanNameMaxLength}',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: AppColors.onSurfaceVariant)),
            ],
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _nameController,
            maxLength: AppConstants.clanNameMaxLength,
            style: theme.textTheme.bodyLarge,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              hintText: 'Enter clan name...',
              counterText: '',
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '${AppConstants.clanNameMinLength}\u2013${AppConstants.clanNameMaxLength} characters, letters and numbers only',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: AppColors.outline),
          ),

          const SizedBox(height: 24),

          // Add members section
          Text('ADD MEMBERS',
              style: theme.textTheme.labelMedium
                  ?.copyWith(color: AppColors.onSurfaceVariant)),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            height: 50,
            child: OutlinedButton.icon(
              onPressed: _openAddFriends,
              icon: const Icon(Icons.person_add, size: 18),
              label: Text(_invitedMembers.isEmpty
                  ? '+ Add Friends'
                  : '${_invitedMembers.length} invited · Tap to edit'),
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: AppColors.primary),
                foregroundColor: AppColors.primary,
              ),
            ),
          ),
          const SizedBox(height: 4),
          Center(
            child: Text('Invite friends to join your clan',
                style: theme.textTheme.bodySmall?.copyWith(
                    color: AppColors.onSurfaceVariant,
                    fontStyle: FontStyle.italic)),
          ),

          const SizedBox(height: 32),

          // Buttons
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 52,
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancel'),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: SizedBox(
                  height: 52,
                  child: FilledButton(
                    onPressed: _isValid && !_creating ? _create : null,
                    style: FilledButton.styleFrom(
                      disabledBackgroundColor:
                          AppColors.onSurfaceVariant.withValues(alpha: 0.3),
                    ),
                    child: _creating
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white))
                        : const Text('Create'),
                  ),
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
