-- =============================================================================
-- StepBattle — recurring "Daily" battles.
--
-- A Daily battle is no longer a one-off ends-at-midnight challenge. It's a
-- series: every day at the creator's local midnight a fresh `battles` row is
-- spawned with the same participants (already accepted at the series level,
-- so nobody re-accepts daily). The creator can stop the recurrence at any
-- time; the currently-running instance still completes naturally — only
-- *future* instances are skipped.
--
-- DATA MODEL:
--   • battle_series             — one row per recurring series.
--   • battle_series_participants — accepted roster cached for the cron to
--                                  replay each day without re-prompting users.
--   • battles.series_id          — nullable FK back to battle_series; null
--                                  for non-recurring (existing) battles.
--
-- LIFECYCLE FLOW:
--   1. Client `createDailySeries`  → inserts series + roster + first battle.
--   2. First instance runs as a normal battle through process_battle_lifecycle.
--   3. When that instance completes, cron checks series.status='active' and
--      spawns next instance: start = b.end_time + 1s (= next local midnight),
--      end = +23h59m59s. Participants copied from battle_series_participants
--      with invite_status='accepted' (series-level acceptance covers it).
--   4. Repeat ad infinitum until creator hits "Stop recurring", which sets
--      series.status='stopped'. The active instance still completes; cron's
--      "series.status='active'" guard prevents further spawns.
--
-- TZ NOTES:
--   • Series stores creator's tz_offset_minutes at creation (for clarity /
--     future fixes), but the cron just does `b.end_time + 1 second` to get
--     the next day's midnight — the original local-midnight encoding is
--     already baked into b.end_time's UTC value.
--   • DST shift days will produce a 23h or 25h instance once per year.
--     Acceptable for v1.
--
-- HOW TO APPLY:
--   Dashboard → SQL Editor → paste this whole file → Run. Safe to re-run.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- battle_series — recurring metadata
-- -----------------------------------------------------------------------------
create table if not exists public.battle_series (
  id                  uuid primary key default gen_random_uuid(),
  type                text not null check (type in ('1v1', 'group')),
  status              text not null default 'active' check (status in ('active', 'stopped')),
  created_by          uuid not null references public.profiles(id) on delete cascade,
  created_at          timestamptz not null default now(),
  stopped_at          timestamptz,
  tz_offset_minutes   integer not null default 0,
  xp_reward           integer not null default 200
);

create index if not exists battle_series_creator_idx
  on public.battle_series (created_by);

alter table public.battle_series enable row level security;

drop policy if exists "battle_series_read_all" on public.battle_series;
create policy "battle_series_read_all"
  on public.battle_series for select to authenticated using (true);

drop policy if exists "battle_series_create_self" on public.battle_series;
create policy "battle_series_create_self"
  on public.battle_series for insert to authenticated
  with check (auth.uid() = created_by);

drop policy if exists "battle_series_update_creator" on public.battle_series;
create policy "battle_series_update_creator"
  on public.battle_series for update to authenticated
  using (auth.uid() = created_by)
  with check (auth.uid() = created_by);

-- -----------------------------------------------------------------------------
-- battle_series_participants — cached accepted roster
-- -----------------------------------------------------------------------------
create table if not exists public.battle_series_participants (
  series_id    uuid not null references public.battle_series(id) on delete cascade,
  user_id      uuid not null references public.profiles(id) on delete cascade,
  display_name text not null default '',
  avatar_url   text,
  primary key (series_id, user_id)
);

alter table public.battle_series_participants enable row level security;

drop policy if exists "battle_series_participants_read_all"
  on public.battle_series_participants;
create policy "battle_series_participants_read_all"
  on public.battle_series_participants for select to authenticated using (true);

-- Only the series creator can write the roster.
drop policy if exists "battle_series_participants_creator_write"
  on public.battle_series_participants;
create policy "battle_series_participants_creator_write"
  on public.battle_series_participants for all to authenticated
  using (exists (
    select 1 from public.battle_series s
    where s.id = battle_series_participants.series_id
      and s.created_by = auth.uid()
  ))
  with check (exists (
    select 1 from public.battle_series s
    where s.id = battle_series_participants.series_id
      and s.created_by = auth.uid()
  ));

-- -----------------------------------------------------------------------------
-- battles.series_id — links each instance back to its series.
-- -----------------------------------------------------------------------------
alter table public.battles
  add column if not exists series_id uuid
    references public.battle_series(id) on delete set null;

create index if not exists battles_series_idx on public.battles (series_id);

-- =============================================================================
-- Inspect after applying:
--   select id, status, created_at, tz_offset_minutes
--     from public.battle_series order by created_at desc limit 5;
--   select b.id, b.status, b.start_time, b.end_time, b.series_id
--     from public.battles b
--     where b.series_id is not null
--     order by b.start_time desc limit 10;
-- =============================================================================
