/// Family-Pass membership state — one row per (owner, member) pair in
/// `public.family_memberships` (migration 0031).
///
/// The FAMILY OWNER is NOT stored here — they're implicit
/// (`profiles.subscription_tier = 'family'` and
/// `profiles.family_owner_id = null`). Each row in this table
/// represents an ADDITIONAL seat granted to another user, up to 3
/// active seats per owner (4 total including the owner).
library;

enum FamilyMembershipStatus {
  /// Owner has invited; member has not responded yet.
  pending,

  /// Member accepted; they get Family-tier entitlements.
  active,

  /// Owner booted OR member left OR owner's subscription lapsed. The
  /// member has been reverted to Free.
  removed,

  /// Member said "no thanks" to the invite. Owner can re-invite later.
  declined;

  String get wire => name;

  static FamilyMembershipStatus fromWire(String? s) => switch (s) {
        'active' => FamilyMembershipStatus.active,
        'removed' => FamilyMembershipStatus.removed,
        'declined' => FamilyMembershipStatus.declined,
        _ => FamilyMembershipStatus.pending,
      };
}

/// How the invite was created — a v2 hook for tracking which of the
/// three invite paths was most used. All V1 traffic flows through
/// `userCode`.
enum FamilyInvitedVia {
  userCode,
  email,
  shareLink;

  String get wire => switch (this) {
        FamilyInvitedVia.userCode => 'user_code',
        FamilyInvitedVia.email => 'email',
        FamilyInvitedVia.shareLink => 'share_link',
      };

  static FamilyInvitedVia fromWire(String? s) => switch (s) {
        'email' => FamilyInvitedVia.email,
        'share_link' => FamilyInvitedVia.shareLink,
        _ => FamilyInvitedVia.userCode,
      };
}

class FamilyMembership {
  final String id;
  final String ownerId;
  final String memberId;
  final FamilyMembershipStatus status;
  final FamilyInvitedVia invitedVia;
  final DateTime invitedAt;
  final DateTime? acceptedAt;
  final DateTime? removedAt;

  const FamilyMembership({
    required this.id,
    required this.ownerId,
    required this.memberId,
    required this.status,
    required this.invitedVia,
    required this.invitedAt,
    this.acceptedAt,
    this.removedAt,
  });

  bool get isPending => status == FamilyMembershipStatus.pending;
  bool get isActive => status == FamilyMembershipStatus.active;

  factory FamilyMembership.fromSupabaseRow(Map<String, dynamic> d) {
    DateTime? ts(Object? raw) =>
        raw == null ? null : DateTime.tryParse(raw.toString());
    return FamilyMembership(
      id: d['id'] as String? ?? '',
      ownerId: d['owner_id'] as String? ?? '',
      memberId: d['member_id'] as String? ?? '',
      status: FamilyMembershipStatus.fromWire(d['status'] as String?),
      invitedVia: FamilyInvitedVia.fromWire(d['invited_via'] as String?),
      invitedAt: ts(d['invited_at']) ?? DateTime.now(),
      acceptedAt: ts(d['accepted_at']),
      removedAt: ts(d['removed_at']),
    );
  }
}
