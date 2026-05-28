-- =============================================================================
-- StepBattle — enable Supabase Realtime on every user-data table the Flutter
-- client streams from.
--
-- By default, Postgres tables are NOT in the `supabase_realtime` publication,
-- so `supabase.from('x').stream(...)` returns the initial snapshot but never
-- emits live updates after that. This migration adds every table the app
-- relies on for live UI (friends, notifications, battles, clans, missions,
-- step_logs).
--
-- HOW TO APPLY:
--   Supabase Dashboard → SQL Editor → New query → paste → Run.
--   Safe to re-run: `add table if not exists` is wrapped in a guard.
-- =============================================================================

do $$
declare
  t text;
  realtime_tables constant text[] := array[
    'public.profiles',
    'public.step_logs',
    'public.user_mission_progress',
    'public.friend_relationships',
    'public.notifications',
    'public.battles',
    'public.battle_participants',
    'public.clans',
    'public.clan_members',
    'public.clan_invites',
    'public.clan_battles',
    'public.clan_battle_teams'
  ];
begin
  foreach t in array realtime_tables loop
    if not exists (
      select 1 from pg_publication_tables
      where pubname = 'supabase_realtime'
        and schemaname || '.' || tablename = t
    ) then
      execute format('alter publication supabase_realtime add table %s', t);
    end if;
  end loop;
end $$;
