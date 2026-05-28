-- =============================================================================
-- StepBattle — initial schema (Phase 0 + foundations for every phase)
--
-- HOW TO APPLY:
--   Supabase Dashboard → SQL Editor → New query → paste the entire file → Run.
--   Safe to re-run: every CREATE uses IF NOT EXISTS and every policy is
--   dropped before being recreated.
--
-- DESIGN NOTES:
--   • All "is this row mine?" checks use auth.uid() — Supabase's helper that
--     resolves to the JWT's `sub` claim on the current request.
--   • RLS is enabled on every user-data table. We default-deny and grant
--     specific policies; nothing is reachable without an explicit allow.
--   • One row per auth user lives in `profiles`. A trigger on auth.users
--     auto-creates it; the app never inserts profiles directly.
--   • Lifetime-counter friendly: `profiles.total_steps_all_time` is monotonic
--     and the battle baseline uses snapshots of it (see battle_participants).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Extensions
-- -----------------------------------------------------------------------------
create extension if not exists "pgcrypto";   -- gen_random_uuid()

-- -----------------------------------------------------------------------------
-- 1. profiles  — one row per auth user (id = auth.uid())
-- -----------------------------------------------------------------------------
create table if not exists public.profiles (
  id                      uuid primary key references auth.users(id) on delete cascade,
  user_code               text unique,
  display_name            text not null default '',
  avatar_url              text,
  email                   text,

  -- Gameplay
  daily_step_goal         integer not null default 8000,
  total_xp                integer not null default 0,
  level                   integer not null default 1,
  xp_earned_today         integer not null default 0,
  xp_earned_today_date    text,                     -- yyyy-MM-dd, local
  total_steps_all_time    bigint  not null default 0,
  current_streak          integer not null default 0,
  longest_streak          integer not null default 0,
  last_active_at          timestamptz,
  last_step_xp_threshold  integer not null default 0,
  last_step_xp_date       text,
  daily_goal_xp_awarded_date text,

  -- Push
  fcm_token               text,

  -- Geo (set during onboarding via the geo flow)
  country_code            text,
  country_name            text,
  state_name              text,
  district_name           text,
  home_lat                double precision,
  home_lng                double precision,
  home_set_at             timestamptz,

  -- Membership
  clan_id                 uuid,                     -- FK added later (forward decl)

  created_at              timestamptz not null default now()
);

create index if not exists profiles_user_code_idx on public.profiles (user_code);
create index if not exists profiles_total_xp_idx  on public.profiles (total_xp desc);
create index if not exists profiles_country_xp_idx on public.profiles (country_code, total_xp desc);
create index if not exists profiles_state_xp_idx   on public.profiles (state_name, total_xp desc);
create index if not exists profiles_district_xp_idx on public.profiles (district_name, total_xp desc);

alter table public.profiles enable row level security;

drop policy if exists "profiles_read_all" on public.profiles;
create policy "profiles_read_all"
  on public.profiles for select
  to authenticated
  using (true);

drop policy if exists "profiles_write_self" on public.profiles;
create policy "profiles_write_self"
  on public.profiles for all
  to authenticated
  using (auth.uid() = id)
  with check (auth.uid() = id);

-- -----------------------------------------------------------------------------
-- 1a. Auto-create profile on auth.users insert.
--     Display name + avatar come from the OAuth provider metadata when
--     present; we still let the onboarding flow overwrite them.
-- -----------------------------------------------------------------------------
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, display_name, avatar_url, email)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'name', new.raw_user_meta_data->>'full_name', ''),
    new.raw_user_meta_data->>'avatar_url',
    new.email
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- -----------------------------------------------------------------------------
-- 2. step_logs — one row per (user, date)
-- -----------------------------------------------------------------------------
create table if not exists public.step_logs (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references public.profiles(id) on delete cascade,
  date        text not null,                         -- yyyy-MM-dd, local
  step_count  integer not null default 0,
  calories    integer not null default 0,
  source      text,                                  -- 'native' | 'health_connect' | 'google_fit'
  synced_at   timestamptz not null default now(),
  unique (user_id, date)
);

create index if not exists step_logs_user_date_idx on public.step_logs (user_id, date desc);

alter table public.step_logs enable row level security;

drop policy if exists "step_logs_own" on public.step_logs;
create policy "step_logs_own"
  on public.step_logs for all
  to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

