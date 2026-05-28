-- =============================================================================
-- StepBattle — extend clans + clan_battles with denormalized fields the
-- existing UI consumes (total_clan_xp, active_battle_id, max_members on
-- clans; duration_days, xp_per_member, winner_clan_id on clan_battles).
--
-- HOW TO APPLY:
--   Supabase Dashboard → SQL Editor → New query → paste → Run.
--   Safe to re-run.
-- =============================================================================

alter table public.clans
  add column if not exists total_clan_xp integer not null default 0,
  add column if not exists active_battle_id uuid,
  add column if not exists max_members integer not null default 10;

-- FK for active_battle_id (added after column exists so we can use IF NOT EXISTS
-- via the same pattern we used for profiles.clan_id).
do $$ begin
  if not exists (
    select 1 from pg_constraint where conname = 'clans_active_battle_id_fkey'
  ) then
    alter table public.clans
      add constraint clans_active_battle_id_fkey
      foreign key (active_battle_id)
      references public.clan_battles(id)
      on delete set null;
  end if;
end $$;

alter table public.clan_battles
  add column if not exists duration_days integer not null default 3,
  add column if not exists xp_per_member integer not null default 300,
  add column if not exists winner_clan_id uuid references public.clans(id) on delete set null;
