-- =============================================================================
-- StepBattle — Team Battles + Public Lobbies + Join Codes.
--
-- NEW FORMATS / CONCEPTS:
--   • Team battle  — battles.type='team'. Default 2 teams, expandable to 4.
--                    Each participant has a `team_label` ('A', 'B', 'C', 'D').
--                    Each team has a `battle_teams` row carrying its
--                    (renameable) display name. Winner = team with the
--                    highest sum of members' `current_steps`. Ties → no
--                    winner (consistent with 1v1/group rule). Winning team
--                    members each get xp_reward × team_size XP.
--   • Public visibility — every battle now has a `visibility` ('private' /
--                         'public'). Public battles are discoverable in the
--                         Battles → Discover screen and joinable by anyone
--                         via tap (no invite needed). Applies to 1v1,
--                         group, and team types — creator decides per battle.
--   • Join code — every battle now has a 6-char human-friendly `join_code`
--                 (uppercase, no ambiguous chars). Anyone can paste it to
--                 join a public OR private battle (the code is the share
--                 token; sharing it grants access).
--
-- ROSTER MAX:
--   • Team battle:   10 participants total across all teams.
--   • Multi-player:  10 participants (unchanged).
--   • 1v1:           2 (unchanged).
--
-- HOW TO APPLY:
--   Dashboard → SQL Editor → paste this whole file → Run. Safe to re-run.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Expand battles.type check to allow 'team'.
-- -----------------------------------------------------------------------------
alter table public.battles
  drop constraint if exists battles_type_check;
alter table public.battles
  add constraint battles_type_check
  check (type in ('1v1', 'group', 'team'));

-- -----------------------------------------------------------------------------
-- 2. Visibility flag (private/public). Default private to preserve existing
--    battle semantics. Public battles surface in the Discover screen.
-- -----------------------------------------------------------------------------
alter table public.battles
  add column if not exists visibility text not null default 'private'
  check (visibility in ('private', 'public'));

-- Index used by the Discover screen query (pending battles, public only).
create index if not exists battles_visibility_status_idx
  on public.battles (visibility, status, created_at desc)
  where visibility = 'public';

-- -----------------------------------------------------------------------------
-- 3. Join code (6-char uppercase). Unique when set; nullable for legacy rows.
-- -----------------------------------------------------------------------------
alter table public.battles
  add column if not exists join_code text;

create unique index if not exists battles_join_code_uniq
  on public.battles (join_code) where join_code is not null;

-- -----------------------------------------------------------------------------
-- 4. Team-battle structure: team_count on battles + team_label on each
--    participant + a `battle_teams` row per (battle, team_label) holding
--    the (renameable) display name.
-- -----------------------------------------------------------------------------
alter table public.battles
  add column if not exists team_count integer;

alter table public.battle_participants
  add column if not exists team_label text;

-- Useful for the per-team aggregation in process_battle_lifecycle.
create index if not exists battle_participants_team_idx
  on public.battle_participants (battle_id, team_label);

create table if not exists public.battle_teams (
  battle_id   uuid not null references public.battles(id) on delete cascade,
  team_label  text not null,                       -- 'A' / 'B' / 'C' / 'D'
  team_name   text,                                -- creator-renameable
  primary key (battle_id, team_label)
);

alter table public.battle_teams enable row level security;

drop policy if exists "battle_teams_read_all" on public.battle_teams;
create policy "battle_teams_read_all"
  on public.battle_teams for select to authenticated using (true);

-- Battle creator may write team metadata (rename teams).
drop policy if exists "battle_teams_write_creator" on public.battle_teams;
create policy "battle_teams_write_creator"
  on public.battle_teams for all to authenticated
  using (exists (
    select 1 from public.battles b
    where b.id = battle_teams.battle_id
      and b.created_by = auth.uid()
  ))
  with check (exists (
    select 1 from public.battles b
    where b.id = battle_teams.battle_id
      and b.created_by = auth.uid()
  ));

-- -----------------------------------------------------------------------------
-- 5. Helper to generate a 6-char join code that avoids ambiguous characters
--    (0/O/I/1) so users can read it off a screen without ambiguity. Loops
--    until it finds an unused code; with a 30^6 space (~729 million) and
--    realistic battle counts the loop rarely iterates more than once.
-- -----------------------------------------------------------------------------
create or replace function public.generate_battle_join_code()
returns text
language plpgsql
volatile
as $$
declare
  v_alphabet text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; -- 30 chars, no 0/O/I/1
  v_code     text;
  v_exists   boolean;
  v_i        int;
begin
  loop
    v_code := '';
    for v_i in 1..6 loop
      v_code := v_code || substr(v_alphabet, 1 + floor(random() * 30)::int, 1);
    end loop;
    select exists (select 1 from public.battles where join_code = v_code)
      into v_exists;
    exit when not v_exists;
  end loop;
  return v_code;
end;
$$;

-- Backfill: any pre-existing battles without a join_code get one assigned now
-- so the new UI's "copy code" surfaces never show NULL.
update public.battles
set join_code = public.generate_battle_join_code()
where join_code is null;

-- =============================================================================
-- Inspect after applying:
--   select id, type, visibility, join_code, status, team_count
--   from public.battles
--   order by created_at desc limit 10;
--
--   select battle_id, team_label, team_name from public.battle_teams limit 10;
--
--   -- Pick a join code and try it:
--   select public.generate_battle_join_code();
-- =============================================================================