-- -----------------------------------------------------------------------------
-- 3. source_step_hourly — per-source, hourly buckets (for charts + battle
--    time-window steps if we ever need finer than per-day granularity).
-- -----------------------------------------------------------------------------
create table if not exists public.source_step_hourly (
  id                    uuid primary key default gen_random_uuid(),
  user_id               uuid not null references public.profiles(id) on delete cascade,
  hour_start            timestamptz not null,        -- UTC, truncated to the hour
  native_steps          integer,
  health_connect_steps  integer,
  google_fit_steps      integer,
  aggregate             integer,
  source_label          text,
  created_at            timestamptz not null default now(),
  unique (user_id, hour_start)
);

create index if not exists source_step_hourly_user_hour_idx
  on public.source_step_hourly (user_id, hour_start desc);

alter table public.source_step_hourly enable row level security;

drop policy if exists "source_step_hourly_own" on public.source_step_hourly;
create policy "source_step_hourly_own"
  on public.source_step_hourly for all
  to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

-- -----------------------------------------------------------------------------
-- 4. missions — read-only catalog (admin-seeded)
-- -----------------------------------------------------------------------------
create table if not exists public.missions (
  id            text primary key,                    -- 'daily_steps', 'weekly_battles', etc.
  type          text not null check (type in ('daily', 'weekly')),
  title         text not null,
  description   text not null default '',
  category      text not null check (category in ('steps','battle','streak','calories')),
  target_value  integer not null,
  xp_reward     integer not null,
  difficulty    text not null default 'easy'
);

alter table public.missions enable row level security;

drop policy if exists "missions_read_all" on public.missions;
create policy "missions_read_all"
  on public.missions for select
  to authenticated
  using (true);
-- No write policy → only the service_role / dashboard can seed missions.

-- Seed the defaults from MissionModel.defaultDaily / defaultWeekly so the
-- app doesn't have to ship hard-coded fallbacks.
insert into public.missions (id, type, title, description, category, target_value, xp_reward, difficulty) values
  ('daily_steps',      'daily',  'Walk 5,000 Steps',     'Hit your daily step target',                    'steps',  5000, 100, 'easy'),
  ('daily_battle',     'daily',  'Win a Battle',         'Defeat an opponent in a step battle',           'battle', 1,    150, 'medium'),
  ('daily_streak',     'daily',  'Keep Streak Alive',    'Log steps for another consecutive day',         'streak', 1,    50,  'easy'),
  ('weekly_steps',     'weekly', 'Walk 50,000 Steps',    'Accumulate steps across the week',              'steps',  50000,500, 'hard'),
  ('weekly_battles',   'weekly', 'Win 3 Battles',        'Defeat 3 opponents this week',                  'battle', 3,    400, 'medium'),
  ('weekly_alldays',   'weekly', 'Complete All Daily Missions 5 Days', 'Finish every daily mission 5 days in a row', 'streak', 5, 300, 'hard')
on conflict (id) do nothing;

-- -----------------------------------------------------------------------------
-- 5. user_mission_progress — one row per (user, mission, period_start)
-- -----------------------------------------------------------------------------
create table if not exists public.user_mission_progress (
  user_id        uuid not null references public.profiles(id) on delete cascade,
  mission_id     text not null references public.missions(id) on delete cascade,
  period_start   text not null,                      -- yyyy-MM-dd, local (Monday for weekly)
  current_value  integer not null default 0,
  target_value   integer not null,
  is_completed   boolean not null default false,
  completed_at   timestamptz,
  primary key (user_id, mission_id, period_start)
);

create index if not exists user_mission_progress_period_idx
  on public.user_mission_progress (user_id, period_start);

alter table public.user_mission_progress enable row level security;

drop policy if exists "user_mission_progress_own" on public.user_mission_progress;
create policy "user_mission_progress_own"
  on public.user_mission_progress for all
  to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

-- -----------------------------------------------------------------------------
-- 6. clans
-- -----------------------------------------------------------------------------
create table if not exists public.clans (
  id            uuid primary key default gen_random_uuid(),
  name          text not null,
  clan_id_code  text unique,
  captain_id    uuid not null references public.profiles(id) on delete cascade,
  created_at    timestamptz not null default now()
);

create index if not exists clans_captain_idx on public.clans (captain_id);

alter table public.clans enable row level security;

drop policy if exists "clans_read_all" on public.clans;
create policy "clans_read_all"
  on public.clans for select to authenticated using (true);

