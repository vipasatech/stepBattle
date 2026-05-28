-- =============================================================================
-- StepBattle — relax cross-user write policies on battle_participants and
-- clan_members so the activation/completion (battles) and promote/demote/
-- transfer-captaincy (clans) flows work.
--
-- THE BUG:
--   The 0001 policies allowed updates only when `auth.uid() = user_id`.
--   But the lifecycle code (BattleService._activateBattle,
--   .completeExpiredBattles; ClanService.promoteToAdmin,
--   transferCaptaincy, etc.) writes other participants' / members' rows
--   from a single device. Those writes were silently denied, leaving rows
--   with half-filled baselines / stale roles.
--
-- THE FIX:
--   • battle_participants — any participant of the same battle can update
--     any row in that battle (snapshots, current_steps, is_winner, etc.).
--   • clan_members         — captain of the clan can update any member row
--     (role changes); self updates remain allowed (for steps_today).
--
-- These match how the existing client code is structured. Production
-- hardening would push the multi-row writes into Edge Functions and keep
-- RLS strictly self-only, but for the current MVP the trust-the-client
-- contract is acceptable.
--
-- HOW TO APPLY:
--   Supabase Dashboard → SQL Editor → New query → paste → Run.
-- =============================================================================

-- battle_participants ----------------------------------------------------------
drop policy if exists "battle_participants_update_self"
  on public.battle_participants;

create policy "battle_participants_update_co_participants"
  on public.battle_participants for update to authenticated
  using (
    exists (
      select 1 from public.battle_participants p
      where p.battle_id = battle_participants.battle_id
        and p.user_id = auth.uid()
    )
  )
  with check (
    exists (
      select 1 from public.battle_participants p
      where p.battle_id = battle_participants.battle_id
        and p.user_id = auth.uid()
    )
  );

-- clan_members ----------------------------------------------------------------
drop policy if exists "clan_members_self_update" on public.clan_members;

create policy "clan_members_update_self_or_captain"
  on public.clan_members for update to authenticated
  using (
    auth.uid() = user_id
    or exists (
      select 1 from public.clans c
      where c.id = clan_members.clan_id and c.captain_id = auth.uid()
    )
  )
  with check (
    auth.uid() = user_id
    or exists (
      select 1 from public.clans c
      where c.id = clan_members.clan_id and c.captain_id = auth.uid()
    )
  );
