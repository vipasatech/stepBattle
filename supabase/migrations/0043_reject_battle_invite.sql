-- =============================================================================
-- Migration 0043: reject_battle_invite RPC
-- =============================================================================
--
-- Prior client behavior: an invitee tapping Reject on a 1v1 battle
-- called `refund_battle_stakes` directly. That RPC enforces
-- `auth.uid() = created_by` server-side, so the invitee's call always
-- threw. The client's empty catch swallowed the error and the button
-- looked dead.
--
-- This migration adds a single SECURITY DEFINER RPC that owns the
-- full reject flow: flips the caller's participant row to 'rejected',
-- and for 1v1 also cancels the battle + refunds every paid stake via
-- credit_user_xp + notifies the creator. Callable only by the
-- participant on their own row (auth.uid() = p_user_id).
--
-- HOW TO APPLY: Dashboard → SQL Editor → paste → Run. Idempotent.
--
-- NOTE: Migration 0047 later rewrote this function to route its refund
-- credit through `_credit_xp_admin` instead of `credit_user_xp` (once
-- the deployed `credit_user_xp` policy started rejecting cross-user
-- and restricted-reason writes). Applying this file followed by 0047
-- arrives at the current live state.
-- =============================================================================

create or replace function public.reject_battle_invite(
  p_battle_id uuid,
  p_user_id   uuid
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_type          text;
  v_status        text;
  v_stake_xp      integer;
  v_created_by    uuid;
  v_my_status     text;
  r               record;
begin
  -- Only the participant themselves may reject on their behalf.
  if auth.uid() is null or auth.uid() <> p_user_id then
    raise exception 'not_authorized: rejecter must match caller';
  end if;

  select b.type, b.status, coalesce(b.stake_xp, 0), b.created_by
    into v_type, v_status, v_stake_xp, v_created_by
    from public.battles b
   where b.id = p_battle_id;

  if v_type is null then
    raise exception 'battle_not_found: %', p_battle_id;
  end if;

  -- No-op if the battle already moved past pending.
  if v_status <> 'pending' then
    return;
  end if;

  select bp.invite_status into v_my_status
    from public.battle_participants bp
   where bp.battle_id = p_battle_id and bp.user_id = p_user_id;

  if v_my_status is null or v_my_status <> 'pending' then
    return;
  end if;

  update public.battle_participants
     set invite_status = 'rejected'
   where battle_id = p_battle_id and user_id = p_user_id;

  if v_type = '1v1' then
    -- Cancel the battle first so any late accept races fail.
    update public.battles
       set status = 'cancelled'
     where id = p_battle_id;

    if v_stake_xp > 0 then
      for r in
        select user_id
          from public.battle_participants
         where battle_id = p_battle_id
           and stake_paid = true
      loop
        perform public.credit_user_xp(
          r.user_id,
          v_stake_xp,
          'battle_refund',
          jsonb_build_object(
            'battle_id', p_battle_id,
            'trigger',   'invitee_rejected'
          )
        );
        update public.battle_participants
           set stake_paid = false
         where battle_id = p_battle_id and user_id = r.user_id;
      end loop;
    end if;

    -- Notify the creator (skip if the creator rejected themselves,
    -- which shouldn't happen for a 1v1 but guarded defensively).
    if v_created_by <> p_user_id then
      insert into public.notifications
        (user_id, type, title, body, data)
      values (
        v_created_by,
        'battle_rejected',
        'Battle Declined',
        'Your opponent declined the battle',
        jsonb_build_object(
          'battle_id',    p_battle_id,
          'from_user_id', p_user_id
        )
      );
    end if;
  end if;
  -- Group/team rejections just flip the row; existing activation logic
  -- picks up "everyone remaining is accepted" via the accept path.
end;
$$;

revoke all on function public.reject_battle_invite(uuid, uuid) from public;
grant execute on function public.reject_battle_invite(uuid, uuid) to authenticated;