drop policy if exists "clans_create_any" on public.clans;
create policy "clans_create_any"
  on public.clans for insert to authenticated
  with check (auth.uid() = captain_id);

drop policy if exists "clans_update_captain" on public.clans;
create policy "clans_update_captain"
  on public.clans for update to authenticated
  using (auth.uid() = captain_id)
  with check (auth.uid() = captain_id);

drop policy if exists "clans_delete_captain" on public.clans;
create policy "clans_delete_captain"
  on public.clans for delete to authenticated
  using (auth.uid() = captain_id);

-- Forward-declared FK on profiles.clan_id now that clans exists.
do $$ begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'profiles_clan_id_fkey'
  ) then
    alter table public.profiles
      add constraint profiles_clan_id_fkey
      foreign key (clan_id) references public.clans(id) on delete set null;
  end if;
end $$;

-- -----------------------------------------------------------------------------
-- 7. clan_members — replaces clans.memberIds[] + subcollection
-- -----------------------------------------------------------------------------
create table if not exists public.clan_members (
  clan_id      uuid not null references public.clans(id) on delete cascade,
  user_id      uuid not null references public.profiles(id) on delete cascade,
  role         text not null default 'soldier' check (role in ('captain','admin','soldier')),
  steps_today  integer not null default 0,
  joined_at    timestamptz not null default now(),
  primary key (clan_id, user_id)
);

create index if not exists clan_members_user_idx on public.clan_members (user_id);

alter table public.clan_members enable row level security;

drop policy if exists "clan_members_read_all" on public.clan_members;
create policy "clan_members_read_all"
  on public.clan_members for select to authenticated using (true);

-- A user can join/leave themselves; captain logic enforced in app +
-- captain update via separate path. Anyone in the clan can update their own
-- steps_today row.
drop policy if exists "clan_members_self_insert" on public.clan_members;
create policy "clan_members_self_insert"
  on public.clan_members for insert to authenticated
  with check (auth.uid() = user_id);

drop policy if exists "clan_members_self_update" on public.clan_members;
create policy "clan_members_self_update"
  on public.clan_members for update to authenticated
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

drop policy if exists "clan_members_self_delete" on public.clan_members;
create policy "clan_members_self_delete"
  on public.clan_members for delete to authenticated
  using (
    auth.uid() = user_id
    or exists (
      select 1 from public.clans c
      where c.id = clan_members.clan_id and c.captain_id = auth.uid()
    )
  );

-- -----------------------------------------------------------------------------
-- 8. clan_invites — pending invites separated from members
-- -----------------------------------------------------------------------------
create table if not exists public.clan_invites (
  clan_id     uuid not null references public.clans(id) on delete cascade,
  user_id     uuid not null references public.profiles(id) on delete cascade,
  invited_by  uuid references public.profiles(id) on delete set null,
  created_at  timestamptz not null default now(),
  primary key (clan_id, user_id)
);

alter table public.clan_invites enable row level security;

drop policy if exists "clan_invites_read_relevant" on public.clan_invites;
create policy "clan_invites_read_relevant"
  on public.clan_invites for select to authenticated
  using (
    auth.uid() = user_id
    or exists (
      select 1 from public.clans c
      where c.id = clan_invites.clan_id and c.captain_id = auth.uid()
    )
  );

drop policy if exists "clan_invites_captain_create" on public.clan_invites;
create policy "clan_invites_captain_create"
  on public.clan_invites for insert to authenticated
  with check (
    exists (select 1 from public.clans c where c.id = clan_invites.clan_id and c.captain_id = auth.uid())
  );

drop policy if exists "clan_invites_delete_either" on public.clan_invites;
create policy "clan_invites_delete_either"
  on public.clan_invites for delete to authenticated
  using (
    auth.uid() = user_id
    or exists (
      select 1 from public.clans c
      where c.id = clan_invites.clan_id and c.captain_id = auth.uid()
    )
  );

-- -----------------------------------------------------------------------------
-- 9. battles + battle_participants
--    NOTE: implements the lifetime-counter baseline approach for the new
--    time-window scoring. battle_participants.start_steps_baseline is
--    captured at activation; current_steps = profile.total_steps_all_time
--    - start_steps_baseline. end_steps_baseline frozen when status flips
--    to completed.
-- -----------------------------------------------------------------------------
create table if not exists public.battles (
  id              uuid primary key default gen_random_uuid(),
  type            text not null check (type in ('1v1','group')),
  status          text not null default 'pending' check (status in ('pending','active','completed','cancelled')),
  start_time      timestamptz not null,
  end_time        timestamptz not null,
  xp_reward       integer not null default 200,
  winner_id       uuid references public.profiles(id) on delete set null,
  created_by      uuid not null references public.profiles(id) on delete cascade,
  created_at      timestamptz not null default now()
);

create index if not exists battles_status_idx on public.battles (status, start_time desc);
create index if not exists battles_created_by_idx on public.battles (created_by);

alter table public.battles enable row level security;

drop policy if exists "battles_read_all" on public.battles;
create policy "battles_read_all"
  on public.battles for select to authenticated using (true);

drop policy if exists "battles_create_self" on public.battles;
create policy "battles_create_self"
  on public.battles for insert to authenticated
  with check (auth.uid() = created_by);

-- Participants (any) can update status / winner / etc. — RLS lets any
-- authenticated user update; integrity enforced in app.
drop policy if exists "battles_update_any_auth" on public.battles;
create policy "battles_update_any_auth"
  on public.battles for update to authenticated using (true) with check (true);

drop policy if exists "battles_delete_creator_pending" on public.battles;
create policy "battles_delete_creator_pending"
  on public.battles for delete to authenticated
  using (auth.uid() = created_by);

create table if not exists public.battle_participants (
  battle_id              uuid not null references public.battles(id) on delete cascade,
  user_id                uuid not null references public.profiles(id) on delete cascade,
  display_name           text not null default '',
  avatar_url             text,
  start_steps_baseline   bigint,                      -- profile.total_steps_all_time at activation
  end_steps_baseline     bigint,                      -- captured at completion
  current_steps          integer not null default 0,  -- denormalized: total_steps_all_time - start_steps_baseline
  is_winner              boolean not null default false,
  invite_status          text not null default 'pending' check (invite_status in ('pending','accepted','rejected')),
  primary key (battle_id, user_id)
);

create index if not exists battle_participants_user_idx
  on public.battle_participants (user_id);

alter table public.battle_participants enable row level security;

drop policy if exists "battle_participants_read_all" on public.battle_participants;
create policy "battle_participants_read_all"
  on public.battle_participants for select to authenticated using (true);

drop policy if exists "battle_participants_insert_creator" on public.battle_participants;
create policy "battle_participants_insert_creator"
  on public.battle_participants for insert to authenticated
  with check (
    exists (
      select 1 from public.battles b
      where b.id = battle_participants.battle_id and b.created_by = auth.uid()
    )
  );

-- Either participant can update their own row (current_steps, invite_status, is_winner).
drop policy if exists "battle_participants_update_self" on public.battle_participants;
create policy "battle_participants_update_self"
  on public.battle_participants for update to authenticated
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

drop policy if exists "battle_participants_delete_self" on public.battle_participants;
create policy "battle_participants_delete_self"
  on public.battle_participants for delete to authenticated
  using (auth.uid() = user_id);

-- -----------------------------------------------------------------------------
-- 10. clan_battles + clan_battle_teams
-- -----------------------------------------------------------------------------
create table if not exists public.clan_battles (
  id            uuid primary key default gen_random_uuid(),
  status        text not null default 'active' check (status in ('pending','active','completed')),
  battle_type   text not null default 'steps',
  start_time    timestamptz not null,
  end_time      timestamptz not null,
  created_at    timestamptz not null default now()
);

create index if not exists clan_battles_status_idx on public.clan_battles (status, start_time desc);

alter table public.clan_battles enable row level security;

drop policy if exists "clan_battles_read_all" on public.clan_battles;
create policy "clan_battles_read_all"
  on public.clan_battles for select to authenticated using (true);

drop policy if exists "clan_battles_write_auth" on public.clan_battles;
create policy "clan_battles_write_auth"
  on public.clan_battles for all to authenticated using (true) with check (true);

create table if not exists public.clan_battle_teams (
  clan_battle_id  uuid not null references public.clan_battles(id) on delete cascade,
  clan_id         uuid not null references public.clans(id) on delete cascade,
  clan_name       text not null,
  team_label      text not null check (team_label in ('A','B')),
  total_steps     bigint not null default 0,
  primary key (clan_battle_id, team_label)
);

alter table public.clan_battle_teams enable row level security;

drop policy if exists "clan_battle_teams_read_all" on public.clan_battle_teams;
create policy "clan_battle_teams_read_all"
  on public.clan_battle_teams for select to authenticated using (true);

drop policy if exists "clan_battle_teams_write_auth" on public.clan_battle_teams;
create policy "clan_battle_teams_write_auth"
  on public.clan_battle_teams for all to authenticated using (true) with check (true);

-- -----------------------------------------------------------------------------
-- 11. friend_relationships
--     Status enforced server-side; RLS prevents cross-user shenanigans
--     (the from-side can only create pending; only to-side can flip
--     status; either side can delete).
-- -----------------------------------------------------------------------------
create table if not exists public.friend_relationships (
  id            uuid primary key default gen_random_uuid(),
  from_user_id  uuid not null references public.profiles(id) on delete cascade,
  to_user_id    uuid not null references public.profiles(id) on delete cascade,
  status        text not null default 'pending' check (status in ('pending','accepted','rejected')),
  created_at    timestamptz not null default now(),
  unique (from_user_id, to_user_id)
);

create index if not exists friend_rels_to_status_idx
  on public.friend_relationships (to_user_id, status);
create index if not exists friend_rels_from_status_idx
  on public.friend_relationships (from_user_id, status);

alter table public.friend_relationships enable row level security;

drop policy if exists "friend_rels_read_party" on public.friend_relationships;
create policy "friend_rels_read_party"
  on public.friend_relationships for select to authenticated
  using (auth.uid() in (from_user_id, to_user_id));

drop policy if exists "friend_rels_create_from" on public.friend_relationships;
create policy "friend_rels_create_from"
  on public.friend_relationships for insert to authenticated
  with check (auth.uid() = from_user_id and status = 'pending');

drop policy if exists "friend_rels_update_to" on public.friend_relationships;
create policy "friend_rels_update_to"
  on public.friend_relationships for update to authenticated
  using (auth.uid() = to_user_id)
  with check (auth.uid() = to_user_id);

drop policy if exists "friend_rels_delete_party" on public.friend_relationships;
create policy "friend_rels_delete_party"
  on public.friend_relationships for delete to authenticated
  using (auth.uid() in (from_user_id, to_user_id));

-- -----------------------------------------------------------------------------
-- 12. notifications
-- -----------------------------------------------------------------------------
create table if not exists public.notifications (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references public.profiles(id) on delete cascade,
  type        text not null,
  title       text not null,
  body        text not null default '',
  data        jsonb not null default '{}'::jsonb,
  read        boolean not null default false,
  created_at  timestamptz not null default now()
);

create index if not exists notifications_user_created_idx
  on public.notifications (user_id, created_at desc);

alter table public.notifications enable row level security;

drop policy if exists "notifications_read_self" on public.notifications;
create policy "notifications_read_self"
  on public.notifications for select to authenticated
  using (auth.uid() = user_id);

-- Authenticated users can create notifications for other users (battle/friend/clan
-- invites all do this client-side). If a `from_user_id` field is present in
-- `data`, it must match the caller (anti-impersonation).
drop policy if exists "notifications_create_any" on public.notifications;
create policy "notifications_create_any"
  on public.notifications for insert to authenticated
  with check (
    (data->>'from_user_id') is null
    or (data->>'from_user_id')::uuid = auth.uid()
  );

drop policy if exists "notifications_update_recipient" on public.notifications;
create policy "notifications_update_recipient"
  on public.notifications for update to authenticated
  using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- No delete: analytics retention.

-- -----------------------------------------------------------------------------
-- 13. leaderboard_snapshots — pre-computed for the global board.
--     We'll write this from a cron / edge function later.
-- -----------------------------------------------------------------------------
create table if not exists public.leaderboard_snapshots (
  user_id      uuid primary key references public.profiles(id) on delete cascade,
  rank         integer not null,
  total_xp     integer not null default 0,
  display_name text not null default '',
  avatar_url   text,
  updated_at   timestamptz not null default now()
);

create index if not exists leaderboard_snapshots_rank_idx
  on public.leaderboard_snapshots (rank);

alter table public.leaderboard_snapshots enable row level security;

drop policy if exists "leaderboard_snapshots_read_all" on public.leaderboard_snapshots;
create policy "leaderboard_snapshots_read_all"
  on public.leaderboard_snapshots for select to authenticated using (true);
-- No write policy → service_role only.
